#include "face_tracker.hpp"

#include <cmath>
#include <tuple>

namespace vircam {
namespace {

// How strongly a detection belongs to a track. Overlap first; a fast-moving face with
// no overlap still matches if its center moved less than 60% of the face width.
float affinity(const Box &track, const Box &detection) {
    const float overlap = iou(track, detection);
    if (overlap > 0.2f) return overlap;
    const float distance = std::hypot(track.cx() - detection.cx(), track.cy() - detection.cy());
    return distance < 0.6f * std::max(track.w, detection.w) ? 0.01f : 0.0f;
}

}  // namespace

void FaceTracker::update(const std::vector<Face> &faces, double t) {
    // Greedy assignment, strongest pairs first.
    std::vector<std::tuple<float, size_t, size_t>> pairs;
    for (size_t ti = 0; ti < tracks_.size(); ++ti) {
        for (size_t fi = 0; fi < faces.size(); ++fi) {
            const float a = affinity(tracks_[ti].box, faces[fi].box);
            if (a > 0) pairs.emplace_back(a, ti, fi);
        }
    }
    std::sort(pairs.begin(), pairs.end(), [](const auto &a, const auto &b) { return std::get<0>(a) > std::get<0>(b); });

    std::vector<bool> track_used(tracks_.size(), false), face_used(faces.size(), false);
    for (const auto &[a, ti, fi] : pairs) {
        if (track_used[ti] || face_used[fi]) continue;
        track_used[ti] = face_used[fi] = true;
        Track &track = tracks_[ti];
        track.box = faces[fi].box;
        track.score = faces[fi].score;
        track.last_seen = t;
        ++track.hits;
    }

    tracks_.erase(std::remove_if(tracks_.begin(), tracks_.end(),
                                 [&](const Track &track) { return t - track.last_seen > max_age_; }),
                  tracks_.end());

    for (size_t fi = 0; fi < faces.size(); ++fi) {
        if (!face_used[fi]) tracks_.push_back({next_id_++, faces[fi].box, faces[fi].score, t, t, 1});
    }
}

}  // namespace vircam
