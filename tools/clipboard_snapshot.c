/* One source offer supplies both MIME hints and text. No sensitive text reads.
 * stdout: one flags byte (1=safe, 3=sensitive), then <=65536 text bytes.
 * Failure/unsupported protocol/stale source: nonzero exit, no stdout.
 */
#define _GNU_SOURCE
#include <wayland-client.h>
#include "ext-data-control-client.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct offer {
    struct ext_data_control_offer_v1 *proxy;
    struct offer *next;
    const char *text_type;
    bool sensitive;
};
static struct wl_display *display;
static struct wl_seat *seat;
static struct ext_data_control_manager_v1 *manager;
static struct offer *offers, *selected;
static unsigned generation;
static bool finished;

static void mime(void *data, struct ext_data_control_offer_v1 *proxy, const char *type) {
    (void)proxy;
    struct offer *offer = data;
    if (!strcmp(type, "x-kde-passwordManagerHint") ||
        !strcmp(type, "application/x-nspasteboard-concealed-type") ||
        !strcmp(type, "ExcludeClipboardContentFromMonitorProcessing")) offer->sensitive = true;
    if (!strcmp(type, "text/plain;charset=utf-8")) offer->text_type = "text/plain;charset=utf-8";
    else if (!offer->text_type && !strcmp(type, "text/plain")) offer->text_type = "text/plain";
    else if (!offer->text_type && !strcmp(type, "UTF8_STRING")) offer->text_type = "UTF8_STRING";
}
static const struct ext_data_control_offer_v1_listener offer_listener = { .offer = mime };
static void new_offer(void *data, struct ext_data_control_device_v1 *device,
                      struct ext_data_control_offer_v1 *proxy) {
    (void)data; (void)device;
    struct offer *offer = calloc(1, sizeof(*offer));
    if (!offer) { finished = true; return; }
    offer->proxy = proxy; offer->next = offers; offers = offer;
    ext_data_control_offer_v1_add_listener(proxy, &offer_listener, offer);
}
static void selection(void *data, struct ext_data_control_device_v1 *device,
                      struct ext_data_control_offer_v1 *proxy) {
    (void)data; (void)device;
    selected = NULL; generation++;
    for (struct offer *offer = offers; offer; offer = offer->next)
        if (offer->proxy == proxy) { selected = offer; break; }
}
static void stop(void *data, struct ext_data_control_device_v1 *device) {
    (void)data; (void)device; finished = true;
}
static void primary(void *data, struct ext_data_control_device_v1 *device,
                    struct ext_data_control_offer_v1 *proxy) {
    (void)data; (void)device; (void)proxy;
}
static const struct ext_data_control_device_v1_listener device_listener = {
    .data_offer = new_offer, .selection = selection, .finished = stop, .primary_selection = primary
};
static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (!manager && !strcmp(interface, "ext_data_control_manager_v1"))
        manager = wl_registry_bind(registry, name, &ext_data_control_manager_v1_interface, 1);
    else if (!seat && !strcmp(interface, "wl_seat"))
        seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}
static const struct wl_registry_listener registry_listener = { global, removed };

static int snapshot(uint8_t *output, size_t *length) {
    if (finished || !selected) return 1;
    if (selected->sensitive) { output[0] = 3; *length = 1; return 0; }
    if (!selected->text_type) return 1;
    unsigned source_generation = generation;
    int pipefd[2];
    if (pipe2(pipefd, O_CLOEXEC | O_NONBLOCK)) return 1;
    ext_data_control_offer_v1_receive(selected->proxy, selected->text_type, pipefd[1]);
    close(pipefd[1]);
    size_t used = 1;
    output[0] = 1;
    int result = 1;
    while (!finished && generation == source_generation) {
        /* Process replacement offers while waiting for a slow source's pipe.
         * prepare_read also drains queued Wayland events before we can publish.
         */
        while (wl_display_prepare_read(display) != 0) {
            if (wl_display_dispatch_pending(display) < 0) goto done;
        }
        if (finished || generation != source_generation) { wl_display_cancel_read(display); break; }
        if (wl_display_flush(display) < 0 && errno != EAGAIN) { wl_display_cancel_read(display); break; }
        struct pollfd fds[2] = {
            { .fd = wl_display_get_fd(display), .events = POLLIN },
            { .fd = pipefd[0], .events = POLLIN }
        };
        int ready = poll(fds, 2, 1000);
        if (ready <= 0) { wl_display_cancel_read(display); break; }
        if (fds[0].revents & POLLIN) {
            if (wl_display_read_events(display) < 0 || wl_display_dispatch_pending(display) < 0) break;
        } else wl_display_cancel_read(display);
        if (finished || generation != source_generation ||
            (fds[0].revents & (POLLERR | POLLHUP | POLLNVAL))) break;
        if (fds[1].revents & (POLLIN | POLLHUP)) {
            uint8_t chunk[8192];
            ssize_t size = read(pipefd[0], chunk, sizeof(chunk));
            if (size == 0) { result = 0; *length = used; break; }
            if (size < 0) { if (errno == EAGAIN || errno == EINTR) continue; break; }
            if (used + (size_t)size > 65537) break;
            memcpy(output + used, chunk, (size_t)size); used += (size_t)size;
        }
    }
done:
    close(pipefd[0]);
    return result;
}

int main(void) {
    /* Includes connection, registry, source and output wait; never hang the agent. */
    alarm(2);
    int result = 1;
    display = wl_display_connect(NULL);
    if (!display) return 1;
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    struct ext_data_control_device_v1 *device = NULL;
    if (wl_display_roundtrip(display) < 0 || !manager || !seat) goto done;
    device = ext_data_control_manager_v1_get_data_device(manager, seat);
    ext_data_control_device_v1_add_listener(device, &device_listener, NULL);
    if (wl_display_roundtrip(display) < 0) goto done;
    uint8_t output[65537]; size_t length = 0;
    if (snapshot(output, &length)) goto done;
    if (fwrite(output, 1, length, stdout) != length || fflush(stdout)) goto done;
    result = 0;
done:
    for (struct offer *offer = offers, *next; offer; offer = next) {
        next = offer->next; ext_data_control_offer_v1_destroy(offer->proxy); free(offer);
    }
    if (device) ext_data_control_device_v1_destroy(device);
    if (manager) ext_data_control_manager_v1_destroy(manager);
    if (seat) wl_seat_destroy(seat);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return result;
}
