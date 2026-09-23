#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// True when the native dlib bridge was compiled and linked (not the stub).
bool prowser_dlib_bridge_linked(void);

/// Load shape predictor + face recognition ResNet from `.dat` paths. Returns false on error.
bool prowser_dlib_load_models(const char *shape_predictor_path, const char *face_recognition_resnet_path);

void prowser_dlib_unload_models(void);

bool prowser_dlib_models_are_loaded(void);

/// Face box in pixel coordinates: top, right, bottom, left (dlib / face_recognition convention).
typedef struct {
    int top;
    int right;
    int bottom;
    int left;
} ProwserFaceRect;

/// Max faces returned per call.
#define PROWSER_DLIB_MAX_FACES 32
#define PROWSER_DLIB_ENCODING_DIM 128

/// Detect faces and compute 128-D encodings on RGB8 image (row-major, `width * 3` bytes per row).
/// `encodings_out` must hold at least `max_faces * PROWSER_DLIB_ENCODING_DIM` floats.
/// `rects_out` must hold at least `max_faces` rects.
/// HOG detections on last successful `prowser_dlib_encode_faces_rgb` call (before encoding skips).
int prowser_dlib_last_hog_face_count(void);

/// Returns number of faces written, or -1 on error.
int prowser_dlib_encode_faces_rgb(
    const uint8_t *rgb,
    int32_t width,
    int32_t height,
    int32_t bytes_per_row,
    float *encodings_out,
    ProwserFaceRect *rects_out,
    int32_t max_faces);

/// Minimum Euclidean distance from `unknown` to any vector in `known` (count vectors). Returns -1 on error.
double prowser_dlib_min_face_distance(
    const float *known_encodings,
    int32_t known_count,
    const float *unknown_encoding);

#ifdef __cplusplus
}
#endif
