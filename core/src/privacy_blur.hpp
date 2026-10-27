#pragma once

#include <functional>
#include <vector>

#include "viracm/viracm.h"

namespace viracm {

// A strong Gaussian blur computed on a downscaled grid, then upsampled smoothly.
// Blurring at low resolution keeps large blur radii cheap.
class GaussianBlur {
public:
    // 1 = fully counts toward the blur, ~0 = excluded. Evaluated at grid cell centers
    // in full-resolution pixel coordinates.
    using WeightFn = std::function<float(float x, float y)>;

    // Averages `in` into cells of `downsample` x `downsample` pixels and blurs them with
    // a Gaussian of `sigma` full-resolution pixels. With `weight`, each cell's color is
    // weighted (normalized convolution), so excluded regions do not bleed their color
    // into the blur.
    void build(const viracm_image &in, int downsample, float sigma, const WeightFn &weight = nullptr);
    // A blurrier version of `source`: halves its resolution, then blurs with `sigma`
    // full-resolution pixels.
    void build_coarser(const GaussianBlur &source, float sigma);

    // Writes the blurred image into [x0, x1) x [y0, y1) of `out`, which must be the size
    // of the image `build` was called with.
    void render(viracm_image &out, int x0, int y0, int x1, int y1) const;
    void render(viracm_image &out) const { render(out, 0, 0, out.width, out.height); }
    // The blurred color at full-resolution pixel (x, y), as B, G, R.
    void sample(float x, float y, float bgr[3]) const;

private:
    void blur_cells(float sigma_cells);
    void normalize();

    float scale_ = 1;  // full-resolution pixels per cell
    int cols_ = 0, rows_ = 0;
    std::vector<float> cells_;  // cols_ x rows_ x 4: B, G, R premultiplied by weight, then weight
};

// Downsampling factor and blur strength used for privacy blurs. Sigma is a fraction of
// frame width (1280 px -> 16 px): soft enough to keep the scene readable, while faces
// in the background lose their features.
constexpr int kBlurDownsample = 8;
constexpr float kBlurSigmaFraction = 1.0f / 80;

// Writes a privacy-blurred copy of `in` into `out` (same size).
void privacy_blur(const viracm_image &in, viracm_image &out);

}  // namespace viracm
