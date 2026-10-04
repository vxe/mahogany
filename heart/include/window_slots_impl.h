#pragma once

#include <stdbool.h>

#include "hrt/hrt_window_slots.h"

struct hrt_server;
struct hrt_view;
struct hrt_layer_shell_surface;

/** xdg_shell.c: a toplevel mapped; apply the app_id rules. */
void hrt_window_slots_view_mapped(struct hrt_view *view);

/**
 * layer_shell.c: if SURFACE asked for a slot output, place it in that slot's
 * hidden layers and return true (Mahogany never sees it as a desktop layer).
 */
bool hrt_window_slots_claim_layer_surface(struct hrt_server *server,
                                          struct hrt_layer_shell_surface *s);

/** output.c: the output layout changed; re-pick the clock output. */
void hrt_window_slots_layout_changed(struct hrt_server *server);

/** server.c: tear everything down (before the allocator/renderer go). */
void hrt_window_slots_destroy(struct hrt_server *server);
