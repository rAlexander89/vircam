#include <algorithm>
#include <chrono>
#include <cstdio>
#include <exception>
#include <memory>
#include <new>
#include <string>

#include "compositor.hpp"
#include "face_detector.hpp"
#include "face_tracker.hpp"
#include "primary_region.hpp"
#include "privacy_blur.hpp"
#include "privacy_policy.hpp"
#include "vircam/vircam.h"

namespace {

constexpr const char *kFaceModelFile = "face_detection_yunet_2023mar.onnx";
// Low enough to catch partly turned or distant faces; the policy separately requires
// a high score before a face can become the primary (sharp) one.
constexpr float kFaceScoreThreshold = 0.6f;
constexpr float kFaceNmsThreshold = 0.3f;
#ifdef __APPLE__
// GPU via Core ML: ~2x faster than CPU for YuNet, and loads quickly (unlike "ALL").
constexpr const char *kCoreMLComputeUnits = "CPUAndGPU";
#else
constexpr const char *kCoreMLComputeUnits = "";
#endif

bool valid_image(const vircam_image *img) {
    return img && img->data && img->width > 0 && img->height > 0 && img->stride >= img->width * 4;
}

void write_error(char *error, int32_t error_size, const std::string &message) {
    if (error && error_size > 0) std::snprintf(error, static_cast<size_t>(error_size), "%s", message.c_str());
}

}  // namespace

struct vircam_engine {
    std::unique_ptr<vircam::FaceDetector> detector;
    vircam::PrivacyPolicy policy;
    vircam::FaceTracker tracker{std::max(policy.config().primary_grace_seconds,
                                         policy.config().blur_persistence_seconds)};
    vircam::Compositor compositor;
    bool debug_overlay = false;
    double last_timestamp = -1;
};

extern "C" {

vircam_engine *vircam_engine_create(const char *model_dir, char *error, int32_t error_size) {
    if (!model_dir) {
        write_error(error, error_size, "model_dir is NULL");
        return nullptr;
    }
    try {
        auto engine = std::make_unique<vircam_engine>();
        engine->detector = std::make_unique<vircam::FaceDetector>(std::string(model_dir) + "/" + kFaceModelFile,
                                                                   kFaceScoreThreshold, kFaceNmsThreshold,
                                                                   kCoreMLComputeUnits);
        return engine.release();
    } catch (const std::exception &e) {
        write_error(error, error_size, e.what());
    } catch (...) {
        write_error(error, error_size, "unknown error");
    }
    return nullptr;
}

void vircam_engine_destroy(vircam_engine *engine) { delete engine; }

void vircam_engine_set_debug_overlay(vircam_engine *engine, int32_t enabled) {
    if (engine) engine->debug_overlay = enabled != 0;
}

vircam_status vircam_engine_process(vircam_engine *engine,
                                    const vircam_image *in,
                                    vircam_image *out,
                                    double timestamp_seconds,
                                    vircam_frame_info *info) {
    return vircam_engine_process_with_masks(engine, in, out, timestamp_seconds, nullptr, 0, info);
}

vircam_status vircam_engine_process_with_masks(vircam_engine *engine,
                                               const vircam_image *in,
                                               vircam_image *out,
                                               double timestamp_seconds,
                                               const vircam_person_mask *masks,
                                               int32_t mask_count,
                                               vircam_frame_info *info) {
    if (!engine || !valid_image(in) || !valid_image(out) || in->width != out->width ||
        in->height != out->height || in->data == out->data || mask_count < 0 || (mask_count > 0 && !masks)) {
        return VIRCAM_ERR_INVALID_ARGUMENT;
    }
    const auto start = std::chrono::steady_clock::now();
    vircam_frame_info result{};

    try {
        if (timestamp_seconds < engine->last_timestamp) {
            engine->tracker.reset();
            engine->policy.reset();
        }
        engine->last_timestamp = timestamp_seconds;

        const std::vector<vircam::Face> faces = engine->detector->detect(*in);
        engine->tracker.update(faces, timestamp_seconds);
        const vircam::PolicyDecision decision =
            engine->policy.decide(engine->tracker.tracks(), timestamp_seconds, in->width);

        vircam::AlphaMap primary;
        if (decision.primary_face) {
            const int index =
                vircam::select_person_mask(masks, mask_count, *decision.primary_face, in->width, in->height);
            if (index >= 0) {
                primary = vircam::from_person_mask(masks[index], in->width, in->height);
                result.used_person_mask = 1;
            } else {
                primary = vircam::head_and_shoulders(*decision.primary_face, in->width, in->height);
            }
        }
        engine->compositor.render(*in, *out, decision, primary);
        if (engine->debug_overlay) vircam::Compositor::draw_debug(*out, decision);

        result.mode = decision.primary_face ? VIRCAM_FRAME_PROTECTED : VIRCAM_FRAME_FULL_BLUR;
        result.faces_detected = static_cast<int32_t>(faces.size());
        result.faces_blurred = static_cast<int32_t>(decision.blur_boxes.size());
    } catch (...) {
        // Fail closed: forget who the primary person is and blur the whole frame.
        engine->tracker.reset();
        engine->policy.reset();
        try {
            vircam::privacy_blur(*in, *out);
        } catch (...) {
            return VIRCAM_ERR_INTERNAL;
        }
        result = {};
        result.mode = VIRCAM_FRAME_FULL_BLUR;
    }

    result.process_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    if (info) *info = result;
    return VIRCAM_OK;
}

}  // extern "C"
