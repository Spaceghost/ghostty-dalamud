#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$root/build/dist/clipboard-snapshot}"
cache="$root/build/clipboard-helper"
xml="$(pkg-config --variable=pkgdatadir wayland-protocols)/staging/ext-data-control/ext-data-control-v1.xml"
mkdir -p "$cache" "$(dirname "$out")"
wayland-scanner client-header "$xml" "$cache/ext-data-control-client.h"
wayland-scanner private-code "$xml" "$cache/ext-data-control-protocol.c"
read -r -a flags <<< "$(pkg-config --cflags --libs wayland-client)"
read -r -a extra <<< "${CFLAGS:-} ${LDFLAGS:-}"
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -O2 -I"$cache" \
  "$root/tools/clipboard_snapshot.c" "$cache/ext-data-control-protocol.c" \
  "${flags[@]}" "${extra[@]}" -o "$out"
