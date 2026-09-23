#!/usr/bin/env bash
# Fetch dependencies at the revisions pinned in toolchain.env.
#
#   tools/fetch-vendor.sh [all|agent]
#     all     everything the full plugin build needs (the default)
#     agent   only what tools/build-agent.sh needs: the Nelua compiler, the
#             vendored C the agent's WireGuard compiles in (Monocypher, lwIP,
#             the QR code generator), the Wayland SDK headers when this host
#             can extract them, and moq-iroh (netlab) when cargo is there
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

# A download checked against its pinned sha256 before anything reads it.
fetch_checked() { # url sha256 dest
  curl -fsSL "$1" -o "$3.tmp"
  echo "$2  $3.tmp" | sha256sum -c --quiet - || { rm -f "$3.tmp"; echo "error: $1 does not match its pin" >&2; exit 1; }
  mv "$3.tmp" "$3"
}
# vendor/<name>/.pinned holds the pin it was unpacked from, so a new pin refetches.
pinned() { [[ -f "$V/$1/.pinned" && "$(cat "$V/$1/.pinned")" == "$2" ]]; }

# The agent's WireGuard (docs/WIREGUARD.md): Monocypher, lwIP, the QR code generator.
if ! pinned monocypher "$MONOCYPHER_SHA256"; then
  tmp="$(mktemp -d)"
  fetch_checked "$MONOCYPHER_URL" "$MONOCYPHER_SHA256" "$tmp/monocypher.tar.gz"
  tar -xzf "$tmp/monocypher.tar.gz" -C "$tmp"
  rm -rf "$V/monocypher"
  mkdir -p "$V/monocypher"
  mv "$tmp/monocypher-$MONOCYPHER_VERSION/src" "$tmp/monocypher-$MONOCYPHER_VERSION/LICENCE.md" "$V/monocypher/"
  printf '%s' "$MONOCYPHER_SHA256" >"$V/monocypher/.pinned"
  rm -rf "$tmp"
fi
echo "monocypher $MONOCYPHER_VERSION"
if ! pinned lwip "$LWIP_SHA256"; then
  tmp="$(mktemp -d)"
  fetch_checked "$LWIP_URL" "$LWIP_SHA256" "$tmp/lwip.zip"
  if command -v unzip >/dev/null; then unzip -q "$tmp/lwip.zip" -d "$tmp"
  else python3 -m zipfile -e "$tmp/lwip.zip" "$tmp"; fi
  rm -rf "$V/lwip"
  mkdir -p "$V/lwip"
  # the stack and its licence; not its tests, docs or contrib ports
  mv "$tmp/lwip-$LWIP_VERSION/src" "$tmp/lwip-$LWIP_VERSION/COPYING" "$V/lwip/"
  printf '%s' "$LWIP_SHA256" >"$V/lwip/.pinned"
  rm -rf "$tmp"
fi
echo "lwip $LWIP_VERSION"
if ! pinned qrcodegen "$QRCODEGEN_C_SHA256$QRCODEGEN_H_SHA256"; then
  rm -rf "$V/qrcodegen"
  mkdir -p "$V/qrcodegen"
  fetch_checked "$QRCODEGEN_URL_BASE/qrcodegen.c" "$QRCODEGEN_C_SHA256" "$V/qrcodegen/qrcodegen.c"
  fetch_checked "$QRCODEGEN_URL_BASE/qrcodegen.h" "$QRCODEGEN_H_SHA256" "$V/qrcodegen/qrcodegen.h"
  printf '%s' "$QRCODEGEN_C_SHA256$QRCODEGEN_H_SHA256" >"$V/qrcodegen/.pinned"
fi
# its MIT notice lives in the source's opening comment; packages ship it as a file
[[ -f "$V/qrcodegen/LICENSE" ]] || sed -n '1,/\*\//p' "$V/qrcodegen/qrcodegen.h" >"$V/qrcodegen/LICENSE"
echo "qrcodegen 1.8.0"

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

# moq over iroh for the agent's netlab (docs/NETLAB.md; Linux only; SKIP_NETLAB=1
# to skip). The fork's rs/moq-iroh-c at the pinned commit, built with cargo into
# vendor/moq-iroh: libmoq_iroh.a and moq_iroh.h. Without it the agent builds
# without netlab (tools/netlab-flags.sh).
if [[ "$(uname -s)" == Linux && "${SKIP_NETLAB:-0}" != 1 ]] &&
   [[ "$(cat "$V/moq-iroh/.pinned" 2>/dev/null)" != "$MOQ_IROH_COMMIT" ]]; then
  if command -v cargo >/dev/null; then
    clone_pin moq "$MOQ_IROH_REPOSITORY" "$MOQ_IROH_COMMIT"
    ( cd "$V/moq" && cargo build --locked --release -p moq-iroh-c )
    rm -rf "$V/moq-iroh"
    mkdir -p "$V/moq-iroh"
    cp "$V/moq/target/release/libmoq_iroh.a" "$V/moq/rs/moq-iroh-c/include/moq_iroh.h" "$V/moq-iroh/"
    printf '%s' "$MOQ_IROH_COMMIT" > "$V/moq-iroh/.pinned"
  else
    echo "moq-iroh skipped: cargo is needed (the agent builds without netlab)"
  fi
fi
[[ -f "$V/moq-iroh/.pinned" ]] && echo "moq-iroh @ $(cut -c1-9 "$V/moq-iroh/.pinned")"

if [[ "$MODE" == agent ]]; then
  echo 'agent: the Nelua compiler and the WireGuard sources are all tools/build-agent.sh needs'
  exit 0
fi

# The installed runtime and these compile-time reference assemblies are separate.
if [[ -n "${DALAMUD_LIB_PATH:-}" ]]; then
  [[ -f "$DALAMUD_LIB_PATH/Dalamud.dll" ]] || { echo 'DALAMUD_LIB_PATH lacks Dalamud.dll' >&2; exit 1; }
  echo "using explicit, unverified reference override: $DALAMUD_LIB_PATH"
else
  python3 "$ROOT/tools/fetch-dalamud.py" "$DALAMUD_DISTRIB_URL" "$DALAMUD_DISTRIB_BLOB_SHA1" "$ROOT/vendor/dalamud"
fi
