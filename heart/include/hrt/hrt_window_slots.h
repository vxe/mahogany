#ifndef HRT_HRT_WINDOW_SLOTS_H
#define HRT_HRT_WINDOW_SLOTS_H

/**
 * Window slots: permanent virtual outputs (REC-1 .. REC-n) that each show
 * exactly one window, whatever that window's visibility on the desktop.
 *
 * Any output-capture client (grim -o REC-1, the screencast portal, OBS)
 * reads a slot like a monitor. An empty slot shows black.
 *
 * Indices are 0-based; slot i is named "REC-<i+1>".
 *
 * NOTE: this header is deliberately not listed in cffi/hrt-bindings.yml yet
 * (cl-bindgen was not available when it was written). The Lisp side declares
 * these functions by hand in lisp/heart/window-slots.lisp.
 */

#include <stdbool.h>

struct hrt_server;
struct hrt_view;
struct wlr_output;

/**
 * Create COUNT slots of WIDTH x HEIGHT at REFRESH_MHZ (the slots' own clock,
 * used only while there is no real output to follow). Call once, before
 * hrt_server_start. Returns false if slots already exist or on failure.
 */
bool hrt_window_slots_create(struct hrt_server *server, int count, int width,
                             int height, int refresh_mhz);

int hrt_window_slot_count(struct hrt_server *server);

/** "REC-<index+1>", or NULL for an invalid index. */
const char *hrt_window_slot_name(struct hrt_server *server, int index);

/**
 * Show VIEW (must be mapped) in slot INDEX, replacing what the slot showed.
 * A view can be in one slot only; it is moved if it already has one.
 * The slot empties itself when the view unmaps.
 */
bool hrt_window_slot_assign(struct hrt_server *server, int index,
                            struct hrt_view *view);

void hrt_window_slot_unassign(struct hrt_server *server, int index);

/** Index of the slot showing VIEW, or -1. */
int hrt_window_slot_find_view(struct hrt_server *server, struct hrt_view *view);

/** The view in slot INDEX, or NULL. */
struct hrt_view *hrt_window_slot_view(struct hrt_server *server, int index);

/**
 * Rule-based assignment: a toplevel whose app_id equals APP_ID is put in
 * slot INDEX when it maps, if the slot is empty. NULL clears the rule.
 */
bool hrt_window_slot_set_rule(struct hrt_server *server, int index,
                              const char *app_id);

/** Number of frames slot INDEX has been ticked (for tests/diagnostics). */
long hrt_window_slot_ticks(struct hrt_server *server, int index);

/**
 * The one predicate for "this output is a window slot, not a desktop
 * output". Every place that must treat slots differently uses this.
 */
bool hrt_output_is_virtual(struct wlr_output *output);

#endif
