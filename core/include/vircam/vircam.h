/*
 * Vircam core C API. Shared by the macOS (Swift) and Linux (C++) shells.
 *
 * Frames are BGRA8 (bytes in memory: B, G, R, A). The engine never passes the raw
 * input through: a frame is either "protected" (primary person sharp, everything else
 * blurred) or fully blurred.
 */
#ifndef VIRCAM_H
#define VIRCAM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t *data;
    int32_t width;
    int32_t height;
    int32_t stride; /* bytes per row, >= width * 4 */
} vircam_image;

/*
 * A soft mask of one person: one float per pixel in [0, 1] (1 = person), covering the
 * whole frame at any resolution (e.g. Apple Vision's person instance masks).
 */
typedef struct {
    const float *data;
    int32_t width;
    int32_t height;
    int32_t stride; /* bytes per row, >= width * 4 */
} vircam_person_mask;

typedef enum {
    VIRCAM_OK = 0,
    VIRCAM_ERR_INVALID_ARGUMENT = 1,
    VIRCAM_ERR_INTERNAL = 2,
} vircam_status;

typedef enum {
    VIRCAM_FRAME_PROTECTED = 0, /* primary person sharp, everything else blurred */
    VIRCAM_FRAME_FULL_BLUR = 1, /* fail-closed: nothing kept sharp */
} vircam_frame_mode;

typedef struct {
    vircam_frame_mode mode;
    int32_t faces_detected;  /* faces detected in this frame */
    int32_t faces_blurred;   /* non-primary face regions forced to blur (includes recently lost faces) */
    int32_t used_person_mask; /* 1 if the sharp region came from a person mask, 0 if from the face alone */
    double process_ms;
} vircam_frame_info;

typedef struct vircam_engine vircam_engine;

/*
 * `model_dir` must contain face_detection_yunet_2023mar.onnx.
 * Returns NULL on failure; if `error` is non-NULL, a description of the failure is
 * written to it (up to `error_size` bytes, NUL-terminated).
 */
vircam_engine *vircam_engine_create(const char *model_dir, char *error, int32_t error_size);
void vircam_engine_destroy(vircam_engine *engine);

/* Draws the privacy decision on output frames (green = kept sharp, red = forced blur). */
void vircam_engine_set_debug_overlay(vircam_engine *engine, int32_t enabled);

/*
 * Processes one frame. `in` and `out` must have equal dimensions and must not alias.
 * `timestamp_seconds` drives tracking and persistence; if it goes backwards (e.g. after
 * switching cameras), tracking state is reset.
 * If face detection fails, the frame is fully blurred and VIRCAM_OK is returned.
 * If the status is not VIRCAM_OK, the contents of `out` are undefined and the caller
 * must not display or send it.
 */
vircam_status vircam_engine_process(vircam_engine *engine,
                                    const vircam_image *in,
                                    vircam_image *out,
                                    double timestamp_seconds,
                                    vircam_frame_info *info);

/*
 * Like vircam_engine_process, with one mask per person detected in this frame. The
 * person whose mask covers the primary face is kept sharp, following their outline;
 * everyone else is blurred. If no mask covers the primary face, the sharp region falls
 * back to a head-and-shoulders shape around it. `masks` may be NULL if `mask_count` is 0.
 */
vircam_status vircam_engine_process_with_masks(vircam_engine *engine,
                                               const vircam_image *in,
                                               vircam_image *out,
                                               double timestamp_seconds,
                                               const vircam_person_mask *masks,
                                               int32_t mask_count,
                                               vircam_frame_info *info);

#ifdef __cplusplus
}
#endif

#endif /* VIRCAM_H */
