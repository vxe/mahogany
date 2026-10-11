#ifndef HRT_HRT_OUTPUT_H
#define HRT_HRT_OUTPUT_H

#include "hrt/hrt_scene.h"
#include <wayland-server.h>

#include <wlr/types/wlr_output.h>
#include <wlr/util/box.h>

#include <hrt/hrt_server.h>

struct hrt_scene_output;

struct hrt_output_config {
    double scale;
    // Use the exact settings instead of the closest supported match:
    bool custom_mode;
    int width, height;
    float refresh_rate;
    // Place the output in a specific spot in the layout based on the
    // given X,Y coordinates:
    bool custom_position;
    // These are in layout coordinates, not pixel coordinates:
    int x, y;
    bool enabled;
};

struct hrt_output {
    struct wlr_output *wlr_output;
    struct hrt_server *server;
    struct hrt_scene_output *scene;
    struct wlr_scene_output *wlr_scene;

    struct wlr_box usable_area;

    struct wl_list layer_surfaces;

    struct wl_listener request_state;
    struct wl_listener frame;
    struct wl_listener destroy;
};

struct hrt_output_callbacks {
    void (*output_added)(struct hrt_output *output);
    void (*output_removed)(struct hrt_output *output);
    void (*output_layout_changed)();
};

/**
 * Attach an exact display timing (a modeline) to CONFIG. It is kept in a
 * side table keyed by CONFIG's address, so struct hrt_output_config keeps
 * its layout (and the generated Lisp bindings stay valid). When the config
 * is applied to a DRM output, the timing is added to the connector as a
 * user-defined mode and used instead of width/height/refresh_rate/
 * custom_mode; other backends get a custom mode of hdisplay x vdisplay at
 * the refresh rate the timing gives.
 *
 * CLOCK_KHZ is the pixel clock in kHz, FLAGS are DRM_MODE_FLAG_* bits.
 * The entry stays until hrt_output_config_clear_modeline is called for
 * the same address: whoever fills a config must set or clear it, and
 * clear it before the config memory is freed.
 **/
void hrt_output_config_set_modeline(struct hrt_output_config *config,
                                    int clock_khz, int hdisplay,
                                    int hsync_start, int hsync_end,
                                    int htotal, int vdisplay,
                                    int vsync_start, int vsync_end,
                                    int vtotal, uint32_t flags);

/**
 * Remove the modeline attached to CONFIG, if any.
 **/
void hrt_output_config_clear_modeline(struct hrt_output_config *config);

bool hrt_output_configure(struct hrt_output *output,
                          struct hrt_output_config *config);

bool hrt_output_configure_atomic(struct hrt_output *outputs[],
                                 struct hrt_output_config configs[],
                                 const size_t length);

/**
 * Get the effective output resolution of the output that can be used to
 * set the width and height of views.
 **/
void hrt_output_resolution(struct hrt_output *output, int *width, int *height);

void hrt_output_position(struct hrt_output *output, int *x, int *y);

bool hrt_output_enabled(struct hrt_output *output);

char *hrt_output_name(struct hrt_output *output);

char *hrt_output_make(struct hrt_output *output);

char *hrt_output_model(struct hrt_output *output);

char *hrt_output_serial(struct hrt_output *output);

#endif
