#!/usr/bin/env bash
# Fetch dependencies at the revisions pinned in toolchain.env.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/toolchain.env"
V="$ROOT/vendor"
mkdir -p "$V"

clone_pin() {
  local dir="$V/$1"
  if [[ ! -d "$dir/.git" ]]; then
    git clone --filter=blob:none "$2" "$dir"
  fi
  if [[ "$(git -C "$dir" rev-parse HEAD)" != "$3" ]]; then
    git -C "$dir" fetch --quiet origin "$3"
    git -C "$dir" checkout --quiet --detach "$3"
  fi
  echo "$1 @ $(git -C "$dir" rev-parse --short HEAD)"
}

clone_pin nelua-lang "$NELUA_REPOSITORY" "$NELUA_COMMIT"
clone_pin ghostty "$GHOSTTY_REPOSITORY" "$GHOSTTY_COMMIT"
clone_pin gc-cimgui "$CIMGUI_REPOSITORY" "$CIMGUI_COMMIT"
clone_pin umbra-dist "$UMBRA_DIST_REPOSITORY" "$UMBRA_DIST_COMMIT"

if [[ ! -f "$V/lua/src/lua.h" ]]; then
  tmp="$(mktemp -d)"
  curl -fsSL "$LUA_URL" -o "$tmp/lua.tar.gz"
  echo "$LUA_SHA256  $tmp/lua.tar.gz" | sha256sum -c -
  tar -xzf "$tmp/lua.tar.gz" -C "$tmp"
  rm -rf "$V/lua"
  mv "$tmp/lua-$LUA_VERSION" "$V/lua"
  rm -rf "$tmp"
fi
echo "lua $LUA_VERSION"

# The installed runtime and these compile-time reference assemblies are separate.
if [[ -n "${DALAMUD_LIB_PATH:-}" ]]; then
  [[ -f "$DALAMUD_LIB_PATH/Dalamud.dll" ]] || { echo 'DALAMUD_LIB_PATH lacks Dalamud.dll' >&2; exit 1; }
  echo "using explicit, unverified reference override: $DALAMUD_LIB_PATH"
else
  python3 "$ROOT/tools/fetch-dalamud.py" "$DALAMUD_DISTRIB_URL" "$DALAMUD_DISTRIB_BLOB_SHA1" "$ROOT/vendor/dalamud"
fi
