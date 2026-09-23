#!/usr/bin/env bash
# Build ghostty-agent alone: the one piece a player who is not building the
# plugin needs. A C compiler and make, and nothing else — no Zig, no .NET SDK,
# no Dalamud reference assemblies, no vendor/ghostty. tools/build.sh builds the
# same binary with the pinned Zig toolchain as part of a full build.
# Darwin support remains experimental until tested there.
#
#   tools/fetch-vendor.sh agent && tools/build-agent.sh
#   tools/build-agent.sh [--wayland|--no-wayland] [-o PATH] [-j N]
#
# Output:
#   build/dist/ghostty-agent   the PTY server for the machine that runs your shells
#
# Environment:
#   CC        the C compiler (default: cc)
#   CFLAGS    extra compiler flags, appended last (Fedora's %set_build_flags)
#   LDFLAGS   extra link flags, appended last
#   JOBS      parallelism for the Nelua compiler build
#   SKIP_WAYLAND  1 to leave the compositor backend out
#
# Exit codes: 0 done, 1 a dependency is missing, 2 bad argument or unsupported
# platform, 127 no C compiler.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
case "$(uname -s)" in Linux | Darwin) ;; *) echo 'The agent requires Linux or macOS.' >&2; exit 2 ;; esac

usage() { sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

OUT="build/dist/ghostty-agent"
WANT_WAYLAND=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wayland) WANT_WAYLAND=1 ;;
    --no-wayland) SKIP_WAYLAND=1 ;;
    -o | --output) [[ $# -ge 2 ]] || { echo "error: $1 needs a path" >&2; exit 2; }; OUT="$2"; shift ;;
    -j | --jobs) [[ $# -ge 2 ]] || { echo "error: $1 needs a number" >&2; exit 2; }; JOBS="$2"; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
export SKIP_WAYLAND="${SKIP_WAYLAND:-0}"

# The agent's own flags. The Nelua compiler is built without them: it is a build
# tool, not a shipped artifact, and a distribution's hardening flags are for the
# code that ships.
AGENT_CFLAGS="${CFLAGS:-}"
AGENT_LDFLAGS="${LDFLAGS:-}"
unset CFLAGS LDFLAGS

CC="${CC:-cc}"
# shellcheck source=tools/build-common.sh
source "$ROOT/tools/build-common.sh"
[[ -d vendor/nelua-lang ]] || {
  echo 'error: vendor/nelua-lang is missing; run tools/fetch-vendor.sh agent' >&2
  exit 1
}
build_nelua
mkdir -p "$(dirname "$OUT")" build/nelua-cache

# shellcheck source=tools/wayland-flags.sh
source "$ROOT/tools/wayland-flags.sh"
if [[ "$WANT_WAYLAND" == 1 && ${#WAYLAND_DEFINE[@]} -eq 0 ]]; then
  echo 'error: no Wayland backend available; install wlroots-devel wayland-devel wayland-protocols-devel libxkbcommon-devel pixman-devel (Fedora 44 or newer), or run tools/fetch-vendor.sh' >&2
  exit 1
fi

# Optional iroh staticlib (docs/IROH.md). iroh_probe leaves everything empty
# unless IROH=1 and crates/ghostty-iroh exists, so a checkout without the crate
# builds exactly as before. Host only: this script never builds Windows.
SKIP_WIN=1 iroh_probe
build_iroh

# Nelua takes one --cflags and keeps the last, so everything goes in one string.
cflags="-I\"$ROOT/compat\""
if [[ -n "${WAYLAND_CFLAGS:-}" ]]; then cflags="$cflags $WAYLAND_CFLAGS"; fi
if [[ -n "$AGENT_CFLAGS" ]]; then cflags="$cflags $AGENT_CFLAGS"; fi
if [[ -n "$AGENT_LDFLAGS" ]]; then cflags="$cflags $AGENT_LDFLAGS"; fi
# The libraries go in --ldflags, not --cflags: nelua runs --cflags through its
# compiler-information probe, and zig refuses a probe that links objects.
iroh_def=()
[[ -n "$(iroh_host_ldflags)" ]] && iroh_def=(-D IROH)
"$ROOT/vendor/nelua-lang/nelua" --cc "$CC" -P nogc "${WAYLAND_DEFINE[@]}" "${iroh_def[@]}" \
  --cflags="$cflags" --ldflags="$(iroh_host_ldflags)" --cache-dir build/nelua-cache -L . -o "$OUT" -b agent/agent.nelua

if [[ ${#WAYLAND_DEFINE[@]} -gt 0 ]]; then wl=yes; else wl=no; fi
echo "== $OUT (wayland compositor: $wl)"
