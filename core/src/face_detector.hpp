#pragma once

#include <memory>
#include <string>
#include <vector>

#include "types.hpp"
#include "vircam/vircam.h"

namespace vircam {

// YuNet face detector on ONNX Runtime. Not thread-safe.
class FaceDetector {
public:
    // Throws on failure to load the model. `coreml_compute_units` selects the Core ML
    // execution provider on Apple platforms ("ALL", "CPUAndNeuralEngine", "CPUAndGPU");
    // empty runs on the CPU.
    FaceDetector(const std::string &model_path, float score_threshold, float nms_threshold,
                 const std::string &coreml_compute_units = "");
    ~FaceDetector();

    // Faces in `image` pixel coordinates, highest score first.
    std::vector<Face> detect(const vircam_image &image);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
    float score_threshold_;
    float nms_threshold_;
};

}  // namespace vircam
