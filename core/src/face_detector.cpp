#include "face_detector.hpp"

#include <onnxruntime_cxx_api.h>

#include <array>
#include <cmath>

namespace viracm {
namespace {

// face_detection_yunet_2023mar.onnx has a fixed 1x3x640x640 BGR input (values 0-255);
// frames are scaled to fit and zero-padded at the bottom/right.
constexpr int kInputSize = 640;
constexpr int kStrides[] = {8, 16, 32};

float clamp01(float v) { return std::min(1.0f, std::max(0.0f, v)); }

std::vector<Face> non_max_suppression(std::vector<Face> faces, float threshold) {
    std::sort(faces.begin(), faces.end(), [](const Face &a, const Face &b) { return a.score > b.score; });
    std::vector<Face> kept;
    for (const Face &face : faces) {
        const bool overlaps = std::any_of(kept.begin(), kept.end(),
                                          [&](const Face &k) { return iou(k.box, face.box) > threshold; });
        if (!overlaps) kept.push_back(face);
    }
    return kept;
}

}  // namespace

struct FaceDetector::Impl {
    Ort::Env env{ORT_LOGGING_LEVEL_WARNING, "viracm"};
    Ort::Session session{nullptr};
    Ort::MemoryInfo memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    std::vector<float> input = std::vector<float>(3 * kInputSize * kInputSize);
    std::vector<std::string> output_names;
    std::vector<const char *> output_name_ptrs;
};

FaceDetector::FaceDetector(const std::string &model_path, float score_threshold, float nms_threshold,
                           const std::string &coreml_compute_units)
    : impl_(std::make_unique<Impl>()), score_threshold_(score_threshold), nms_threshold_(nms_threshold) {
    Ort::SessionOptions options;
    options.SetIntraOpNumThreads(2);
    options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
    if (!coreml_compute_units.empty()) {
        options.AppendExecutionProvider("CoreML", {{"ModelFormat", "MLProgram"},
                                                   {"MLComputeUnits", coreml_compute_units},
                                                   {"RequireStaticInputShapes", "1"}});
    }
    impl_->session = Ort::Session(impl_->env, model_path.c_str(), options);

    // Output order used by decoding below: cls, obj, bbox, kps, each for strides 8/16/32.
    for (const char *kind : {"cls", "obj", "bbox", "kps"}) {
        for (int stride : kStrides) impl_->output_names.push_back(std::string(kind) + "_" + std::to_string(stride));
    }
    for (const std::string &name : impl_->output_names) impl_->output_name_ptrs.push_back(name.c_str());
}

FaceDetector::~FaceDetector() = default;

std::vector<Face> FaceDetector::detect(const viracm_image &image) {
    const float scale = std::min(static_cast<float>(kInputSize) / image.width,
                                 static_cast<float>(kInputSize) / image.height);
    const int resized_w = std::max(1, static_cast<int>(image.width * scale));
    const int resized_h = std::max(1, static_cast<int>(image.height * scale));

    // Bilinear resize BGRA -> planar BGR float.
    std::vector<float> &input = impl_->input;
    std::fill(input.begin(), input.end(), 0.0f);
    float *planes[3] = {input.data(), input.data() + kInputSize * kInputSize,
                        input.data() + 2 * kInputSize * kInputSize};
    for (int y = 0; y < resized_h; ++y) {
        const float fy = std::clamp((y + 0.5f) / scale - 0.5f, 0.0f, static_cast<float>(image.height - 1));
        const int y0 = static_cast<int>(fy);
        const int y1 = std::min(y0 + 1, image.height - 1);
        const float wy = fy - y0;
        const uint8_t *r0 = image.data + static_cast<size_t>(y0) * image.stride;
        const uint8_t *r1 = image.data + static_cast<size_t>(y1) * image.stride;
        for (int x = 0; x < resized_w; ++x) {
            const float fx = std::clamp((x + 0.5f) / scale - 0.5f, 0.0f, static_cast<float>(image.width - 1));
            const int x0 = static_cast<int>(fx);
            const int x1 = std::min(x0 + 1, image.width - 1);
            const float wx = fx - x0;
            for (int c = 0; c < 3; ++c) {
                const float top = r0[x0 * 4 + c] * (1 - wx) + r0[x1 * 4 + c] * wx;
                const float bottom = r1[x0 * 4 + c] * (1 - wx) + r1[x1 * 4 + c] * wx;
                planes[c][y * kInputSize + x] = top * (1 - wy) + bottom * wy;
            }
        }
    }

    const std::array<int64_t, 4> shape{1, 3, kInputSize, kInputSize};
    Ort::Value tensor = Ort::Value::CreateTensor<float>(impl_->memory, input.data(), input.size(),
                                                        shape.data(), shape.size());
    const char *input_names[] = {"input"};
    std::vector<Ort::Value> outputs =
        impl_->session.Run(Ort::RunOptions{nullptr}, input_names, &tensor, 1, impl_->output_name_ptrs.data(),
                           impl_->output_name_ptrs.size());

    std::vector<Face> faces;
    for (int i = 0; i < 3; ++i) {
        const int stride = kStrides[i];
        const int cols = kInputSize / stride;
        const int rows = kInputSize / stride;
        const float *cls = outputs[i].GetTensorData<float>();
        const float *obj = outputs[3 + i].GetTensorData<float>();
        const float *bbox = outputs[6 + i].GetTensorData<float>();
        for (int r = 0; r < rows; ++r) {
            for (int c = 0; c < cols; ++c) {
                const int idx = r * cols + c;
                const float score = std::sqrt(clamp01(cls[idx]) * clamp01(obj[idx]));
                if (score < score_threshold_) continue;
                const float cx = (c + bbox[idx * 4 + 0]) * stride;
                const float cy = (r + bbox[idx * 4 + 1]) * stride;
                const float w = std::exp(bbox[idx * 4 + 2]) * stride;
                const float h = std::exp(bbox[idx * 4 + 3]) * stride;
                faces.push_back({{(cx - w / 2) / scale, (cy - h / 2) / scale, w / scale, h / scale}, score});
            }
        }
    }
    return non_max_suppression(std::move(faces), nms_threshold_);
}

}  // namespace viracm
