/* Exercise the production functions from freshly generated Nelua host C. */
#include "../build/host-loading-camera-check.c"
#include <assert.h>
static int flags, writes, reads;
static int test_flags(void) { return flags; }
static int test_read(float *h, float *v, float *d, float *min) {
    ++reads; *h = 0; *v = 0; *d = 5; *min = 1; return 1;
}
static int test_write(float h, float v, float d) {
    (void)h; (void)v; (void)d; ++writes; return 1;
}
int main(void) {
    core_app_state_host.api.scene_flags = test_flags;
    core_app_state_host.api.get_camera_state = test_read;
    core_app_state_host.api.set_camera_state = test_write;
    core_app_state_host.cam_active = true;
    core_app_state_host.cam_restore = true;
    core_app_state_host.cam_saved_d = 12;
    flags = 4;
    core_app_worldview_camera_tick(0.016f);
    assert(writes == 0 && reads == 0);
    assert(!core_app_state_host.cam_active && !core_app_state_host.cam_restore);
    assert(core_app_state_host.cam_saved_d == 0);
    flags = 0;
    core_app_worldview_camera_tick(0.016f);
    assert(writes == 0 && reads == 0); /* no stale restore on arrival */
    core_app_lakitu_steering = true;
    core_app_lakitu_giving_back = true;
    core_app_lakitu_saved_d = 12;
    core_app_lakitu_drop_view(false);
    assert(writes == 0);
    assert(!core_app_lakitu_steering && !core_app_lakitu_giving_back);
    assert(core_app_lakitu_saved_d == 0);
    core_app_lakitu_steering = true;
    core_app_lakitu_saved_d = 12;
    core_app_lakitu_drop_view(true);
    assert(writes == 1); /* ordinary teardown still restores */
    puts("PASS: loading discards saved camera state; arrival does not restore it; ordinary teardown restores");
    return 0;
}
