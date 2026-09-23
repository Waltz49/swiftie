#include "prowser_dlib_bridge.h"

#include <cmath>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#if __has_include(<dlib/image_processing.h>) && __has_include(<dlib/dnn.h>)
#define PROWSER_HAS_DLIB 1
#include <dlib/dnn.h>
#include <dlib/image_processing/frontal_face_detector.h>
#include <dlib/image_transforms.h>
#endif

namespace {

std::mutex g_mutex;
bool g_bridge_linked = false;

#if PROWSER_HAS_DLIB
// Must match dnn_face_recognition_ex.cpp / face_recognition `anet_type` for
// `dlib_face_recognition_resnet_model_v1.dat`.
template <template <int, template <typename> class, int, typename> class block, int N, template <typename> class BN, typename SUBNET>
using residual = dlib::add_prev1<block<N, BN, 1, dlib::tag1<SUBNET>>>;

template <template <int, template <typename> class, int, typename> class block, int N, template <typename> class BN, typename SUBNET>
using residual_down = dlib::add_prev2<dlib::avg_pool<2, 2, 2, 2, dlib::skip1<dlib::tag2<block<N, BN, 2, dlib::tag1<SUBNET>>>>>>;

template <int N, template <typename> class BN, int stride, typename SUBNET>
using block = BN<dlib::con<N, 3, 3, 1, 1, dlib::relu<BN<dlib::con<N, 3, 3, stride, stride, SUBNET>>>>>;

template <int N, typename SUBNET> using ares = dlib::relu<residual<block, N, dlib::affine, SUBNET>>;
template <int N, typename SUBNET> using ares_down = dlib::relu<residual_down<block, N, dlib::affine, SUBNET>>;

template <typename SUBNET> using alevel0 = ares_down<256, SUBNET>;
template <typename SUBNET> using alevel1 = ares<256, ares<256, ares_down<256, SUBNET>>>;
template <typename SUBNET> using alevel2 = ares<128, ares<128, ares_down<128, SUBNET>>>;
template <typename SUBNET> using alevel3 = ares<64, ares<64, ares<64, ares_down<64, SUBNET>>>>;
template <typename SUBNET> using alevel4 = ares<32, ares<32, ares<32, SUBNET>>>;

using face_recognition_net_type = dlib::loss_metric<dlib::fc_no_bias<128, dlib::avg_pool_everything<
    alevel0<
        alevel1<
            alevel2<
                alevel3<
                    alevel4<
                        dlib::max_pool<3, 3, 2, 2, dlib::relu<dlib::affine<dlib::con<32, 7, 7, 2, 2,
                            dlib::input_rgb_image_sized<150>
                            >>>>>>>>>>>>;

dlib::frontal_face_detector g_detector;
dlib::shape_predictor g_shape_predictor;
face_recognition_net_type g_face_net;
bool g_models_loaded = false;
int g_last_hog_face_count = 0;

dlib::matrix<dlib::rgb_pixel> rgb_matrix_from_buffer(
    const uint8_t *rgb,
    int width,
    int height,
    int bytes_per_row)
{
    dlib::matrix<dlib::rgb_pixel> img(height, width);
    for (int y = 0; y < height; ++y) {
        const uint8_t *row = rgb + y * bytes_per_row;
        for (int x = 0; x < width; ++x) {
            const uint8_t *p = row + x * 3;
            img(y, x) = dlib::rgb_pixel(p[0], p[1], p[2]);
        }
    }
    return img;
}

dlib::matrix<float, 0, 1> face_descriptor(const dlib::matrix<dlib::rgb_pixel> &img, const dlib::rectangle &face)
{
    dlib::full_object_detection shape = g_shape_predictor(img, face);
    dlib::matrix<dlib::rgb_pixel> face_chip;
    dlib::extract_image_chip(img, dlib::get_face_chip_details(shape, 150, 0.25), face_chip);
    return g_face_net(face_chip);
}
static int encode_faces_on_image(
    const dlib::matrix<dlib::rgb_pixel> &img,
    float *encodings_out,
    ProwserFaceRect *rects_out,
    int32_t max_faces)
{
    // Static macOS dlib + hand-built rgb_pixel matrices: upsample 1 loses faces vs pip face_recognition.
    // upsample 0 matches Python recall on the same pixels (see Tools/FaceDetectBench).
    std::vector<dlib::rectangle> faces = g_detector(img, 0);
    g_last_hog_face_count = static_cast<int>(faces.size());
    int written = 0;
    for (const auto &face : faces) {
        if (written >= max_faces) {
            break;
        }
        try {
            auto desc = face_descriptor(img, face);
            for (long i = 0; i < desc.nr(); ++i) {
                encodings_out[written * PROWSER_DLIB_ENCODING_DIM + static_cast<size_t>(i)] = desc(i);
            }
            rects_out[written].top = static_cast<int>(face.top());
            rects_out[written].right = static_cast<int>(face.right());
            rects_out[written].bottom = static_cast<int>(face.bottom());
            rects_out[written].left = static_cast<int>(face.left());
            ++written;
        } catch (...) {
            continue;
        }
    }
    return written;
}
#endif

} // namespace

bool prowser_dlib_bridge_linked(void)
{
#if PROWSER_HAS_DLIB
    return true;
#else
    return g_bridge_linked;
#endif
}

bool prowser_dlib_load_models(const char *shape_predictor_path, const char *face_recognition_resnet_path)
{
#if !PROWSER_HAS_DLIB
    (void)shape_predictor_path;
    (void)face_recognition_resnet_path;
    return false;
#else
    if (!shape_predictor_path || !face_recognition_resnet_path) {
        return false;
    }
    std::lock_guard<std::mutex> lock(g_mutex);
    try {
        dlib::deserialize(shape_predictor_path) >> g_shape_predictor;
        dlib::deserialize(face_recognition_resnet_path) >> g_face_net;
        g_detector = dlib::get_frontal_face_detector();
        g_models_loaded = true;
        return true;
    } catch (...) {
        g_models_loaded = false;
        return false;
    }
#endif
}

void prowser_dlib_unload_models(void)
{
#if PROWSER_HAS_DLIB
    std::lock_guard<std::mutex> lock(g_mutex);
    g_models_loaded = false;
#endif
}

bool prowser_dlib_models_are_loaded(void)
{
#if !PROWSER_HAS_DLIB
    return false;
#else
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_models_loaded;
#endif
}

int prowser_dlib_last_hog_face_count(void)
{
#if !PROWSER_HAS_DLIB
    return 0;
#else
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_last_hog_face_count;
#endif
}

int prowser_dlib_encode_faces_rgb(
    const uint8_t *rgb,
    int32_t width,
    int32_t height,
    int32_t bytes_per_row,
    float *encodings_out,
    ProwserFaceRect *rects_out,
    int32_t max_faces)
{
#if !PROWSER_HAS_DLIB
    (void)rgb;
    (void)width;
    (void)height;
    (void)bytes_per_row;
    (void)encodings_out;
    (void)rects_out;
    (void)max_faces;
    return -1;
#else
    if (!rgb || !encodings_out || !rects_out || width <= 0 || height <= 0 || max_faces <= 0) {
        return -1;
    }
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_models_loaded) {
        return -1;
    }
    try {
        auto img = rgb_matrix_from_buffer(rgb, width, height, bytes_per_row);
        return encode_faces_on_image(img, encodings_out, rects_out, max_faces);
    } catch (...) {
        return -1;
    }
#endif
}

double prowser_dlib_min_face_distance(
    const float *known_encodings,
    int32_t known_count,
    const float *unknown_encoding)
{
    if (!known_encodings || !unknown_encoding || known_count <= 0) {
        return -1.0;
    }
    double best = -1.0;
    for (int k = 0; k < known_count; ++k) {
        const float *known = known_encodings + k * PROWSER_DLIB_ENCODING_DIM;
        double sum = 0.0;
        for (int i = 0; i < PROWSER_DLIB_ENCODING_DIM; ++i) {
            const double d = static_cast<double>(known[i]) - static_cast<double>(unknown_encoding[i]);
            sum += d * d;
        }
        const double dist = std::sqrt(sum);
        if (best < 0.0 || dist < best) {
            best = dist;
        }
    }
    return best;
}
