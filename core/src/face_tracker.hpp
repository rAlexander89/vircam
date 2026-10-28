#pragma once

#include <vector>

#include "types.hpp"

namespace vircam {

struct Track {
    int id = 0;
    Box box;          // last detected position
    float score = 0;  // last detection score
    double first_seen = 0;
    double last_seen = 0;
    int hits = 0;  // number of frames this face was detected in
};

// Associates detections across frames so a face that is briefly missed keeps its
// identity and its last known position.
class FaceTracker {
public:
    // Tracks not detected for longer than `max_age_seconds` are dropped.
    explicit FaceTracker(double max_age_seconds) : max_age_(max_age_seconds) {}

    void update(const std::vector<Face> &faces, double t);
    void reset() { tracks_.clear(); }
    const std::vector<Track> &tracks() const { return tracks_; }

private:
    double max_age_;
    int next_id_ = 1;
    std::vector<Track> tracks_;
};

}  // namespace vircam
