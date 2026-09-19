#!/usr/bin/env bash
# Fetch every third-party dependency at the revision pinned in toolchain.env.
# Nothing here is modified by us; see docs/ARCHITECTURE.md for what each is for.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/toolchain.env"
V="$ROOT/vendor"
mkdir -p "$V"

clone_pin() { # name repo commit
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

# Wayland SDK headers (Linux only; SKIP_WAYLAND=1 to skip). Needs rpm2cpio and
# cpio. Without it the agent builds with no Wayland compositor backend.
if [[ "$(uname -s)" == Linux && "${SKIP_WAYLAND:-0}" != 1 && ! -f "$V/wayland-sdk/.pinned" ]] ||
   [[ -f "$V/wayland-sdk/.pinned" && "$(cat "$V/wayland-sdk/.pinned")" != "$WAYLAND_SDK_RPMS" ]]; then
  if command -v rpm2cpio >/dev/null && command -v cpio >/dev/null; then
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/root"
    for pin in $WAYLAND_SDK_RPMS; do
      rel="${pin%%:*}"; sum="${pin##*:}"; f="$tmp/$(basename "$rel")"
      curl -fsSL "$WAYLAND_SDK_URL_BASE/$rel" -o "$f"
      echo "$sum  $f" | sha256sum -c --quiet -
      ( cd "$tmp/root" && rpm2cpio "$f" | cpio -idm --quiet './usr/include/*' )
    done
    rm -rf "$V/wayland-sdk"
    mkdir -p "$V/wayland-sdk"
    mv "$tmp/root/usr/include" "$V/wayland-sdk/include"
    printf '%s' "$WAYLAND_SDK_RPMS" > "$V/wayland-sdk/.pinned"
    rm -rf "$tmp"
  else
    echo "wayland-sdk skipped: rpm2cpio and cpio are needed"
  fi
fi
[[ -f "$V/wayland-sdk/.pinned" ]] && echo "wayland-sdk (wlroots 0.20)"

# Dalamud reference assemblies (for compiling the C# shim only).
DD="${DALAMUD_LIB_PATH:-$HOME/.cache/dalamud-dev}"
if [[ ! -f "$DD/Dalamud.dll" ]]; then
  mkdir -p "$DD"
  curl -fsSL "$DALAMUD_DISTRIB_URL" -o "$DD/latest.zip"
  python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$DD/latest.zip" "$DD"
fi
echo "dalamud dev assemblies in $DD"
