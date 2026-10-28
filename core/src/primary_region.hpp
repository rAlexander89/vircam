#pragma once

#include <vector>

#include "types.hpp"
#include "vircam/vircam.h"

namespace vircam {

struct PixelRange {
    int x0 = 0, y0 = 0, x1 = 0, y1 = 0;  // half-open

    bool empty() const { return x0 >= x1 || y0 >= y1; }
};

PixelRange clip(float x0, float y0, float x1, float y1, int width, int height);

// How sharp each pixel of the primary person's region is: 1 = sharp, 0 = blurred.
// Only `bounds` is stored; everything outside it is 0.
struct AlphaMap {
    PixelRange bounds;
    std::vector<float> alpha;  // (bounds.x1 - bounds.x0) x (bounds.y1 - bounds.y0)

    float at(int x, int y) const {
        if (x < bounds.x0 || x >= bounds.x1 || y < bounds.y0 || y >= bounds.y1) return 0;
        return alpha[static_cast<size_t>(y - bounds.y0) * (bounds.x1 - bounds.x0) + (x - bounds.x0)];
    }
};

// Fallback when no person mask is available: a head ellipse, neck, and shoulders/torso
// placed relative to the face box.
AlphaMap head_and_shoulders(const Box &face, int width, int height);

// The person mask scaled to the frame, with its soft edge sharpened.
AlphaMap from_person_mask(const vircam_person_mask &mask, int width, int height);

// Index of the mask that best covers `face`, or -1 if none covers enough of it.
int select_person_mask(const vircam_person_mask *masks, int count, const Box &face, int width, int height);

}  // namespace vircam
