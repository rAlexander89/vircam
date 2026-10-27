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
#include "viracm/viracm.h"

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

bool valid_image(const viracm_image *img) {
    return img && img->data && img->width > 0 && img->height > 0 && img->stride >= img->width * 4;
}

void write_error(char *error, int32_t error_size, const std::string &message) {
    if (error && error_size > 0) std::snprintf(error, static_cast<size_t>(error_size), "%s", message.c_str());
}

}  // namespace

struct viracm_engine {
    std::unique_ptr<viracm::FaceDetector> detector;
    viracm::PrivacyPolicy policy;
    viracm::FaceTracker tracker{std::max(policy.config().primary_grace_seconds,
                                         policy.config().blur_persistence_seconds)};
    viracm::Compositor compositor;
    bool debug_overlay = false;
    double last_timestamp = -1;
};

extern "C" {

viracm_engine *viracm_engine_create(const char *model_dir, char *error, int32_t error_size) {
    if (!model_dir) {
        write_error(error, error_size, "model_dir is NULL");
        return nullptr;
    }
    try {
        auto engine = std::make_unique<viracm_engine>();
        engine->detector = std::make_unique<viracm::FaceDetector>(std::string(model_dir) + "/" + kFaceModelFile,
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

void viracm_engine_destroy(viracm_engine *engine) { delete engine; }

void viracm_engine_set_debug_overlay(viracm_engine *engine, int32_t enabled) {
    if (engine) engine->debug_overlay = enabled != 0;
}

viracm_status viracm_engine_process(viracm_engine *engine,
                                    const viracm_image *in,
                                    viracm_image *out,
                                    double timestamp_seconds,
                                    viracm_frame_info *info) {
    return viracm_engine_process_with_masks(engine, in, out, timestamp_seconds, nullptr, 0, info);
}

viracm_status viracm_engine_process_with_masks(viracm_engine *engine,
                                               const viracm_image *in,
                                               viracm_image *out,
                                               double timestamp_seconds,
                                               const viracm_person_mask *masks,
                                               int32_t mask_count,
                                               viracm_frame_info *info) {
    if (!engine || !valid_image(in) || !valid_image(out) || in->width != out->width ||
        in->height != out->height || in->data == out->data || mask_count < 0 || (mask_count > 0 && !masks)) {
        return VIRACM_ERR_INVALID_ARGUMENT;
    }
    const auto start = std::chrono::steady_clock::now();
    viracm_frame_info result{};

    try {
        if (timestamp_seconds < engine->last_timestamp) {
            engine->tracker.reset();
            engine->policy.reset();
        }
        engine->last_timestamp = timestamp_seconds;

        const std::vector<viracm::Face> faces = engine->detector->detect(*in);
        engine->tracker.update(faces, timestamp_seconds);
        const viracm::PolicyDecision decision =
            engine->policy.decide(engine->tracker.tracks(), timestamp_seconds, in->width);

        viracm::AlphaMap primary;
        if (decision.primary_face) {
            const int index =
                viracm::select_person_mask(masks, mask_count, *decision.primary_face, in->width, in->height);
            if (index >= 0) {
                primary = viracm::from_person_mask(masks[index], in->width, in->height);
                result.used_person_mask = 1;
            } else {
                primary = viracm::head_and_shoulders(*decision.primary_face, in->width, in->height);
            }
        }
        engine->compositor.render(*in, *out, decision, primary);
        if (engine->debug_overlay) viracm::Compositor::draw_debug(*out, decision);

        result.mode = decision.primary_face ? VIRACM_FRAME_PROTECTED : VIRACM_FRAME_FULL_BLUR;
        result.faces_detected = static_cast<int32_t>(faces.size());
        result.faces_blurred = static_cast<int32_t>(decision.blur_boxes.size());
    } catch (...) {
        // Fail closed: forget who the primary person is and blur the whole frame.
        engine->tracker.reset();
        engine->policy.reset();
        try {
            viracm::privacy_blur(*in, *out);
        } catch (...) {
            return VIRACM_ERR_INTERNAL;
        }
        result = {};
        result.mode = VIRACM_FRAME_FULL_BLUR;
    }

    result.process_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    if (info) *info = result;
    return VIRACM_OK;
}

}  // extern "C"
