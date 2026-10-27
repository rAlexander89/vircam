/*
 * Viracm core C API. Shared by the macOS (Swift) and Linux (C++) shells.
 *
 * Frames are BGRA8 (bytes in memory: B, G, R, A). The engine never passes the raw
 * input through: a frame is either "protected" (primary person sharp, everything else
 * blurred) or fully blurred.
 */
#ifndef VIRACM_H
#define VIRACM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t *data;
    int32_t width;
    int32_t height;
    int32_t stride; /* bytes per row, >= width * 4 */
} viracm_image;

/*
 * A soft mask of one person: one float per pixel in [0, 1] (1 = person), covering the
 * whole frame at any resolution (e.g. Apple Vision's person instance masks).
 */
typedef struct {
    const float *data;
    int32_t width;
    int32_t height;
    int32_t stride; /* bytes per row, >= width * 4 */
} viracm_person_mask;

typedef enum {
    VIRACM_OK = 0,
    VIRACM_ERR_INVALID_ARGUMENT = 1,
    VIRACM_ERR_INTERNAL = 2,
} viracm_status;

typedef enum {
    VIRACM_FRAME_PROTECTED = 0, /* primary person sharp, everything else blurred */
    VIRACM_FRAME_FULL_BLUR = 1, /* fail-closed: nothing kept sharp */
} viracm_frame_mode;

typedef struct {
    viracm_frame_mode mode;
    int32_t faces_detected;  /* faces detected in this frame */
    int32_t faces_blurred;   /* non-primary face regions forced to blur (includes recently lost faces) */
    int32_t used_person_mask; /* 1 if the sharp region came from a person mask, 0 if from the face alone */
    double process_ms;
} viracm_frame_info;

typedef struct viracm_engine viracm_engine;

/*
 * `model_dir` must contain face_detection_yunet_2023mar.onnx.
 * Returns NULL on failure; if `error` is non-NULL, a description of the failure is
 * written to it (up to `error_size` bytes, NUL-terminated).
 */
viracm_engine *viracm_engine_create(const char *model_dir, char *error, int32_t error_size);
void viracm_engine_destroy(viracm_engine *engine);

/* Draws the privacy decision on output frames (green = kept sharp, red = forced blur). */
void viracm_engine_set_debug_overlay(viracm_engine *engine, int32_t enabled);

/*
 * Processes one frame. `in` and `out` must have equal dimensions and must not alias.
 * `timestamp_seconds` drives tracking and persistence; if it goes backwards (e.g. after
 * switching cameras), tracking state is reset.
 * If face detection fails, the frame is fully blurred and VIRACM_OK is returned.
 * If the status is not VIRACM_OK, the contents of `out` are undefined and the caller
 * must not display or send it.
 */
viracm_status viracm_engine_process(viracm_engine *engine,
                                    const viracm_image *in,
                                    viracm_image *out,
                                    double timestamp_seconds,
                                    viracm_frame_info *info);

/*
 * Like viracm_engine_process, with one mask per person detected in this frame. The
 * person whose mask covers the primary face is kept sharp, following their outline;
 * everyone else is blurred. If no mask covers the primary face, the sharp region falls
 * back to a head-and-shoulders shape around it. `masks` may be NULL if `mask_count` is 0.
 */
viracm_status viracm_engine_process_with_masks(viracm_engine *engine,
                                               const viracm_image *in,
                                               viracm_image *out,
                                               double timestamp_seconds,
                                               const viracm_person_mask *masks,
                                               int32_t mask_count,
                                               viracm_frame_info *info);

#ifdef __cplusplus
}
#endif

#endif /* VIRACM_H */
