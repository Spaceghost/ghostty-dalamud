#!/usr/bin/env bash
# Fresh production C; native compilation stays in the capped compositor builder.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
vendor/nelua-lang/nelua -c -P nogc -P noentrypoint \
    -P "writestderr='hooked'" -P "abort='hooked'" -L . \
    -o build/host-loading-camera-check.c core/host.nelua
podman exec "${GHOSTTY_TEST_CONTAINER:-ghostty-vote-compositor-tests}" bash -lc \
    'cd /work && gcc -O2 -ffunction-sections -fdata-sections -Wl,--gc-sections -Ivendor/ghostty/include -Ivendor/gc-cimgui -Ivendor/lua/src -Ivendor/stb tests/test_loading_camera.c -lm -o build/test-loading-camera && build/test-loading-camera'
