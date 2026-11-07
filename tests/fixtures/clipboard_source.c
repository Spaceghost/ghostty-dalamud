/* Private integration source: no keyboard serial or real desktop required. */
#define main snapshot_main
#include "../../tools/clipboard_snapshot.c"
#undef main
#include <signal.h>

static bool slow;

static void send_data(void *data, struct ext_data_control_source_v1 *source,
                      const char *type, int fd) {
    (void)data; (void)source;
    printf("requested:%s\n", type); fflush(stdout);
    if (slow) sleep(1);
    const char text[] = "fixture clipboard text";
    (void)write(fd, text, sizeof(text) - 1);
    close(fd);
}
static void cancelled(void *data, struct ext_data_control_source_v1 *source) {
    (void)data; (void)source; finished = true;
}
static const struct ext_data_control_source_v1_listener source_listener = {
    .send = send_data, .cancelled = cancelled
};
int main(int argc, char **argv) {
    slow = argc > 1 && !strcmp(argv[1], "slow");
    signal(SIGPIPE, SIG_IGN);
    alarm(10);
    display = wl_display_connect(NULL);
    if (!display) return 1;
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    if (wl_display_roundtrip(display) < 0 || !manager || !seat) return 1;
    struct ext_data_control_device_v1 *device = ext_data_control_manager_v1_get_data_device(manager, seat);
    struct ext_data_control_source_v1 *source = ext_data_control_manager_v1_create_data_source(manager);
    ext_data_control_source_v1_add_listener(source, &source_listener, NULL);
    ext_data_control_source_v1_offer(source, "text/plain;charset=utf-8");
    if (!slow) ext_data_control_source_v1_offer(source, "application/x-nspasteboard-concealed-type");
    ext_data_control_device_v1_set_selection(device, source);
    if (wl_display_roundtrip(display) < 0) return 1;
    puts("published:1"); fflush(stdout);
    while (!finished && wl_display_dispatch(display) >= 0) {}
    wl_display_disconnect(display);
    return 0;
}
