#include "primary_region.hpp"

#include <cmath>

namespace viracm {
namespace {

// Mask values are remapped so [kMaskLow, kMaskHigh] becomes [0, 1]. This fills the
// noisy interior of Vision masks (hair, clothing often read 0.6-0.9) and keeps a short
// soft edge.
constexpr float kMaskLow = 0.3f;
constexpr float kMaskHigh = 0.7f;
// A mask must cover at least this fraction of the primary face box to be the user's.
constexpr float kMinFaceCoverage = 0.5f;

float sharpen(float m) {
    const float t = std::clamp((m - kMaskLow) / (kMaskHigh - kMaskLow), 0.0f, 1.0f);
    return t * t * (3 - 2 * t);  // smoothstep
}

float mask_value(const viracm_person_mask &mask, int mx, int my) {
    const auto *row = reinterpret_cast<const float *>(reinterpret_cast<const uint8_t *>(mask.data) +
                                                      static_cast<size_t>(my) * mask.stride);
    return row[mx];
}

}  // namespace

PixelRange clip(float x0, float y0, float x1, float y1, int width, int height) {
    return {std::max(0, static_cast<int>(std::floor(x0))), std::max(0, static_cast<int>(std::floor(y0))),
            std::min(width, static_cast<int>(std::ceil(x1))), std::min(height, static_cast<int>(std::ceil(y1)))};
}

AlphaMap head_and_shoulders(const Box &face, int width, int height) {
    const float w = face.w, h = face.h, cx = face.cx(), cy = face.cy();
    const float head_cx = cx, head_cy = cy - 0.05f * h, rx = 0.7f * w, ry = 0.8f * h;
    const float neck_x0 = cx - 0.45f * w, neck_x1 = cx + 0.45f * w, neck_y0 = cy, neck_y1 = cy + 1.2f * h;
    const float torso_x0 = cx - 1.6f * w, torso_x1 = cx + 1.6f * w, torso_y0 = cy + 0.95f * h;
    const float feather = std::max(2.0f, 0.06f * w);

    AlphaMap map;
    map.bounds = clip(std::min(head_cx - rx, torso_x0) - feather, head_cy - ry - feather,
                      std::max(head_cx + rx, torso_x1) + feather, static_cast<float>(height), width, height);
    if (map.bounds.empty()) return map;
    const int bw = map.bounds.x1 - map.bounds.x0;
    map.alpha.resize(static_cast<size_t>(bw) * (map.bounds.y1 - map.bounds.y0));
    for (int y = map.bounds.y0; y < map.bounds.y1; ++y) {
        const float py = y + 0.5f;
        for (int x = map.bounds.x0; x < map.bounds.x1; ++x) {
            const float px = x + 0.5f;
            // Signed distances, negative inside.
            const float dx = (px - head_cx) / rx, dy = (py - head_cy) / ry;
            const float head = (std::sqrt(dx * dx + dy * dy) - 1.0f) * std::min(rx, ry);
            const float neck = std::max({neck_x0 - px, px - neck_x1, neck_y0 - py, py - neck_y1});
            const float torso = std::max({torso_x0 - px, px - torso_x1, torso_y0 - py});
            map.alpha[static_cast<size_t>(y - map.bounds.y0) * bw + (x - map.bounds.x0)] =
                std::clamp(0.5f - std::min({head, neck, torso}) / feather, 0.0f, 1.0f);
        }
    }
    return map;
}

AlphaMap from_person_mask(const viracm_person_mask &mask, int width, int height) {
    const float sx = static_cast<float>(mask.width) / width;  // mask pixels per frame pixel
    const float sy = static_cast<float>(mask.height) / height;

    // Bounds: mask pixels that are part of the person, plus one mask pixel of margin.
    int mx0 = mask.width, my0 = mask.height, mx1 = -1, my1 = -1;
    for (int my = 0; my < mask.height; ++my) {
        for (int mx = 0; mx < mask.width; ++mx) {
            if (mask_value(mask, mx, my) <= kMaskLow) continue;
            mx0 = std::min(mx0, mx);
            my0 = std::min(my0, my);
            mx1 = std::max(mx1, mx);
            my1 = std::max(my1, my);
        }
    }
    AlphaMap map;
    if (mx1 < 0) return map;
    map.bounds = clip((mx0 - 1) / sx, (my0 - 1) / sy, (mx1 + 2) / sx, (my1 + 2) / sy, width, height);
    if (map.bounds.empty()) return map;

    // Bilinear upsample, then sharpen. Per-column sampling positions are shared by rows.
    const int bw = map.bounds.x1 - map.bounds.x0;
    map.alpha.resize(static_cast<size_t>(bw) * (map.bounds.y1 - map.bounds.y0));
    std::vector<int> cx0(bw), cx1(bw);
    std::vector<float> wx(bw);
    for (int i = 0; i < bw; ++i) {
        const float fx = std::clamp((map.bounds.x0 + i + 0.5f) * sx - 0.5f, 0.0f, static_cast<float>(mask.width - 1));
        cx0[i] = static_cast<int>(fx);
        cx1[i] = std::min(cx0[i] + 1, mask.width - 1);
        wx[i] = fx - cx0[i];
    }
    for (int y = map.bounds.y0; y < map.bounds.y1; ++y) {
        const float fy = std::clamp((y + 0.5f) * sy - 0.5f, 0.0f, static_cast<float>(mask.height - 1));
        const int my0r = static_cast<int>(fy);
        const int my1r = std::min(my0r + 1, mask.height - 1);
        const float wy = fy - my0r;
        float *dst = &map.alpha[static_cast<size_t>(y - map.bounds.y0) * bw];
        for (int i = 0; i < bw; ++i) {
            const float top = mask_value(mask, cx0[i], my0r) + wx[i] * (mask_value(mask, cx1[i], my0r) - mask_value(mask, cx0[i], my0r));
            const float bottom = mask_value(mask, cx0[i], my1r) + wx[i] * (mask_value(mask, cx1[i], my1r) - mask_value(mask, cx0[i], my1r));
            dst[i] = sharpen(top + wy * (bottom - top));
        }
    }
    return map;
}

int select_person_mask(const viracm_person_mask *masks, int count, const Box &face, int width, int height) {
    int best = -1;
    float best_coverage = kMinFaceCoverage;
    for (int i = 0; i < count; ++i) {
        const viracm_person_mask &mask = masks[i];
        if (!mask.data || mask.width <= 0 || mask.height <= 0 || mask.stride < mask.width * 4) continue;
        const float sx = static_cast<float>(mask.width) / width;
        const float sy = static_cast<float>(mask.height) / height;
        const PixelRange r = clip(face.x * sx, face.y * sy, (face.x + face.w) * sx, (face.y + face.h) * sy,
                                  mask.width, mask.height);
        if (r.empty()) continue;
        float sum = 0;
        for (int my = r.y0; my < r.y1; ++my)
            for (int mx = r.x0; mx < r.x1; ++mx) sum += sharpen(mask_value(mask, mx, my));
        const float coverage = sum / ((r.x1 - r.x0) * (r.y1 - r.y0));
        if (coverage > best_coverage) {
            best_coverage = coverage;
            best = i;
        }
    }
    return best;
}

}  // namespace viracm
