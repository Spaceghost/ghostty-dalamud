#!/usr/bin/env bash
# Pack the agent's own source: everything tools/build-agent.sh compiles, the
# pinned Nelua compiler, and the RPM spec at the tree root, so
# `rpmbuild -tb ghostty-agent-<version>-src.tar.gz` builds a package offline.
#
#   tools/package-agent.sh [--version V] [--out DIR]
#
# Output, under build/dist by default (<version> is AssemblyVersion from
# shim/GhosttyDalamud/GhosttyDalamud.json):
#   ghostty-agent-<version>-src.tar.gz   the agent's sources, vendor/nelua-lang
#                                        at the pinned commit, and the spec
#
# Environment:
#   SOURCE_DATE_EPOCH   file times in the tarball (default: the last commit's time)
#
# Exit codes: 0 done, 1 an input is missing, 2 bad argument, 127 GNU tar or gzip missing.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source "$ROOT/toolchain.env"

usage() { sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

VERSION=""
OUT="build/dist"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) [[ $# -ge 2 ]] || { echo "error: $1 needs a value" >&2; exit 2; }; VERSION="$2"; shift ;;
    --out) [[ $# -ge 2 ]] || { echo "error: $1 needs a directory" >&2; exit 2; }; OUT="$2"; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

command -v gzip >/dev/null || { echo "error: gzip is required" >&2; exit 127; }
tar --version | head -n1 | grep -q GNU || { echo "error: GNU tar is required" >&2; exit 127; }

if [[ -z "$VERSION" ]]; then
  MANIFEST="shim/GhosttyDalamud/GhosttyDalamud.json"
  [[ -f "build/dist/GhosttyDalamud/GhosttyDalamud.json" ]] && MANIFEST="build/dist/GhosttyDalamud/GhosttyDalamud.json"
  VERSION="$(sed -n 's/^[[:space:]]*"AssemblyVersion"[[:space:]]*:[[:space:]]*"\([0-9.]*\)".*/\1/p' "$MANIFEST" | head -n1)"
fi
[[ -n "$VERSION" ]] || { echo "error: no AssemblyVersion to package" >&2; exit 1; }

[[ -d vendor/nelua-lang/.git ]] || {
  echo "error: vendor/nelua-lang is not a checkout; run tools/fetch-vendor.sh agent" >&2
  exit 1
}
[[ "$(git -C vendor/nelua-lang rev-parse HEAD)" == "$NELUA_COMMIT" ]] || {
  echo "error: vendor/nelua-lang is not at the pinned commit $NELUA_COMMIT" >&2
  exit 1
}

if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
  SOURCE_DATE_EPOCH="$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || echo 0)"
fi

STAGE="build/package-agent-stage"
DST="$STAGE/ghostty-agent-$VERSION"
rm -rf "$STAGE"
mkdir -p "$DST" "$OUT"

# Whole directories out of git, never a hand-kept file list: a list rots
# silently the first time the agent grows a new `require`.
while IFS= read -r -d '' f; do
  mkdir -p "$DST/$(dirname "$f")"
  cp -p "$f" "$DST/$f"
done < <(git ls-files -z -- agent core compat \
  tools/build-agent.sh tools/build-common.sh tools/wayland-flags.sh tools/zig-cc.sh \
  packaging/ghostty-agent.service packaging/README-agent.md packaging/ghostty-agent.1)

# git archive emits tracked files only, so a host-built nelua-lua never travels:
# `make` would then say "up to date" and the foreign-libc interpreter would fail
# to exec inside the container.
git -C vendor/nelua-lang archive --format=tar --prefix=vendor/nelua-lang/ "$NELUA_COMMIT" | tar -x -C "$DST"

# The embedded WireGuard's vendored C (docs/WIREGUARD.md), exactly as
# tools/fetch-vendor.sh checked it against toolchain.env: the package builds
# offline, so it must travel in the tarball.
for dep in monocypher:MONOCYPHER_SHA256 lwip:LWIP_SHA256 qrcodegen:QRCODEGEN_C_SHA256; do
  dir="${dep%%:*}" pin_var="${dep##*:}"
  want="${!pin_var}"
  [[ "$dir" == qrcodegen ]] && want="$QRCODEGEN_C_SHA256$QRCODEGEN_H_SHA256"
  [[ -f "vendor/$dir/.pinned" && "$(cat "vendor/$dir/.pinned")" == "$want" ]] || {
    echo "error: vendor/$dir is missing or not at its pin; run tools/fetch-vendor.sh agent" >&2
    exit 1
  }
  mkdir -p "$DST/vendor/$dir"
  cp -pR "vendor/$dir/." "$DST/vendor/$dir/"
done

cp -p packaging/ghostty-agent.spec "$DST/ghostty-agent.spec"
cp -p packaging/README-agent.md "$DST/README-agent.md"
printf '%s\n' "$VERSION" >"$DST/VERSION"
if [[ -f LICENSE ]]; then cp -p LICENSE "$DST/LICENSE"; fi

# Three guards, each saying what is wrong rather than just failing.
if find "$DST" -name nelua-lua -print -quit | grep -q .; then
  echo "error: a built nelua-lua is in the tarball; it must be built inside the package" >&2
  exit 1
fi
if find "$DST" -name .git -print -quit | grep -q .; then
  echo "error: a .git directory is in the tarball" >&2
  exit 1
fi
if find "$DST" \( -name '*.o' -o -name '*.a' \) -print -quit | grep -q .; then
  echo "error: object files are in the tarball" >&2
  exit 1
fi

TARBALL="$OUT/ghostty-agent-$VERSION-src.tar.gz"
echo "== $(basename "$TARBALL")"
find "$DST" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
rm -f "$TARBALL"
( cd "$STAGE" && find . \( -type f -o -type l \) | LC_ALL=C sort | sed 's|^\./||' |
  tar --format=gnu --numeric-owner --owner=0 --group=0 --mtime="@$SOURCE_DATE_EPOCH" \
    --no-recursion -T - -cf - ) | gzip -n -9 >"$TARBALL"
rm -rf "$STAGE"
ls -la "$TARBALL"
