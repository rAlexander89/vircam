#include "compositor.hpp"

#include <cmath>
#include <vector>

namespace vircam {
namespace {

// Non-primary faces inside the sharp region are blurred this much more than the background.
constexpr float kHeavySigmaFactor = 2.0f;

// Distance from (px, py) to the outside of `box`; <= 0 inside.
float outside_distance(const Box &box, float px, float py) {
    return std::max({box.x - px, px - (box.x + box.w), box.y - py, py - (box.y + box.h)});
}

float box_feather(const Box &box) { return std::max(2.0f, 0.1f * box.w); }

void stroke_rect(vircam_image &img, const Box &box, uint8_t b, uint8_t g, uint8_t r, int thickness) {
    const PixelRange o = clip(box.x, box.y, box.x + box.w, box.y + box.h, img.width, img.height);
    for (int y = o.y0; y < o.y1; ++y) {
        uint8_t *row = img.data + static_cast<size_t>(y) * img.stride;
        for (int x = o.x0; x < o.x1; ++x) {
            const bool edge = x < o.x0 + thickness || x >= o.x1 - thickness || y < o.y0 + thickness ||
                              y >= o.y1 - thickness;
            if (!edge) continue;
            row[x * 4 + 0] = b;
            row[x * 4 + 1] = g;
            row[x * 4 + 2] = r;
        }
    }
}

}  // namespace

void Compositor::render(const vircam_image &in, vircam_image &out, const PolicyDecision &decision,
                        const AlphaMap &primary) {
    const float sigma = in.width * kBlurSigmaFraction;

    if (!decision.primary_face) {
        background_.build(in, kBlurDownsample, sigma);
        background_.render(out);
        return;
    }

    // 1. Background blur, built only from pixels outside the primary region so the
    //    person's colors do not smear into a halo around them.
    background_.build(in, kBlurDownsample, sigma, [&](float x, float y) {
        return 1.0f - primary.at(static_cast<int>(x), static_cast<int>(y));
    });
    background_.render(out);

    // Non-primary faces that touch the primary region. Faces elsewhere are already
    // blurred with the background and need nothing more.
    const PixelRange &r = primary.bounds;
    std::vector<const Box *> overlapping;
    for (const Box &box : decision.blur_boxes) {
        const float f = box_feather(box);
        if (box.x + box.w + f > r.x0 && box.x - f < r.x1 && box.y + box.h + f > r.y0 && box.y - f < r.y1)
            overlapping.push_back(&box);
    }
    if (!overlapping.empty()) heavy_.build_coarser(background_, kHeavySigmaFactor * sigma);

    // 2. Inside the primary region: sharp, except heavily blurred where it overlaps a
    //    non-primary face. Outside it: the background blur from step 1.
    const int bw = r.x1 - r.x0;
    for (int y = r.y0; y < r.y1; ++y) {
        const float py = y + 0.5f;
        const float *alpha = &primary.alpha[static_cast<size_t>(y - r.y0) * bw];
        const uint8_t *src = in.data + static_cast<size_t>(y) * in.stride;
        uint8_t *dst = out.data + static_cast<size_t>(y) * out.stride;
        for (int x = r.x0; x < r.x1; ++x) {
            const float a = alpha[x - r.x0];
            if (a <= 0) continue;
            const float px = x + 0.5f;
            float face = 0;  // 1 inside a non-primary face box, ramping to 0 outside it
            for (const Box *box : overlapping) {
                face = std::max(face, 1.0f - std::clamp(outside_distance(*box, px, py) / box_feather(*box), 0.0f, 1.0f));
            }
            float heavy[3] = {0, 0, 0};
            if (face > 0) heavy_.sample(px, py, heavy);
            for (int c = 0; c < 3; ++c) {
                const float inside = (1 - face) * src[x * 4 + c] + face * heavy[c];
                dst[x * 4 + c] = static_cast<uint8_t>(dst[x * 4 + c] + a * (inside - dst[x * 4 + c]) + 0.5f);
            }
        }
    }
}

void Compositor::draw_debug(vircam_image &out, const PolicyDecision &decision) {
    const int thickness = std::max(2, out.width / 400);
    if (decision.primary_face) stroke_rect(out, *decision.primary_face, 0, 220, 0, thickness);
    for (const Box &box : decision.blur_boxes) stroke_rect(out, box, 0, 0, 230, thickness);
}

}  // namespace vircam
