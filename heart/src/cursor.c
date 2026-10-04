#include "wlr/util/log.h"
#include <stdint.h>
#include <wayland-util.h>
#include <wlr/types/wlr_xcursor_manager.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_seat.h>

#include <hrt/hrt_server.h>
#include <hrt/hrt_input.h>
#include <hrt/hrt_window_slots.h>

// This function is shamelessly ripped from the tinywl implementation:
static void *find_view_at(struct hrt_server *server, double lx, double ly,
                          struct wlr_surface **surface, double *sx,
                          double *sy) {
    /* This returns the topmost node in the scene at the given layout coords.
     * We only care about surface nodes as we are specifically looking for a
     * surface in the surface tree of a tinywl_toplevel. */
    struct wlr_scene_node *node =
        wlr_scene_node_at(&server->scene->tree.node, lx, ly, sx, sy);
    if (node == NULL || node->type != WLR_SCENE_NODE_BUFFER) {
        return NULL;
    }
    struct wlr_scene_buffer *scene_buffer = wlr_scene_buffer_from_node(node);
    struct wlr_scene_surface *scene_surface =
        wlr_scene_surface_try_from_buffer(scene_buffer);
    if (!scene_surface) {
        return NULL;
    }

    *surface = scene_surface->surface;
    /* Find the node corresponding to the toplevel at the root of this
     * surface tree, it is the only one for which we set the data field. */
    struct wlr_scene_tree *tree = node->parent;
    while (tree != NULL && tree->node.data == NULL) {
        tree = tree->node.parent;
    }
    if (tree) {
        return tree->node.data;
    } else {
        return NULL;
    }
}

void hrt_seat_reset_view_under(struct hrt_seat *seat) {
    if (!seat->grabbed) {
        double sx, sy;
        struct wlr_surface *found_surface = NULL;
        void *view = find_view_at(seat->server, seat->cursor->x,
                                  seat->cursor->y, &found_surface, &sx, &sy);

        if (!view) {
            wlr_cursor_set_xcursor(seat->cursor, seat->xcursor_manager,
                                   seat->cursor_image);
        }
        if (found_surface) {
            wlr_seat_pointer_notify_enter(seat->seat, found_surface, sx, sy);
        } else {
            wlr_seat_pointer_clear_focus(seat->seat);
        }
    }
}

static void handle_cursor_motion(struct hrt_seat *seat, uint32_t time) {
    if (!seat->grabbed) {
        double sx, sy;
        struct wlr_surface *found_surface = NULL;
        void *view = find_view_at(seat->server, seat->cursor->x,
                                  seat->cursor->y, &found_surface, &sx, &sy);
        if (!view) {
            wlr_cursor_set_xcursor(seat->cursor, seat->xcursor_manager,
                                   seat->cursor_image);
        }
        if (found_surface) {
            wlr_seat_pointer_notify_enter(seat->seat, found_surface, sx, sy);
            wlr_seat_pointer_notify_motion(seat->seat, time, sx, sy);
        } else {
            wlr_seat_pointer_clear_focus(seat->seat);
        }
    }
}

// Window slots are virtual outputs parked in the layout right next to the
// desktop (see mirror.c). The pointer must never enter one.
static bool cursor_on_virtual_output(struct hrt_seat *seat) {
    return hrt_output_is_virtual(wlr_output_layout_output_at(
        seat->server->output_layout, seat->cursor->x, seat->cursor->y));
}

/**
 * The bounding box of the desktop (non-virtual) outputs. Returns false when
 * the layout has no virtual outputs, or no desktop output, so callers can
 * keep wlroots' default behaviour.
 */
static bool desktop_box(struct hrt_server *server, struct wlr_box *box) {
    bool has_virtual = false;
    int x1 = 0, y1 = 0, x2 = 0, y2 = 0;
    bool any = false;
    struct wlr_output_layout_output *l_output;
    wl_list_for_each(l_output, &server->output_layout->outputs, link) {
        if (hrt_output_is_virtual(l_output->output)) {
            has_virtual = true;
            continue;
        }
        struct wlr_box b;
        wlr_output_layout_get_box(server->output_layout, l_output->output, &b);
        if (wlr_box_empty(&b)) {
            continue;
        }
        if (!any) {
            x1 = b.x, y1 = b.y;
            x2 = b.x + b.width, y2 = b.y + b.height;
            any = true;
            continue;
        }
        x1 = b.x < x1 ? b.x : x1;
        y1 = b.y < y1 ? b.y : y1;
        x2 = b.x + b.width > x2 ? b.x + b.width : x2;
        y2 = b.y + b.height > y2 ? b.y + b.height : y2;
    }
    *box =
        (struct wlr_box){.x = x1, .y = y1, .width = x2 - x1, .height = y2 - y1};
    return has_virtual && any;
}

static void seat_motion(struct wl_listener *listener, void *data) {
    struct hrt_seat *seat = wl_container_of(listener, seat, motion);
    struct wlr_pointer_motion_event *ev = data;

    const double old_x = seat->cursor->x, old_y = seat->cursor->y;
    wlr_cursor_move(seat->cursor, &ev->pointer->base, ev->delta_x, ev->delta_y);
    if (cursor_on_virtual_output(seat)) {
        // Keep the vertical part of the motion if that stays on the desktop.
        if (!wlr_cursor_warp(seat->cursor, NULL, old_x, seat->cursor->y) ||
            cursor_on_virtual_output(seat)) {
            wlr_cursor_warp(seat->cursor, NULL, old_x, old_y);
        }
    }
    handle_cursor_motion(seat, ev->time_msec);
}

static void seat_motion_absolute(struct wl_listener *listener, void *data) {
    struct hrt_seat *seat = wl_container_of(listener, seat, motion_absolute);
    struct wlr_pointer_motion_absolute_event *ev = data;

    struct wlr_box box;
    if (desktop_box(seat->server, &box)) {
        // Map absolute devices onto the desktop only, not the parked slots.
        wlr_cursor_warp_closest(seat->cursor, &ev->pointer->base,
                                box.x + ev->x * box.width,
                                box.y + ev->y * box.height);
    } else {
        wlr_cursor_warp_absolute(seat->cursor, &ev->pointer->base, ev->x,
                                 ev->y);
    }
    handle_cursor_motion(seat, ev->time_msec);
}

static void seat_button(struct wl_listener *listener, void *data) {
    struct hrt_seat *seat = wl_container_of(listener, seat, button);
    if (!seat->grabbed) {
        struct wlr_pointer_button_event *event = data;

        /* Notify the client with pointer focus that a button press has occurred */
        seat->callbacks->button_event(seat, event);
    }
}

static void seat_axis(struct wl_listener *listener, void *data) {
    struct hrt_seat *seat = wl_container_of(listener, seat, axis);
    if (!seat->grabbed) {
        struct wlr_pointer_axis_event *ev = data;
        seat->callbacks->wheel_event(seat, ev);
    }
}

static void seat_frame(struct wl_listener *listener, void *data) {
    struct hrt_seat *seat = wl_container_of(listener, seat, frame);
    wlr_seat_pointer_notify_frame(seat->seat);
}

constexpr uint32_t xcursor_base_size = 24;

bool hrt_seat_cursor_set_theme(struct hrt_seat *seat, char *theme_name,
                               uint32_t base_size) {
    if (base_size < 1) {
        wlr_log(WLR_ERROR, "Cannot set cursor base size to zero.");
    }
    struct wlr_xcursor_manager *manager =
        wlr_xcursor_manager_create(theme_name, base_size);
    if (!manager) {
        return false;
    }

    struct wlr_output_layout_output *output;
    wl_list_for_each(output, &seat->server->output_layout->outputs, link) {
        struct wlr_output *wlr_output = output->output;
        const float scale             = wlr_output->scale;
        if (!wlr_xcursor_manager_load(manager, scale)) {
            wlr_log(WLR_ERROR, "Failed to load cursor theme for scale %f",
                    scale);
            goto error;
        }
    }
    wlr_xcursor_manager_destroy(seat->xcursor_manager);
    seat->xcursor_manager = manager;
    hrt_seat_reset_view_under(seat);

    return true;
error:
    wlr_xcursor_manager_destroy(manager);
    return false;
}

bool hrt_cursor_init(struct hrt_seat *seat, struct hrt_server *server) {
    seat->cursor = wlr_cursor_create();
    if (!seat->cursor) {
        return false;
    }
    wlr_cursor_attach_output_layout(seat->cursor, server->output_layout);

    seat->xcursor_manager = wlr_xcursor_manager_create(NULL, xcursor_base_size);
    if (!seat->xcursor_manager) {
        wlr_log(WLR_ERROR, "Could not create the xcursor manager");
        return false;
    }

    seat->motion.notify = seat_motion;
    wl_signal_add(&seat->cursor->events.motion, &seat->motion);
    seat->motion_absolute.notify = seat_motion_absolute;
    wl_signal_add(&seat->cursor->events.motion_absolute,
                  &seat->motion_absolute);
    seat->button.notify = seat_button;
    wl_signal_add(&seat->cursor->events.button, &seat->button);
    seat->axis.notify = seat_axis;
    wl_signal_add(&seat->cursor->events.axis, &seat->axis);
    seat->frame.notify = seat_frame;
    wl_signal_add(&seat->cursor->events.frame, &seat->frame);

    return true;
}

void hrt_cursor_destroy(struct hrt_seat *seat) {
    wlr_log(WLR_DEBUG, "hrt_cursor destroyed");
    wl_list_remove(&seat->frame.link);
    wl_list_remove(&seat->axis.link);
    wl_list_remove(&seat->button.link);
    wl_list_remove(&seat->motion_absolute.link);
    wl_list_remove(&seat->motion.link);

    wlr_xcursor_manager_destroy(seat->xcursor_manager);
    wlr_cursor_destroy(seat->cursor);
}
