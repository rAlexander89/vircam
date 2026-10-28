#pragma once

#include <algorithm>

namespace vircam {

// Axis-aligned box in pixels, top-left origin.
struct Box {
    float x = 0, y = 0, w = 0, h = 0;

    float area() const { return std::max(0.0f, w) * std::max(0.0f, h); }
    float cx() const { return x + w / 2; }
    float cy() const { return y + h / 2; }
    Box scaled(float s) const { return {cx() - w * s / 2, cy() - h * s / 2, w * s, h * s}; }
};

inline float iou(const Box &a, const Box &b) {
    const float x0 = std::max(a.x, b.x), y0 = std::max(a.y, b.y);
    const float x1 = std::min(a.x + a.w, b.x + b.w), y1 = std::min(a.y + a.h, b.y + b.h);
    const float inter = std::max(0.0f, x1 - x0) * std::max(0.0f, y1 - y0);
    const float uni = a.area() + b.area() - inter;
    return uni > 0 ? inter / uni : 0;
}

struct Face {
    Box box;
    float score = 0;
};

}  // namespace vircam
