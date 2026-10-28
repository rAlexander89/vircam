#include "privacy_policy.hpp"

namespace vircam {

void PrivacyPolicy::reset() {
    primary_id_ = 0;
    challenger_id_ = 0;
}

PolicyDecision PrivacyPolicy::decide(const std::vector<Track> &tracks, double t, int frame_width) {
    auto detected_now = [&](const Track &track) { return track.last_seen >= t; };
    auto find = [&](int id) -> const Track * {
        for (const Track &track : tracks)
            if (track.id == id) return &track;
        return nullptr;
    };

    const Track *primary = primary_id_ ? find(primary_id_) : nullptr;
    if (primary && t - primary->last_seen > config_.primary_grace_seconds) primary = nullptr;

    if (primary) {
        // Takeover: the largest other face currently detected, if it is much larger.
        const Track *challenger = nullptr;
        for (const Track &track : tracks) {
            if (&track == primary || !detected_now(track)) continue;
            if (track.box.area() < config_.takeover_ratio * primary->box.area()) continue;
            if (!challenger || track.box.area() > challenger->box.area()) challenger = &track;
        }
        if (!challenger) {
            challenger_id_ = 0;
        } else if (challenger->id != challenger_id_) {
            challenger_id_ = challenger->id;
            challenger_since_ = t;
        } else if (t - challenger_since_ >= config_.takeover_seconds) {
            primary = challenger;
            challenger_id_ = 0;
        }
    }

    if (!primary) {
        challenger_id_ = 0;
        const Track *largest = nullptr;
        const Track *second = nullptr;
        for (const Track &track : tracks) {
            if (!detected_now(track)) continue;
            if (!largest || track.box.area() > largest->box.area()) {
                second = largest;
                largest = &track;
            } else if (!second || track.box.area() > second->box.area()) {
                second = &track;
            }
        }
        const bool eligible = largest && largest->hits >= config_.min_hits_for_primary &&
                              largest->score >= config_.min_primary_score &&
                              largest->box.w >= config_.min_primary_width_fraction * frame_width;
        const bool dominant = largest && (!second || largest->box.area() >= config_.dominance_ratio * second->box.area());
        if (eligible && dominant) primary = largest;
    }

    primary_id_ = primary ? primary->id : 0;

    PolicyDecision decision;
    if (primary) decision.primary_face = primary->box;
    for (const Track &track : tracks) {
        if (&track == primary) continue;
        const double age = t - track.last_seen;
        if (age > config_.blur_persistence_seconds) continue;
        const float growth = 1.0f + config_.stale_growth * static_cast<float>(age / config_.blur_persistence_seconds);
        decision.blur_boxes.push_back(track.box.scaled(config_.blur_box_scale * growth));
    }
    return decision;
}

}  // namespace vircam
