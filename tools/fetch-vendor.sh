#!/usr/bin/env bash
# Fetch dependencies at the revisions pinned in toolchain.env.
#
#   tools/fetch-vendor.sh [all|agent]
#     all     everything the full plugin build needs (the default)
#     agent   only what tools/build-agent.sh needs: the Nelua compiler, and the
#             Wayland SDK headers when this host can extract them
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/toolchain.env"
V="$ROOT/vendor"
mkdir -p "$V"

MODE="${1:-all}"
case "$MODE" in
  all | agent) ;;
  -h | --help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo 'usage: tools/fetch-vendor.sh [all|agent]' >&2; exit 2 ;;
esac

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

if [[ "$MODE" == all ]]; then
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

if [[ ! -f "$V/stb/stb_truetype.h" ]] || ! echo "$STB_TRUETYPE_SHA256  $V/stb/stb_truetype.h" | sha256sum -c --quiet - >/dev/null 2>&1; then
  mkdir -p "$V/stb"
  curl -fsSL "$STB_TRUETYPE_URL" -o "$V/stb/stb_truetype.h.tmp"
  echo "$STB_TRUETYPE_SHA256  $V/stb/stb_truetype.h.tmp" | sha256sum -c --quiet -
  mv "$V/stb/stb_truetype.h.tmp" "$V/stb/stb_truetype.h"
fi
echo "stb_truetype $(grep -m1 -o 'v[0-9.]*' "$V/stb/stb_truetype.h")"
fi # MODE == all

# The cargo vendor tree for crates/ghostty-iroh (docs/IROH.md). Optional: a
# toolchain.env with no CARGO_VENDOR_URL, or a checkout with no crate, skips it
# and nothing else changes. vendor/cargo doubles as CARGO_HOME, so the
# replace-with stanza below is the one cargo config the build needs.
if [[ -n "${CARGO_VENDOR_URL:-}" ]]; then
  if [[ ! -f "$V/cargo/.pinned" || "$(cat "$V/cargo/.pinned")" != "$CARGO_VENDOR_SHA256" ]]; then
    tmp="$(mktemp -d)"
    curl -fsSL "$CARGO_VENDOR_URL" -o "$tmp/cargo-vendor.tar.gz"
    echo "$CARGO_VENDOR_SHA256  $tmp/cargo-vendor.tar.gz" | sha256sum -c -
    rm -rf "$V/cargo"
    mkdir -p "$V/cargo/registry-vendor"
    tar -xzf "$tmp/cargo-vendor.tar.gz" -C "$V/cargo/registry-vendor" --strip-components=1
    cat >"$V/cargo/config.toml" <<CARGOEOF
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "$V/cargo/registry-vendor"
CARGOEOF
    printf '%s' "$CARGO_VENDOR_SHA256" > "$V/cargo/.pinned"
    rm -rf "$tmp"
  fi
  echo "cargo vendor ${IROH_VERSION:-unpinned} (${CARGO_VENDOR_SHA256:0:12})"
fi

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

if [[ "$MODE" == agent ]]; then
  echo 'agent: the Nelua compiler is all tools/build-agent.sh needs'
  exit 0
fi

# The installed runtime and these compile-time reference assemblies are separate.
if [[ -n "${DALAMUD_LIB_PATH:-}" ]]; then
  [[ -f "$DALAMUD_LIB_PATH/Dalamud.dll" ]] || { echo 'DALAMUD_LIB_PATH lacks Dalamud.dll' >&2; exit 1; }
  echo "using explicit, unverified reference override: $DALAMUD_LIB_PATH"
else
  python3 "$ROOT/tools/fetch-dalamud.py" "$DALAMUD_DISTRIB_URL" "$DALAMUD_DISTRIB_BLOB_SHA1" "$ROOT/vendor/dalamud"
fi
