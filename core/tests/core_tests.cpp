#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "compositor.hpp"
#include "primary_region.hpp"
#include "face_tracker.hpp"
#include "privacy_policy.hpp"
#include "viracm/viracm.h"

#define CHECK(cond)                                                                       \
    do {                                                                                  \
        if (!(cond)) {                                                                    \
            std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
            std::exit(1);                                                                 \
        }                                                                                 \
    } while (0)

using namespace viracm;

namespace {

constexpr double kFrame = 1.0 / 30;
constexpr int kWidth = 1280;

struct Frame {
    std::vector<uint8_t> pixels;
    viracm_image image;
    Frame(int w, int h) : pixels(static_cast<size_t>(w) * h * 4), image{nullptr, w, h, w * 4} {
        image.data = pixels.data();
    }
    const uint8_t *at(int x, int y) const { return &pixels[(static_cast<size_t>(y) * image.width + x) * 4]; }
};

// A 1-pixel checkerboard: the finest possible detail. A privacy blur must erase it.
Frame checkerboard(int w, int h) {
    Frame f(w, h);
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) {
            uint8_t v = ((x + y) % 2) ? 255 : 0;
            uint8_t *p = &f.pixels[(static_cast<size_t>(y) * w + x) * 4];
            p[0] = p[1] = p[2] = v;
            p[3] = 255;
        }
    return f;
}

bool is_blurred_gray(const uint8_t *p) { return std::abs(p[0] - 128) <= 3; }
bool is_original(const uint8_t *p) { return p[0] == 0 || p[0] == 255; }

Face face(float x, float y, float size, float score = 0.95f) { return {{x, y, size, size}, score}; }

// Renders with the head-and-shoulders region (no person mask).
void render(Compositor &compositor, Frame &in, Frame &out, const PolicyDecision &d) {
    AlphaMap primary;
    if (d.primary_face) primary = head_and_shoulders(*d.primary_face, in.image.width, in.image.height);
    compositor.render(in.image, out.image, d, primary);
}

// A low-resolution person mask (like Vision's) containing one ellipse, given in frame
// coordinates for a kWidth x 720 frame.
struct Mask {
    std::vector<float> values;
    viracm_person_mask mask;
    Mask(float cx, float cy, float rx, float ry, int w = 256, int h = 144) : values(static_cast<size_t>(w) * h, 0.0f) {
        const float s = static_cast<float>(w) / kWidth;
        for (int y = 0; y < h; ++y)
            for (int x = 0; x < w; ++x)
                if (std::hypot((x + 0.5f - cx * s) / (rx * s), (y + 0.5f - cy * s) / (ry * s)) < 1) values[y * w + x] = 1;
        mask = {values.data(), w, h, w * 4};
    }
};

// Runs tracker + policy over `frames` frames of the same detections, starting at `t`.
PolicyDecision run(FaceTracker &tracker, PrivacyPolicy &policy, const std::vector<Face> &faces, double &t,
                   int frames) {
    PolicyDecision decision;
    for (int i = 0; i < frames; ++i) {
        tracker.update(faces, t);
        decision = policy.decide(tracker.tracks(), t, kWidth);
        t += kFrame;
    }
    return decision;
}

// --- tracker ---

void test_tracker_keeps_identity_and_expires() {
    FaceTracker tracker(1.0);
    tracker.update({face(100, 100, 80)}, 0);
    const int id = tracker.tracks()[0].id;
    tracker.update({face(110, 105, 80)}, kFrame);  // moved slightly
    CHECK(tracker.tracks().size() == 1 && tracker.tracks()[0].id == id && tracker.tracks()[0].hits == 2);
    tracker.update({}, 0.5);  // missed, still kept
    CHECK(tracker.tracks().size() == 1);
    tracker.update({}, 1.2);  // gone longer than max age
    CHECK(tracker.tracks().empty());
}

void test_tracker_follows_fast_motion() {
    FaceTracker tracker(1.0);
    tracker.update({face(100, 100, 80)}, 0);
    const int id = tracker.tracks()[0].id;
    tracker.update({face(140, 100, 80)}, kFrame);  // no overlap issue: IoU ~0.33
    tracker.update({face(185, 100, 80)}, 2 * kFrame);  // IoU ~0.28
    CHECK(tracker.tracks().size() == 1 && tracker.tracks()[0].id == id);
}

// --- policy ---

void test_primary_needs_confirmation() {
    FaceTracker tracker(1.0);
    PrivacyPolicy policy;
    double t = 0;
    CHECK(!run(tracker, policy, {face(500, 200, 200)}, t, 2).primary_face);
    CHECK(run(tracker, policy, {face(500, 200, 200)}, t, 1).primary_face);
}

void test_low_confidence_or_tiny_face_is_not_primary() {
    FaceTracker tracker(1.0);
    PrivacyPolicy policy;
    double t = 0;
    CHECK(!run(tracker, policy, {face(500, 200, 200, 0.7f)}, t, 10).primary_face);
    FaceTracker tracker2(1.0);
    PrivacyPolicy policy2;
    t = 0;
    CHECK(!run(tracker2, policy2, {face(500, 200, 30)}, t, 10).primary_face);
}

void test_ambiguous_faces_fail_closed() {
    FaceTracker tracker(1.0);
    PrivacyPolicy policy;
    double t = 0;
    // Two similar-size faces: nobody can be confirmed as the user.
    const PolicyDecision d = run(tracker, policy, {face(200, 200, 200), face(800, 200, 190)}, t, 10);
    CHECK(!d.primary_face);
}

void test_background_face_blurred() {
    FaceTracker tracker(1.0);
    PrivacyPolicy policy;
    double t = 0;
    const PolicyDecision d = run(tracker, policy, {face(500, 200, 200), face(1000, 100, 60)}, t, 5);
    CHECK(d.primary_face && d.primary_face->x == 500);
    CHECK(d.blur_boxes.size() == 1);
    // Enlarged around the background face.
    CHECK(d.blur_boxes[0].w > 60 && d.blur_boxes[0].x < 1000);
}

void test_lost_face_stays_blurred_then_expires() {
    FaceTracker tracker(1.0);
    PrivacyPolicy policy;
    double t = 0;
    run(tracker, policy, {face(500, 200, 200), face(1000, 100, 60)}, t, 5);
    // Background face disappears (missed detection); keep blurring where it was.
    PolicyDecision d = run(tracker, policy, {face(500, 200, 200)}, t, 15);  // 0.5 s
    CHECK(d.blur_boxes.size() == 1);
    CHECK(d.blur_boxes[0].w > 60 * 1.3f);  // grows while undetected
    d = run(tracker, policy, {face(500, 200, 200)}, t, 10);  // 0.83 s total
    CHECK(d.blur_boxes.empty());
}

void test_takeover_requires_sustained_larger_face() {
    FaceTracker tracker(1.0);
    PrivacyPolicy policy;
    double t = 0;
    run(tracker, policy, {face(500, 200, 150)}, t, 5);
    // Someone leans in with a much larger face for 0.4 s: primary must not switch.
    PolicyDecision d = run(tracker, policy, {face(500, 200, 150), face(100, 50, 300)}, t, 12);
    CHECK(d.primary_face && d.primary_face->x == 500);
    CHECK(d.blur_boxes.size() == 1);
    // Still there past 0.5 s: takeover.
    d = run(tracker, policy, {face(500, 200, 150), face(100, 50, 300)}, t, 6);
    CHECK(d.primary_face && d.primary_face->x == 100);
}

void test_lost_primary_fails_closed_after_grace() {
    FaceTracker tracker(1.5);
    PrivacyPolicy policy;
    double t = 0;
    run(tracker, policy, {face(500, 200, 200)}, t, 5);
    CHECK(run(tracker, policy, {}, t, 25).primary_face);  // 0.83 s: within grace
    CHECK(!run(tracker, policy, {}, t, 10).primary_face);  // > 1 s
}

// --- compositor ---

void test_compositor_regions() {
    Frame in = checkerboard(kWidth, 720), out(kWidth, 720);
    Compositor compositor;
    PolicyDecision d;
    d.primary_face = Box{540, 200, 200, 200};
    d.blur_boxes = {Box{1000, 100, 100, 100}};
    render(compositor, in, out, d);
    CHECK(is_original(out.at(640, 300)));     // center of the primary face: sharp
    CHECK(is_original(out.at(640, 600)));     // primary's torso: sharp
    CHECK(is_blurred_gray(out.at(50, 50)));   // far background: blurred
    CHECK(is_blurred_gray(out.at(1050, 150)));  // non-primary face: blurred

    // A non-primary face box overlapping the primary region still wins.
    d.blur_boxes = {Box{600, 250, 80, 80}};
    render(compositor, in, out, d);
    CHECK(is_blurred_gray(out.at(640, 290)));
}

// A smooth horizontal gradient: survives blurring nearly unchanged, so any extra
// processing shows up as a difference.
Frame gradient(int w, int h) {
    Frame f(w, h);
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) {
            uint8_t *p = &f.pixels[(static_cast<size_t>(y) * w + x) * 4];
            p[0] = p[1] = p[2] = static_cast<uint8_t>(x * 255 / (w - 1));
            p[3] = 255;
        }
    return f;
}

void test_faces_in_blur_zone_are_not_blurred_twice() {
    Frame in = gradient(kWidth, 720), plain(kWidth, 720), with_box(kWidth, 720);
    Compositor compositor;
    PolicyDecision d;
    d.primary_face = Box{540, 200, 200, 200};
    render(compositor, in, plain, d);
    d.blur_boxes = {Box{1000, 100, 100, 100}, Box{20, 20, 260, 260}};  // small and large, outside the primary region
    render(compositor, in, with_box, d);
    CHECK(plain.pixels == with_box.pixels);
}

void test_no_halo_around_primary() {
    // Dark person region on a white background: the blurred background next to the
    // person must stay white rather than picking up the person's dark colors.
    Frame in(kWidth, 720), out(kWidth, 720);
    std::fill(in.pixels.begin(), in.pixels.end(), 255);
    const Box face{540, 200, 200, 200};
    for (int y = 0; y < 720; ++y)
        for (int x = 0; x < kWidth; ++x) {
            const bool head = std::hypot((x - 640) / 140.0, (y - 290) / 160.0) < 1.0;
            const bool torso = y > 490 && x > 320 && x < 960;
            if (head || torso) {
                uint8_t *p = &in.pixels[(static_cast<size_t>(y) * kWidth + x) * 4];
                p[0] = p[1] = p[2] = 0;
            }
        }
    Compositor compositor;
    PolicyDecision d;
    d.primary_face = face;
    render(compositor, in, out, d);
    CHECK(out.at(640 + 140 + 15, 290)[0] > 230);  // 15 px right of the head
    CHECK(out.at(320 - 15, 600)[0] > 230);        // 15 px left of the torso
}

void test_compositor_full_blur_without_primary() {
    Frame in = checkerboard(kWidth, 720), out(kWidth, 720);
    Compositor compositor;
    render(compositor, in, out, PolicyDecision{});
    for (size_t i = 0; i < out.pixels.size(); i += 4) {
        CHECK(is_blurred_gray(&out.pixels[i]));
        CHECK(out.pixels[i + 3] == 255);
    }
}

// --- person masks ---

void test_selects_mask_covering_primary_face() {
    const Box primary_face{540, 200, 200, 200};
    Mask other(1000, 300, 120, 250), user(640, 400, 250, 350);
    const viracm_person_mask masks[] = {other.mask, user.mask};
    CHECK(select_person_mask(masks, 2, primary_face, kWidth, 720) == 1);
    CHECK(select_person_mask(masks, 1, primary_face, kWidth, 720) == -1);  // only the other person
    CHECK(select_person_mask(nullptr, 0, primary_face, kWidth, 720) == -1);
}

void test_mask_region_is_tighter_than_head_shape() {
    // A narrow person: background just beside their head is inside the head-and-shoulders
    // shape, but must be blurred when the person's mask is known.
    Frame in = checkerboard(kWidth, 720), out(kWidth, 720);
    const Box face{560, 200, 160, 160};
    Mask user(640, 450, 75, 300);
    PolicyDecision d;
    d.primary_face = face;
    Compositor compositor;
    compositor.render(in.image, out.image, d, from_person_mask(user.mask, kWidth, 720));
    CHECK(is_original(out.at(640, 280)));       // face: sharp
    CHECK(is_blurred_gray(out.at(640 + 95, 260)));  // beside the head, outside the mask: blurred
    CHECK(head_and_shoulders(face, kWidth, 720).at(640 + 95, 260) > 0.9f);  // the old shape kept it sharp
}

// --- engine (uses the real face model) ---

void test_engine_without_faces_fails_closed() {
    char error[256] = {0};
    viracm_engine *engine = viracm_engine_create(VIRACM_MODEL_DIR, error, sizeof(error));
    if (!engine) std::fprintf(stderr, "engine error: %s\n", error);
    CHECK(engine);
    Frame in = checkerboard(kWidth, 720), out(kWidth, 720);
    viracm_frame_info info{};
    CHECK(viracm_engine_process(engine, &in.image, &out.image, 0.0, &info) == VIRACM_OK);
    CHECK(info.mode == VIRACM_FRAME_FULL_BLUR && info.faces_detected == 0);
    CHECK(is_blurred_gray(out.at(640, 360)));
    viracm_engine_destroy(engine);
}

void test_engine_rejects_bad_arguments() {
    viracm_engine *engine = viracm_engine_create(VIRACM_MODEL_DIR, nullptr, 0);
    Frame in(64, 64), small(32, 32);
    CHECK(viracm_engine_process(engine, &in.image, &small.image, 0.0, nullptr) == VIRACM_ERR_INVALID_ARGUMENT);
    CHECK(viracm_engine_process(engine, &in.image, &in.image, 0.0, nullptr) == VIRACM_ERR_INVALID_ARGUMENT);
    viracm_engine_destroy(engine);
    CHECK(viracm_engine_create("/nonexistent", nullptr, 0) == nullptr);
}

}  // namespace

int main() {
    test_tracker_keeps_identity_and_expires();
    test_tracker_follows_fast_motion();
    test_primary_needs_confirmation();
    test_low_confidence_or_tiny_face_is_not_primary();
    test_ambiguous_faces_fail_closed();
    test_background_face_blurred();
    test_lost_face_stays_blurred_then_expires();
    test_takeover_requires_sustained_larger_face();
    test_lost_primary_fails_closed_after_grace();
    test_compositor_regions();
    test_compositor_full_blur_without_primary();
    test_faces_in_blur_zone_are_not_blurred_twice();
    test_no_halo_around_primary();
    test_selects_mask_covering_primary_face();
    test_mask_region_is_tighter_than_head_shape();
    test_engine_without_faces_fails_closed();
    test_engine_rejects_bad_arguments();
    std::puts("all core tests passed");
    return 0;
}
