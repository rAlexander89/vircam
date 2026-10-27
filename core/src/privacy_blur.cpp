#include "privacy_blur.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace viracm {
namespace {

// Pixels excluded by a weight function still count this much, so a cell surrounded
// only by excluded pixels falls back to an ordinary blur instead of dividing by zero.
constexpr float kMinWeight = 0.02f;

std::vector<float> gaussian_kernel(float sigma) {
    const int radius = std::max(1, static_cast<int>(std::ceil(3 * sigma)));
    std::vector<float> kernel(2 * radius + 1);
    float sum = 0;
    for (int i = -radius; i <= radius; ++i) {
        kernel[i + radius] = std::exp(-0.5f * i * i / (sigma * sigma));
        sum += kernel[i + radius];
    }
    for (float &k : kernel) k /= sum;
    return kernel;
}

}  // namespace

void GaussianBlur::build(const viracm_image &in, int downsample, float sigma, const WeightFn &weight) {
    const int factor = std::max(1, downsample);
    scale_ = static_cast<float>(factor);
    cols_ = (in.width + factor - 1) / factor;
    rows_ = (in.height + factor - 1) / factor;

    std::vector<uint32_t> sums(static_cast<size_t>(cols_) * rows_ * 3, 0);
    std::vector<uint32_t> counts(static_cast<size_t>(cols_) * rows_, 0);
    for (int y = 0; y < in.height; ++y) {
        const uint8_t *row = in.data + static_cast<size_t>(y) * in.stride;
        uint32_t *sum_row = &sums[static_cast<size_t>(y / factor) * cols_ * 3];
        uint32_t *count_row = &counts[static_cast<size_t>(y / factor) * cols_];
        for (int cx = 0; cx < cols_; ++cx) {
            const int x_end = std::min(in.width, (cx + 1) * factor);
            uint32_t b = 0, g = 0, r = 0;
            for (int x = cx * factor; x < x_end; ++x) {
                b += row[x * 4 + 0];
                g += row[x * 4 + 1];
                r += row[x * 4 + 2];
            }
            sum_row[cx * 3 + 0] += b;
            sum_row[cx * 3 + 1] += g;
            sum_row[cx * 3 + 2] += r;
            count_row[cx] += x_end - cx * factor;
        }
    }

    cells_.resize(static_cast<size_t>(cols_) * rows_ * 4);
    for (int cy = 0; cy < rows_; ++cy) {
        for (int cx = 0; cx < cols_; ++cx) {
            const size_t i = static_cast<size_t>(cy) * cols_ + cx;
            const float w = weight ? std::max(kMinWeight, weight((cx + 0.5f) * scale_, (cy + 0.5f) * scale_)) : 1.0f;
            for (int c = 0; c < 3; ++c) cells_[i * 4 + c] = w * static_cast<float>(sums[i * 3 + c]) / counts[i];
            cells_[i * 4 + 3] = w;
        }
    }
    blur_cells(sigma / scale_);
    normalize();
}

void GaussianBlur::build_coarser(const GaussianBlur &source, float sigma) {
    scale_ = source.scale_ * 2;
    cols_ = (source.cols_ + 1) / 2;
    rows_ = (source.rows_ + 1) / 2;
    cells_.assign(static_cast<size_t>(cols_) * rows_ * 4, 0.0f);
    for (int y = 0; y < source.rows_; ++y) {
        for (int x = 0; x < source.cols_; ++x) {
            const float *p = &source.cells_[(static_cast<size_t>(y) * source.cols_ + x) * 4];
            float *d = &cells_[(static_cast<size_t>(y / 2) * cols_ + x / 2) * 4];
            for (int c = 0; c < 3; ++c) d[c] += p[c];
            d[3] += 1;
        }
    }
    blur_cells(sigma / scale_);
    normalize();
}

// Separable Gaussian over all four channels, clamping at the edges.
void GaussianBlur::blur_cells(float sigma_cells) {
    if (sigma_cells <= 0) return;
    const std::vector<float> kernel = gaussian_kernel(sigma_cells);
    const int radius = static_cast<int>(kernel.size() / 2);
    std::vector<float> tmp(cells_.size());

    for (int y = 0; y < rows_; ++y) {
        for (int x = 0; x < cols_; ++x) {
            float acc[4] = {0, 0, 0, 0};
            for (int k = -radius; k <= radius; ++k) {
                const int xx = std::clamp(x + k, 0, cols_ - 1);
                const float *p = &cells_[(static_cast<size_t>(y) * cols_ + xx) * 4];
                const float kw = kernel[k + radius];
                for (int c = 0; c < 4; ++c) acc[c] += kw * p[c];
            }
            std::copy_n(acc, 4, &tmp[(static_cast<size_t>(y) * cols_ + x) * 4]);
        }
    }
    for (int y = 0; y < rows_; ++y) {
        for (int x = 0; x < cols_; ++x) {
            float acc[4] = {0, 0, 0, 0};
            for (int k = -radius; k <= radius; ++k) {
                const int yy = std::clamp(y + k, 0, rows_ - 1);
                const float *p = &tmp[(static_cast<size_t>(yy) * cols_ + x) * 4];
                const float kw = kernel[k + radius];
                for (int c = 0; c < 4; ++c) acc[c] += kw * p[c];
            }
            std::copy_n(acc, 4, &cells_[(static_cast<size_t>(y) * cols_ + x) * 4]);
        }
    }
}

// Divides out the weights, leaving plain colors with weight 1.
void GaussianBlur::normalize() {
    for (size_t i = 0; i < cells_.size(); i += 4) {
        const float w = cells_[i + 3];
        for (int c = 0; c < 3; ++c) cells_[i + c] /= w;
        cells_[i + 3] = 1;
    }
}

void GaussianBlur::sample(float x, float y, float bgr[3]) const {
    const float fx = std::clamp(x / scale_ - 0.5f, 0.0f, static_cast<float>(cols_ - 1));
    const float fy = std::clamp(y / scale_ - 0.5f, 0.0f, static_cast<float>(rows_ - 1));
    const int x0 = static_cast<int>(fx), y0 = static_cast<int>(fy);
    const int x1 = std::min(x0 + 1, cols_ - 1), y1 = std::min(y0 + 1, rows_ - 1);
    const float wx = fx - x0, wy = fy - y0;
    const float *p00 = &cells_[(static_cast<size_t>(y0) * cols_ + x0) * 4];
    const float *p01 = &cells_[(static_cast<size_t>(y0) * cols_ + x1) * 4];
    const float *p10 = &cells_[(static_cast<size_t>(y1) * cols_ + x0) * 4];
    const float *p11 = &cells_[(static_cast<size_t>(y1) * cols_ + x1) * 4];
    for (int c = 0; c < 3; ++c) {
        const float top = p00[c] + wx * (p01[c] - p00[c]);
        const float bottom = p10[c] + wx * (p11[c] - p10[c]);
        bgr[c] = top + wy * (bottom - top);
    }
}

void GaussianBlur::render(viracm_image &out, int x0, int y0, int x1, int y1) const {
    x0 = std::max(0, x0);
    y0 = std::max(0, y0);
    x1 = std::min(out.width, x1);
    y1 = std::min(out.height, y1);
    if (x0 >= x1 || y0 >= y1) return;

    // Bilinear sampling positions per column, shared by every row.
    const int span = x1 - x0;
    std::vector<int> cx0(span), cx1(span);
    std::vector<float> wx(span);
    for (int i = 0; i < span; ++i) {
        const float fx = std::clamp((x0 + i + 0.5f) / scale_ - 0.5f, 0.0f, static_cast<float>(cols_ - 1));
        cx0[i] = static_cast<int>(fx);
        cx1[i] = std::min(cx0[i] + 1, cols_ - 1);
        wx[i] = fx - cx0[i];
    }
    // Each output row: blend the two neighboring cell rows once, then interpolate across.
    std::vector<float> row(static_cast<size_t>(cols_) * 3);
    for (int y = y0; y < y1; ++y) {
        const float fy = std::clamp((y + 0.5f) / scale_ - 0.5f, 0.0f, static_cast<float>(rows_ - 1));
        const int ry0 = static_cast<int>(fy);
        const int ry1 = std::min(ry0 + 1, rows_ - 1);
        const float wy = fy - ry0;
        const float *r0 = &cells_[static_cast<size_t>(ry0) * cols_ * 4];
        const float *r1 = &cells_[static_cast<size_t>(ry1) * cols_ * 4];
        for (int cx = 0; cx < cols_; ++cx)
            for (int c = 0; c < 3; ++c) row[cx * 3 + c] = r0[cx * 4 + c] + wy * (r1[cx * 4 + c] - r0[cx * 4 + c]);

        uint8_t *dst = out.data + static_cast<size_t>(y) * out.stride;
        for (int i = 0; i < span; ++i) {
            uint8_t *px = dst + (x0 + i) * 4;
            const float *a = &row[cx0[i] * 3];
            const float *b = &row[cx1[i] * 3];
            for (int c = 0; c < 3; ++c)
                px[c] = static_cast<uint8_t>(std::clamp(a[c] + wx[i] * (b[c] - a[c]), 0.0f, 255.0f) + 0.5f);
            px[3] = 255;
        }
    }
}

void privacy_blur(const viracm_image &in, viracm_image &out) {
    GaussianBlur blur;
    blur.build(in, kBlurDownsample, in.width * kBlurSigmaFraction);
    blur.render(out);
}

}  // namespace viracm
