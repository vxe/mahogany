// Window slots: permanent virtual outputs that each mirror one window.
//
// Design (SPRINT-1 §2, ~/Dropbox/OBS/thinkpad):
// - REC-1..REC-n are headless outputs on a PRIVATE headless backend that is
//   not part of the server's multi backend. Their new_output events therefore
//   never reach Mahogany: a slot is never a desktop (Lisp) output, and it can
//   be created before or after the server starts without racing new_output.
// - Each slot has its own wlr_scene: a black backdrop plus the assigned
//   window's xdg surface tree (popups included). The window keeps its place in
//   the main scene; the slot only mirrors it, so it stays live while hidden.
// - Slots must be in the output layout (wlr_xdg_output_v1 asserts that every
//   wl_output it is asked about has a layout position). They are parked to the
//   LEFT of x=0, with REC-1's right edge exactly on 0, at y=0. wlroots places
//   auto-configured outputs right of the rightmost manually placed output, at
//   that output's y, so a real output without a configured position lands at
//   (0,0), where it would be without slots. (Parking at x=+100000, as the
//   spike did, moved the panel to x=101920 and pushed xdg popups off screen.)
//   Consequence: REC-1 touches the real output's left edge, so cursor.c
//   refuses pointer motion into virtual outputs.
// - Layer surfaces (bars, wallpapers) aimed at a slot are accepted into
//   per-slot layer trees that are never enabled: clients that put one surface
//   on every wl_output keep working, and nothing shows up in the slot.
// - Clock: while at least one slot is assigned and a real output exists,
//   slots are ticked from that output's frame event (eDP preferred) and the
//   real output is kept flipping by scheduling a frame every vblank (the
//   keep-alive). Otherwise every slot runs on its own headless timer, which
//   only fires when something (damage, a capture request) needs a frame.
// - The one predicate for "is a slot" is hrt_output_is_virtual(): a
//   wlr_addon on the slot's wlr_output.
//
// State is file-static (one server per process); the Lisp-visible structs
// (hrt_server, hrt_output) are unchanged so the cffi bindings stay valid.

#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <wayland-server-core.h>
#include <wlr/backend.h>
#include <wlr/backend/headless.h>
#include <wlr/types/wlr_layer_shell_v1.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/util/addon.h>
#include <wlr/util/log.h>

#include "hrt/hrt_layer_shell.h"
#include "hrt/hrt_output.h"
#include "hrt/hrt_scene.h"
#include "hrt/hrt_server.h"
#include "hrt/hrt_view.h"
#include "layer_shell_impl.h"
#include "window_slots_impl.h"

struct window_slot;

// One xdg surface (the toplevel, or a popup) mirrored into a slot. Owned by
// its scene tree: freed when the tree is destroyed, whoever destroys it
// (unassign, the xdg surface going away, or a parent tree being destroyed).
struct slot_xdg_tree {
    struct window_slot *slot;
    struct wlr_scene_tree *tree;
    struct wl_listener new_popup;
    struct wl_listener tree_destroy;
};

struct window_slot {
    int index;
    char name[16];
    char *rule_app_id;

    struct wlr_output *wlr_output;
    // A C-private hrt_output so layer surfaces can be placed on the slot.
    // Its layer trees live in the main scene but are never enabled.
    struct hrt_output output;
    struct wlr_addon addon;

    struct wlr_scene *scene;
    struct wlr_scene_output *scene_output;
    struct wlr_scene_tree *content;

    struct hrt_view *view;
    struct slot_xdg_tree *root;
    long ticks;

    struct wl_listener frame;
    struct wl_listener output_destroy;
    struct wl_listener view_unmap;
};

static struct {
    struct hrt_server *server;
    struct wlr_backend *backend;
    struct window_slot *slots;
    int count;

    struct wlr_output *clock;
    struct wl_listener clock_frame;
    struct wl_listener clock_destroy;
    bool engaged;
    // Set while hrt_window_slots_destroy runs: removing slot outputs from the
    // layout emits layout changes, which must not re-attach the clock.
    bool destroying;
} ws;

// --- the predicate -----------------------------------------------------------

static void slot_addon_destroy(struct wlr_addon *addon) {
    // The output is going away; handle_slot_output_destroy did the work.
    wlr_addon_finish(addon);
}

static const struct wlr_addon_interface slot_addon_impl = {
    .name    = "hrt_window_slot",
    .destroy = slot_addon_destroy,
};

bool hrt_output_is_virtual(struct wlr_output *output) {
    return output &&
        wlr_addon_find(&output->addons, &slot_addon_impl, &slot_addon_impl);
}

static struct window_slot *slot_at(struct hrt_server *server, int index) {
    if (server != ws.server || index < 0 || index >= ws.count) {
        return NULL;
    }
    return &ws.slots[index];
}

// --- clock -------------------------------------------------------------------

static bool any_assigned(void) {
    for (int i = 0; i < ws.count; i++) {
        if (ws.slots[i].view) {
            return true;
        }
    }
    return false;
}

static void slot_tick(struct window_slot *slot) {
    if (!slot->scene_output) {
        return;
    }
    slot->ticks++;
    wlr_scene_output_commit(slot->scene_output, NULL);
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    wlr_scene_output_send_frame_done(slot->scene_output, &now);
}

static void slots_resume_own_timers(void) {
    for (int i = 0; i < ws.count; i++) {
        if (ws.slots[i].wlr_output) {
            wlr_output_schedule_frame(ws.slots[i].wlr_output);
        }
    }
}

static void clock_update(void) {
    bool engaged = ws.clock && any_assigned();
    if (engaged == ws.engaged) {
        return;
    }
    ws.engaged = engaged;
    wlr_log(WLR_INFO, "window slots: %s",
            engaged ? "following the clock output" : "on their own timers");
    if (engaged) {
        // Start the keep-alive; from now on handle_clock_frame re-arms it.
        wlr_output_schedule_frame(ws.clock);
    } else {
        slots_resume_own_timers();
    }
}

// Registered at the HEAD of the clock output's frame signal, so it runs before
// the output's own handler commits the desktop scene: the frame we schedule
// here is what makes that commit happen (one desktop commit, and one slot
// tick, per vblank).
static void handle_clock_frame(struct wl_listener *listener, void *data) {
    if (!ws.engaged) {
        return;
    }
    for (int i = 0; i < ws.count; i++) {
        slot_tick(&ws.slots[i]);
    }
    wlr_output_schedule_frame(ws.clock); // keep-alive
}

static void clock_detach(void) {
    if (!ws.clock) {
        return;
    }
    wl_list_remove(&ws.clock_frame.link);
    wl_list_remove(&ws.clock_destroy.link);
    ws.clock = NULL;
}

static void clock_set(struct wlr_output *output);

static struct wlr_output *clock_pick(struct wlr_output *exclude) {
    struct wlr_output *best = NULL;
    struct wlr_output_layout_output *l_output;
    wl_list_for_each(l_output, &ws.server->output_layout->outputs, link) {
        struct wlr_output *output = l_output->output;
        if (output == exclude || hrt_output_is_virtual(output) ||
            !output->enabled) {
            continue;
        }
        if (strncmp(output->name, "eDP", 3) == 0) {
            return output;
        }
        if (!best) {
            best = output;
        }
    }
    return best;
}

static void handle_clock_destroy(struct wl_listener *listener, void *data) {
    struct wlr_output *dying = ws.clock;
    clock_detach();
    if (ws.server && !ws.destroying) {
        clock_set(clock_pick(dying));
    }
}

static void clock_set(struct wlr_output *output) {
    if (output != ws.clock) {
        clock_detach();
        if (output) {
            ws.clock              = output;
            ws.clock_frame.notify = handle_clock_frame;
            wl_list_insert(&output->events.frame.listener_list,
                           &ws.clock_frame.link);
            ws.clock_destroy.notify = handle_clock_destroy;
            wl_signal_add(&output->events.destroy, &ws.clock_destroy);
        }
        wlr_log(WLR_INFO, "window slots: clock output is %s",
                output ? output->name : "(none, own timers)");
        // Re-evaluate from scratch: the old keep-alive stopped with the
        // detach, so slots run on their own timers until clock_update
        // engages the new output.
        if (ws.engaged) {
            ws.engaged = false;
            slots_resume_own_timers();
        }
    }
    clock_update();
}

void hrt_window_slots_layout_changed(struct hrt_server *server) {
    if (server != ws.server || ws.count == 0 || ws.destroying) {
        return;
    }
    clock_set(clock_pick(NULL));
}

static void handle_slot_frame(struct wl_listener *listener, void *data) {
    struct window_slot *slot = wl_container_of(listener, slot, frame);
    if (ws.engaged) {
        return; // the clock output drives every slot
    }
    slot_tick(slot);
}

// --- mirrored xdg trees (toplevel + popups) ----------------------------------

static struct slot_xdg_tree *slot_xdg_tree_create(struct window_slot *slot,
                                                  struct wlr_scene_tree *parent,
                                                  struct wlr_xdg_surface *xdg);

static void handle_tree_new_popup(struct wl_listener *listener, void *data) {
    struct slot_xdg_tree *t     = wl_container_of(listener, t, new_popup);
    struct wlr_xdg_popup *popup = data;
    slot_xdg_tree_create(t->slot, t->tree, popup->base);
}

static void slot_clear(struct window_slot *slot);

static void handle_tree_destroy(struct wl_listener *listener, void *data) {
    struct slot_xdg_tree *t = wl_container_of(listener, t, tree_destroy);
    wl_list_remove(&t->new_popup.link);
    wl_list_remove(&t->tree_destroy.link);
    if (t->slot->root == t) {
        t->slot->root = NULL;
        // The window's tree went away without an unmap (it should not
        // happen, but never leave a dangling view behind):
        slot_clear(t->slot);
    }
    free(t);
}

static struct slot_xdg_tree *slot_xdg_tree_create(struct window_slot *slot,
                                                  struct wlr_scene_tree *parent,
                                                  struct wlr_xdg_surface *xdg) {
    struct slot_xdg_tree *t = calloc(1, sizeof(*t));
    if (!t) {
        return NULL;
    }
    // wlr_scene_xdg_surface_create offsets the surface by minus its window
    // geometry (no CSD shadow margin in the slot) and positions popups
    // relative to their parent's tree.
    t->tree = wlr_scene_xdg_surface_create(parent, xdg);
    if (!t->tree) {
        free(t);
        return NULL;
    }
    t->slot             = slot;
    t->new_popup.notify = handle_tree_new_popup;
    wl_signal_add(&xdg->events.new_popup, &t->new_popup);
    t->tree_destroy.notify = handle_tree_destroy;
    wl_signal_add(&t->tree->node.events.destroy, &t->tree_destroy);

    // Popups that already exist (assigned while a menu is open).
    struct wlr_xdg_popup *popup;
    wl_list_for_each(popup, &xdg->popups, link) {
        slot_xdg_tree_create(slot, t->tree, popup->base);
    }
    return t;
}

// --- assignment --------------------------------------------------------------

// Forget the view; the caller has already dealt with the tree.
static void slot_clear(struct window_slot *slot) {
    if (!slot->view) {
        return;
    }
    wl_list_remove(&slot->view_unmap.link);
    slot->view = NULL;
    wlr_log(WLR_INFO, "window slot %s now empty", slot->name);
    clock_update();
}

static void slot_unassign(struct window_slot *slot) {
    if (slot->root) {
        struct slot_xdg_tree *root = slot->root;
        slot->root                 = NULL;
        wlr_scene_node_destroy(&root->tree->node); // frees every tracker
    }
    slot_clear(slot);
}

static void handle_view_unmap(struct wl_listener *listener, void *data) {
    struct window_slot *slot = wl_container_of(listener, slot, view_unmap);
    slot_unassign(slot);
}

static bool slot_assign(struct window_slot *slot, struct hrt_view *view) {
    if (!slot->wlr_output || !view || !view->xdg_toplevel ||
        !view->xdg_toplevel->base->surface->mapped) {
        return false;
    }
    if (slot->view == view) {
        return true;
    }
    int other = hrt_window_slot_find_view(ws.server, view);
    if (other >= 0) {
        slot_unassign(&ws.slots[other]);
    }
    slot_unassign(slot);

    struct wlr_xdg_surface *xdg = view->xdg_toplevel->base;
    slot->root = slot_xdg_tree_create(slot, slot->content, xdg);
    if (!slot->root) {
        wlr_log(WLR_ERROR, "window slot %s: could not mirror the window",
                slot->name);
        return false;
    }
    slot->view              = view;
    slot->view_unmap.notify = handle_view_unmap;
    wl_signal_add(&xdg->surface->events.unmap, &slot->view_unmap);
    wlr_log(WLR_INFO, "window slot %s shows app_id=%s", slot->name,
            view->xdg_toplevel->app_id ? view->xdg_toplevel->app_id : "");
    clock_update();
    return true;
}

bool hrt_window_slot_assign(struct hrt_server *server, int index,
                            struct hrt_view *view) {
    struct window_slot *slot = slot_at(server, index);
    return slot && slot_assign(slot, view);
}

void hrt_window_slot_unassign(struct hrt_server *server, int index) {
    struct window_slot *slot = slot_at(server, index);
    if (slot) {
        slot_unassign(slot);
    }
}

int hrt_window_slot_find_view(struct hrt_server *server,
                              struct hrt_view *view) {
    if (server != ws.server || !view) {
        return -1;
    }
    for (int i = 0; i < ws.count; i++) {
        if (ws.slots[i].view == view) {
            return i;
        }
    }
    return -1;
}

struct hrt_view *hrt_window_slot_view(struct hrt_server *server, int index) {
    struct window_slot *slot = slot_at(server, index);
    return slot ? slot->view : NULL;
}

bool hrt_window_slot_set_rule(struct hrt_server *server, int index,
                              const char *app_id) {
    struct window_slot *slot = slot_at(server, index);
    if (!slot) {
        return false;
    }
    free(slot->rule_app_id);
    slot->rule_app_id = app_id && *app_id ? strdup(app_id) : NULL;
    return true;
}

void hrt_window_slots_view_mapped(struct hrt_view *view) {
    const char *app_id = view->xdg_toplevel->app_id;
    if (!app_id || hrt_window_slot_find_view(ws.server, view) >= 0) {
        return;
    }
    for (int i = 0; i < ws.count; i++) {
        struct window_slot *slot = &ws.slots[i];
        if (!slot->view && slot->rule_app_id &&
            strcmp(slot->rule_app_id, app_id) == 0) {
            slot_assign(slot, view);
            return;
        }
    }
}

int hrt_window_slot_count(struct hrt_server *server) {
    return server == ws.server ? ws.count : 0;
}

const char *hrt_window_slot_name(struct hrt_server *server, int index) {
    struct window_slot *slot = slot_at(server, index);
    return slot ? slot->name : NULL;
}

long hrt_window_slot_ticks(struct hrt_server *server, int index) {
    struct window_slot *slot = slot_at(server, index);
    return slot ? slot->ticks : -1;
}

// --- layer shell guard -------------------------------------------------------

bool hrt_window_slots_claim_layer_surface(struct hrt_server *server,
                                          struct hrt_layer_shell_surface *s) {
    struct wlr_output *target = s->layer_surface->output;
    if (server != ws.server || !hrt_output_is_virtual(target)) {
        return false;
    }
    struct hrt_output *output = target->data;
    hrt_layer_shell_surface_place(s, output);
    hrt_layer_shell_finish_init(s);
    wlr_log(WLR_DEBUG, "window slot %s: layer surface '%s' kept hidden",
            target->name, s->layer_surface->namespace);
    return true;
}

// --- slot outputs ------------------------------------------------------------

static void handle_slot_output_destroy(struct wl_listener *listener,
                                       void *data) {
    struct window_slot *slot = wl_container_of(listener, slot, output_destroy);
    wlr_log(WLR_DEBUG, "window slot %s destroyed", slot->name);
    slot_unassign(slot);

    // Close the layer surfaces parked on this slot, then their trees.
    hrt_layer_shell_output_destroy(&slot->output);
    hrt_scene_output_destroy(slot->output.scene);
    slot->output.scene = NULL;

    wlr_scene_output_destroy(slot->scene_output);
    slot->scene_output = NULL;
    wlr_scene_node_destroy(&slot->scene->tree.node);
    slot->scene   = NULL;
    slot->content = NULL;

    wl_list_remove(&slot->frame.link);
    wl_list_remove(&slot->output_destroy.link);
    wlr_addon_finish(&slot->addon);
    slot->wlr_output->data = NULL;
    slot->wlr_output       = NULL;
}

static bool slot_init(struct window_slot *slot, int index, int width,
                      int height, int refresh_mhz) {
    struct hrt_server *server = ws.server;
    slot->index               = index;
    snprintf(slot->name, sizeof(slot->name), "REC-%d", index + 1);

    struct wlr_output *out = wlr_headless_add_output(ws.backend, width, height);
    if (!out) {
        return false;
    }
    slot->wlr_output = out;
    wlr_output_set_name(out, slot->name);
    wlr_output_set_description(out, "Mahogany window slot");
    wlr_addon_init(&slot->addon, &out->addons, &slot_addon_impl,
                   &slot_addon_impl);
    wlr_output_init_render(out, server->allocator, server->renderer);

    struct wlr_output_state state;
    wlr_output_state_init(&state);
    wlr_output_state_set_enabled(&state, true);
    wlr_output_state_set_custom_mode(&state, width, height, refresh_mhz);
    bool ok = wlr_output_commit_state(out, &state);
    wlr_output_state_finish(&state);
    if (!ok) {
        wlr_log(WLR_ERROR, "window slot %s: could not enable", slot->name);
    }

    slot->scene    = wlr_scene_create();
    float black[4] = {0, 0, 0, 1};
    wlr_scene_rect_create(&slot->scene->tree, width, height, black);
    slot->content      = wlr_scene_tree_create(&slot->scene->tree);
    slot->scene_output = wlr_scene_output_create(slot->scene, out);

    // The slot as an hrt_output, for layer-shell placement only.
    slot->output.wlr_output = out;
    slot->output.server     = server;
    slot->output.wlr_scene  = slot->scene_output;
    slot->output.scene      = hrt_scene_output_create(server->scene_root);
    wlr_scene_node_set_enabled(&slot->output.scene->background->node, false);
    wlr_scene_node_set_enabled(&slot->output.scene->bottom->node, false);
    wlr_scene_node_set_enabled(&slot->output.scene->top->node, false);
    wlr_scene_node_set_enabled(&slot->output.scene->overlay->node, false);
    wl_list_init(&slot->output.layer_surfaces);
    out->data = &slot->output;

    slot->frame.notify = handle_slot_frame;
    wl_signal_add(&out->events.frame, &slot->frame);
    slot->output_destroy.notify = handle_slot_output_destroy;
    wl_signal_add(&out->events.destroy, &slot->output_destroy);

    // Park left of x=0 (see the top of this file); adding it to the layout
    // also creates the wl_output global.
    wlr_output_layout_add(server->output_layout, out, -(index + 1) * width, 0);
    wlr_log(WLR_INFO, "window slot %s parked at (%d,0)", slot->name,
            -(index + 1) * width);
    wlr_output_schedule_frame(out); // first (black) frame
    return true;
}

bool hrt_window_slots_create(struct hrt_server *server, int count, int width,
                             int height, int refresh_mhz) {
    if (ws.server || count <= 0) {
        return count == 0;
    }
    if (width <= 0 || height <= 0 || refresh_mhz <= 0) {
        wlr_log(WLR_ERROR, "window slots: bad mode %dx%d@%d mHz", width, height,
                refresh_mhz);
        return false;
    }
    struct wl_event_loop *loop = wl_display_get_event_loop(server->wl_display);
    ws.backend                 = wlr_headless_backend_create(loop);
    if (!ws.backend) {
        return false;
    }
    ws.slots = calloc(count, sizeof(*ws.slots));
    if (!ws.slots) {
        wlr_backend_destroy(ws.backend);
        ws.backend = NULL;
        return false;
    }
    ws.server = server;
    for (int i = 0; i < count; i++) {
        if (!slot_init(&ws.slots[i], i, width, height, refresh_mhz)) {
            wlr_log(WLR_ERROR, "window slots: could not create REC-%d", i + 1);
            break;
        }
        ws.count++;
    }
    wlr_backend_start(ws.backend);
    wlr_log(WLR_INFO, "window slots: %d x %dx%d@%d mHz", ws.count, width,
            height, refresh_mhz);
    clock_set(clock_pick(NULL));
    return ws.count == count;
}

void hrt_window_slots_destroy(struct hrt_server *server) {
    if (server != ws.server) {
        return;
    }
    ws.destroying = true;
    clock_detach();
    ws.engaged = false;
    // Destroying the backend destroys every slot output, which runs
    // handle_slot_output_destroy for each.
    wlr_backend_destroy(ws.backend);
    clock_detach(); // in case anything re-attached it meanwhile
    for (int i = 0; i < ws.count; i++) {
        free(ws.slots[i].rule_app_id);
    }
    free(ws.slots);
    ws.slots      = NULL;
    ws.count      = 0;
    ws.backend    = NULL;
    ws.server     = NULL;
    ws.destroying = false;
}
