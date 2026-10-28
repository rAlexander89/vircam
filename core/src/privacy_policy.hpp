#pragma once

#include <optional>
#include <vector>

#include "face_tracker.hpp"

namespace vircam {

// Values from the privacy rules in PLAN.md.
struct PolicyConfig {
    // A primary face must be detected this many times, be this confident, and be at
    // least this fraction of the frame width before it can be kept sharp.
    int min_hits_for_primary = 3;
    float min_primary_score = 0.8f;
    float min_primary_width_fraction = 0.04f;
    // To pick a primary with none current, the largest face must be this much larger
    // (by area) than the next largest; otherwise the frame is fully blurred.
    float dominance_ratio = 1.5f;
    // Another face takes over from the current primary only if it stays this much
    // larger for this long.
    float takeover_ratio = 1.5f;
    double takeover_seconds = 0.5;
    // An undetected primary is kept for this long, then the frame is fully blurred.
    double primary_grace_seconds = 1.0;
    // Non-primary faces stay blurred this long after they were last detected.
    double blur_persistence_seconds = 0.75;
    // Non-primary face boxes are enlarged by this factor, and by up to
    // `stale_growth` more as they go undetected (the face may be moving).
    float blur_box_scale = 1.3f;
    float stale_growth = 0.5f;
};

struct PolicyDecision {
    std::optional<Box> primary_face;  // empty = fail closed, blur everything
    std::vector<Box> blur_boxes;      // regions that must be blurred even inside the primary region
};

class PrivacyPolicy {
public:
    explicit PrivacyPolicy(PolicyConfig config = {}) : config_(config) {}

    PolicyDecision decide(const std::vector<Track> &tracks, double t, int frame_width);
    void reset();

    const PolicyConfig &config() const { return config_; }

private:
    PolicyConfig config_;
    int primary_id_ = 0;  // 0 = none
    int challenger_id_ = 0;
    double challenger_since_ = 0;
};

}  // namespace vircam
