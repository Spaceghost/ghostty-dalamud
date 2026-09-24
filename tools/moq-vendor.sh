#!/usr/bin/env bash
# Cut the moq fork down to moq-iroh-c and vendor every crate it builds from, so
# the agent's netlab library builds with no network: in mock, in COPR, on a
# plane. tools/fetch-vendor.sh runs this; nothing else needs to.
#
#   tools/moq-vendor.sh [SRC] [OUT]
#     SRC   the fork checked out at MOQ_IROH_COMMIT (default vendor/moq)
#     OUT   the offline workspace (default vendor/moq-iroh-src)
#
# OUT holds:
#   Cargo.toml         the fork's workspace manifest, members cut to moq-iroh-c
#                      and the workspace crates it reaches by path
#   Cargo.lock         the fork's lock with every other crate dropped; no version
#                      moves (checked), and its sha256 is MOQ_IROH_LOCK_SHA256
#   rs/<crate>/        those crates, straight out of git at the pinned commit
#   vendor/<crate>-<version>/   every crates.io dependency (`cargo vendor`),
#                      each checked by cargo against the lock's sha256
#   .cargo/config.toml source replacement: crates.io is vendor/, offline
#   .pinned            "<commit> <lock sha256>"
#
# Needs git, python3 and cargo (tools/rust-toolchain.sh), and the network, once.
# Exit codes: 0 done, 1 a check failed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/toolchain.env"
# shellcheck source=tools/rust-toolchain.sh
source "$ROOT/tools/rust-toolchain.sh"

SRC="${1:-$ROOT/vendor/moq}"
OUT="${2:-$ROOT/vendor/moq-iroh-src}"
die() { printf 'moq-vendor: error: %s\n' "$*" >&2; exit 1; }

[[ "$(git -C "$SRC" rev-parse HEAD)" == "$MOQ_IROH_COMMIT" ]] ||
  die "$SRC is not at the pinned $MOQ_IROH_COMMIT"
# shellcheck disable=SC2119 # the host's toolchain, no extra target
ensure_rust

STAGE="$OUT.tmp"
rm -rf "$STAGE"
mkdir -p "$STAGE"

PY="$ROOT/tools/moq_vendor.py"
# moq-iroh-c and every workspace crate it reaches by path
mapfile -t CRATES < <(cargo metadata --no-deps --format-version 1 --manifest-path "$SRC/Cargo.toml" | python3 "$PY" closure)
[[ ${#CRATES[@]} -gt 0 ]] || die 'found no moq-iroh-c in the fork'
# [patch.crates-io] points at workspace paths too; keep what it names so the
# manifest loads (cargo only warns about a patch nothing uses).
mapfile -t PATCHED < <(python3 "$PY" patched "$SRC/Cargo.toml")
echo "== moq-vendor: ${CRATES[*]}${PATCHED:+ (patched: ${PATCHED[*]})}"

# Out of git, never the working tree: a stray target/ or edit never travels.
git -C "$SRC" archive --format=tar HEAD -- Cargo.toml Cargo.lock 'LICENSE*' "${CRATES[@]}" "${PATCHED[@]}" |
  tar -x -C "$STAGE"
cp "$STAGE/Cargo.lock" "$STAGE/Cargo.lock.fork"

# The members list becomes the crates we took; default-members goes, since it
# names crates that are not here. Everything else in the manifest (workspace
# package fields, workspace dependencies, [patch], profiles) stays as the fork has it.
python3 "$PY" members "$STAGE/Cargo.toml" "${CRATES[@]}"

# Resolving the cut-down workspace drops every lock entry nothing here uses. It
# must not move a single version: prove it against the fork's own lock.
( cd "$STAGE" && cargo metadata --format-version 1 >/dev/null )
python3 "$PY" lock-subset "$STAGE/Cargo.lock.fork" "$STAGE/Cargo.lock"
rm "$STAGE/Cargo.lock.fork"

mkdir -p "$STAGE/.cargo"
( cd "$STAGE" && cargo vendor --locked --versioned-dirs vendor >.cargo/config.toml.new )
{
  echo '# Written by tools/moq-vendor.sh: every crate comes from vendor/, never the network.'
  cat "$STAGE/.cargo/config.toml.new"
  printf '\n[net]\noffline = true\n'
} >"$STAGE/.cargo/config.toml"
rm "$STAGE/.cargo/config.toml.new"

# `cargo vendor` takes every crate in the lock for every platform: 800 MB, most
# of it Windows import libraries for i686, ARM and MSVC. Keep, whole, what
# moq-iroh-c builds from for the two targets we ship (and the build scripts
# that run on the Linux host); the rest become empty stubs, as
# cargo-vendor-filterer and the distributions' own vendoring do: the manifest
# stays (cargo still resolves the lock against it), every target path becomes an
# empty file, and .cargo-checksum.json keeps the package's sha256 but lists no
# files. A stub that some build did need fails loudly at compile time.
KEEP="$STAGE/.keep"
: >"$KEEP"
for t in x86_64-unknown-linux-gnu x86_64-pc-windows-gnu; do
  ( cd "$STAGE" && cargo tree --offline --locked -p moq-iroh-c --target "$t" -e normal,build \
      --prefix none --format '{p}' ) | tee "$STAGE/.keep-$t" >>"$KEEP"
done
# .keep-<target> stays: tools/package-agent.sh stubs the Windows-only crates too,
# in a source tarball that only ever builds for Linux.
python3 "$PY" stub "$STAGE/vendor" "$KEEP"
rm "$KEEP"

LOCK_SHA="$(sha256sum "$STAGE/Cargo.lock" | cut -d' ' -f1)"
if [[ -z "${MOQ_IROH_LOCK_SHA256:-}" ]]; then
  echo "moq-vendor: warning: MOQ_IROH_LOCK_SHA256 is not pinned; this lock is $LOCK_SHA" >&2
elif [[ "$LOCK_SHA" != "$MOQ_IROH_LOCK_SHA256" ]]; then
  die "the cut-down Cargo.lock is $LOCK_SHA, toolchain.env pins $MOQ_IROH_LOCK_SHA256"
fi
printf '%s %s\n' "$MOQ_IROH_COMMIT" "$LOCK_SHA" >"$STAGE/.pinned"
rm -rf "$OUT"
mv "$STAGE" "$OUT"
echo "== moq-vendor: $OUT ($(du -sh "$OUT" | cut -f1), $(find "$OUT/vendor" -mindepth 1 -maxdepth 1 -type d | wc -l) crates)"
