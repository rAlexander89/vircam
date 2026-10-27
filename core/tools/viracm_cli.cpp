// Runs the privacy pipeline on a still image, for testing without a camera.
//
//   viracm_cli <model_dir> <input image> <output.png> [--debug] [--frames N]
//
// A still image is fed as N consecutive frames at 30 fps (default 15), since a face
// must be seen in several frames before it can be kept sharp.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "stb_image.h"
#include "stb_image_write.h"
#include "viracm/viracm.h"

namespace {

void swap_red_blue(std::vector<uint8_t> &pixels) {
    for (size_t i = 0; i < pixels.size(); i += 4) std::swap(pixels[i], pixels[i + 2]);
}

int usage() {
    std::fprintf(stderr, "usage: viracm_cli <model_dir> <input image> <output.png> [--debug] [--frames N]\n");
    return 2;
}

}  // namespace

int main(int argc, char **argv) {
    if (argc < 4) return usage();
    const char *model_dir = argv[1];
    const char *input_path = argv[2];
    const char *output_path = argv[3];
    bool debug = false;
    int frames = 15;
    for (int i = 4; i < argc; ++i) {
        if (std::strcmp(argv[i], "--debug") == 0) {
            debug = true;
        } else if (std::strcmp(argv[i], "--frames") == 0 && i + 1 < argc) {
            frames = std::max(1, std::atoi(argv[++i]));
        } else {
            return usage();
        }
    }

    int width = 0, height = 0, channels = 0;
    uint8_t *loaded = stbi_load(input_path, &width, &height, &channels, 4);
    if (!loaded) {
        std::fprintf(stderr, "error: cannot read %s: %s\n", input_path, stbi_failure_reason());
        return 1;
    }
    std::vector<uint8_t> input(loaded, loaded + static_cast<size_t>(width) * height * 4);
    stbi_image_free(loaded);
    swap_red_blue(input);  // RGBA -> BGRA
    std::vector<uint8_t> output(input.size());

    char error[512] = {0};
    viracm_engine *engine = viracm_engine_create(model_dir, error, sizeof(error));
    if (!engine) {
        std::fprintf(stderr, "error: cannot create engine: %s\n", error);
        return 1;
    }
    viracm_engine_set_debug_overlay(engine, debug);

    viracm_image in{input.data(), width, height, width * 4};
    viracm_image out{output.data(), width, height, width * 4};
    viracm_frame_info info{};
    double total_ms = 0;
    for (int frame = 0; frame < frames; ++frame) {
        if (viracm_engine_process(engine, &in, &out, frame / 30.0, &info) != VIRACM_OK) {
            std::fprintf(stderr, "error: processing failed\n");
            return 1;
        }
        total_ms += info.process_ms;
    }
    viracm_engine_destroy(engine);

    std::printf("%dx%d  mode=%s  faces_detected=%d  faces_blurred=%d  avg=%.1f ms/frame\n", width, height,
                info.mode == VIRACM_FRAME_PROTECTED ? "protected" : "full_blur", info.faces_detected,
                info.faces_blurred, total_ms / frames);

    swap_red_blue(output);
    if (!stbi_write_png(output_path, width, height, 4, output.data(), width * 4)) {
        std::fprintf(stderr, "error: cannot write %s\n", output_path);
        return 1;
    }
    return 0;
}
