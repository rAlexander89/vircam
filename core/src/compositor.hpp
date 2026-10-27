#pragma once

#include "primary_region.hpp"
#include "privacy_blur.hpp"
#include "privacy_policy.hpp"
#include "viracm/viracm.h"

namespace viracm {

// Builds the output frame: everything blurred, except the primary person's region.
// Non-primary faces that overlap that region get a stronger blur; faces elsewhere are
// already blurred with the background.
class Compositor {
public:
    // `primary` is ignored (and the whole frame blurred) when the decision has no primary face.
    void render(const viracm_image &in, viracm_image &out, const PolicyDecision &decision, const AlphaMap &primary);

    // Outlines the decision on `out`: green = kept sharp, red = forced blur.
    static void draw_debug(viracm_image &out, const PolicyDecision &decision);

private:
    GaussianBlur background_;
    GaussianBlur heavy_;
};

}  // namespace viracm
