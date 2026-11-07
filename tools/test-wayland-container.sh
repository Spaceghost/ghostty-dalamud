#!/usr/bin/env bash
# Run real compositor tests in the prepared Fedora 44 test container.
# Preparation/dependency installation is documented in docs/REMOTE_WINDOWS.md.
set -euo pipefail
container="${GHOSTTY_WAYLAND_TEST_CONTAINER:-ghostty-vote-compositor-tests}"
podman exec -i --env "GHOSTTY_TEST_CFLAGS=${GHOSTTY_TEST_CFLAGS:-}" \
  --env GHOSTTY_NOTIFICATION_HELPER=/work/tools/app_notifications.py "$container" bash -s <<'INNER'
set -euo pipefail
cd /work
command -v yad >/dev/null
command -v python3 >/dev/null
command -v rsvg-convert >/dev/null
command -v dbus-daemon >/dev/null
python3 -c 'import dbus_next'
pkg-config --exists wlroots-0.20 wayland-server xkbcommon pixman-1
runtime="$(mktemp -d /tmp/ghostty-wayland-test.XXXXXX)"
trap 'rm -rf "$runtime"' EXIT
chmod 700 "$runtime"
export XDG_RUNTIME_DIR="$runtime"
unset DISPLAY WAYLAND_DISPLAY
vendor/nelua-lang/nelua --cc gcc -P nogc --cache-dir build/notification-process-cache \
  -L . -o build/test-notification-process -b tests/test_notification_process.nelua
build/test-notification-process /work/tools/app_notifications.py
mkdir -p build/container-wayland-results
flags="$(pkg-config --cflags --libs wlroots-0.20 wayland-server xkbcommon pixman-1) ${GHOSTTY_TEST_CFLAGS:-}"
vendor/nelua-lang/nelua --cc gcc -D WAYLAND -P nogc --cflags="$flags" \
  --cache-dir build/container-wayland-cache -L . -b tests/test_wayland_compositor.nelua
build/container-wayland-cache/test_wayland_compositor /work/build/container-wayland-results
INNER
