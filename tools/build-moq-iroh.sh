#!/usr/bin/env bash
# Build libmoq_iroh.a, the agent's netlab library (docs/NETLAB.md), from the
# offline workspace tools/moq-vendor.sh wrote. No network: every crate is in
# vendor/moq-iroh-src/vendor and cargo runs --offline --locked.
#
#   tools/build-moq-iroh.sh [linux] [windows]     (default: linux)
#
# Output:
#   vendor/moq-iroh/libmoq_iroh.a, moq_iroh.h                  linux
#   vendor/moq-iroh/x86_64-pc-windows-gnu/libmoq_iroh.a        windows
#
# The staticlib alone (`cargo rustc --crate-type staticlib`): the crate also
# declares a cdylib, and linking that for Windows would need a MinGW linker we do
# not otherwise have. The C parts of the dependency tree (ring) are compiled for
# Windows with the pinned Zig, the same compiler that builds ghostty-agent.exe,
# and Zig's llvm-dlltool makes the import libraries, so no MinGW is needed.
#
# Size: fat LTO and one codegen unit, so the archive is one object the agent's
# --gc-sections can cut down; no debug info (the agent's own release builds are
# stripped, and the RPM keeps its debug info in -debuginfo).
#
# Environment:
#   MOQ_IROH_SRC   the offline workspace (default vendor/moq-iroh-src)
#   MOQ_IROH_OUT   where the libraries go (default vendor/moq-iroh)
#   RUST_SYSTEM=1  build with the cargo on PATH (the RPM: Fedora's rust)
#   ZIG            zig for the Windows C parts (default: zig on PATH)
#   JOBS           cargo -j
#
# Exit codes: 0 done, 1 a build failed or an input is missing, 2 bad argument.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/toolchain.env"
# shellcheck source=tools/rust-toolchain.sh
source "$ROOT/tools/rust-toolchain.sh"
die() { printf 'build-moq-iroh: error: %s\n' "$*" >&2; exit 1; }

SRC="${MOQ_IROH_SRC:-$ROOT/vendor/moq-iroh-src}"
OUT="${MOQ_IROH_OUT:-$ROOT/vendor/moq-iroh}"
WANT=()
for a in "$@"; do
  case "$a" in
    linux | windows) WANT+=("$a") ;;
    -h | --help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown target: $a (linux, windows)" >&2; exit 2 ;;
  esac
done
[[ ${#WANT[@]} -gt 0 ]] || WANT=(linux)

[[ -f "$SRC/.pinned" && -f "$SRC/.cargo/config.toml" ]] ||
  die "$SRC is not an offline moq-iroh workspace; run tools/fetch-vendor.sh"
[[ "$(cut -d' ' -f1 "$SRC/.pinned")" == "$MOQ_IROH_COMMIT" ]] ||
  die "$SRC is from $(cut -d' ' -f1 "$SRC/.pinned"), toolchain.env pins $MOQ_IROH_COMMIT; run tools/fetch-vendor.sh"

targets=()
for w in "${WANT[@]}"; do [[ "$w" == windows ]] && targets+=(x86_64-pc-windows-gnu); done
ensure_rust "${targets[@]}"

export CARGO_PROFILE_RELEASE_LTO=fat
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
export CARGO_PROFILE_RELEASE_DEBUG=0
export CARGO_PROFILE_RELEASE_PANIC=abort
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$SRC/target}"
# a path in the archive's panic messages, not the builder's home
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$SRC=moq-iroh-src"
jobs=()
[[ -n "${JOBS:-}" ]] && jobs=(-j "$JOBS")

build() { # rust-target out-dir
  local t="$1" dst="$2"
  echo "== moq-iroh: $t"
  ( cd "$SRC" && "$RUST_BIN/cargo" rustc --offline --locked --release "${jobs[@]}" \
      -p moq-iroh-c --lib --crate-type staticlib --target "$t" )
  mkdir -p "$dst"
  cp "$CARGO_TARGET_DIR/$t/release/libmoq_iroh.a" "$dst/libmoq_iroh.a.new"
  mv -f "$dst/libmoq_iroh.a.new" "$dst/libmoq_iroh.a"
  echo "== $dst/libmoq_iroh.a ($(du -h "$dst/libmoq_iroh.a" | cut -f1))"
}

for w in "${WANT[@]}"; do
  case "$w" in
    linux)
      [[ "$(uname -s)-$(uname -m)" == Linux-x86_64 ]] || die 'the Linux library is built on Linux x86_64'
      build x86_64-unknown-linux-gnu "$OUT"
      ;;
    windows)
      zig="${ZIG:-$(command -v zig || true)}"
      [[ -x "$zig" ]] || die 'the Windows library needs zig for its C parts (ZIG=/path/to/zig)'
      # One wrapper is both the C compiler (cc-rs) and the linker: zig for
      # x86_64-windows-gnu, as tools/zig-cc-win.sh does for the agent, so no
      # MinGW is needed. The linker only ever links a dependency's cdylib that
      # nothing uses (iroh-relay declares one, and cargo builds every declared
      # crate type), so what zig will not take is dropped rather than
      # translated: cc-rs's --target=<rust triple>, MinGW's own runtime
      # libraries (zig brings its own), GNU ld options, and the .def export
      # list. libgcc_eh's unwinder is zig's libunwind. No UBSan: zig turns it
      # on at -O0, which aws-lc builds jitterentropy at, and nothing links its
      # runtime.
      wrap="$CARGO_TARGET_DIR/zig-win"
      mkdir -p "$wrap"
      # shellcheck disable=SC2016 # the wrapper's own $a and $@, written literally
      {
        echo '#!/bin/sh'
        echo 'for a; do'
        echo '  shift'
        echo '  case "$a" in'
        echo '    --target=* | -lgcc | -lgcc_s | -l:libpthread.a | -lmsvcrt | -lmingwex | -lmingw32 | -lmoldname) ;;'
        echo '    -fno-use-linker-plugin | -Wl,--disable-auto-image-base | -Wl,*.def) ;;'
        echo '    -lgcc_eh) set -- "$@" -lunwind ;;'
        echo '    *) set -- "$@" "$a" ;;'
        echo '  esac'
        echo 'done'
        printf 'exec "%s" cc -target x86_64-windows-gnu -fno-sanitize=undefined "$@"\n' "$zig"
      } >"$wrap/cc"
      printf '#!/bin/sh\nexec "%s" ar "$@"\n' "$zig" >"$wrap/ar"
      # rustc makes the import libraries of raw-dylib crates (windows-sys) with
      # dlltool, by default MinGW's x86_64-w64-mingw32-dlltool, which a runner
      # need not have. zig's is llvm-dlltool; it takes GNU dlltool's arguments
      # except --temp-prefix, which only names GNU's scratch files.
      # shellcheck disable=SC2016 # the wrapper's own $a and $@, written literally
      {
        echo '#!/bin/sh'
        echo 'skip=0'
        echo 'for a; do'
        echo '  shift'
        echo '  if [ "$skip" = 1 ]; then skip=0; continue; fi'
        echo '  case "$a" in'
        echo '    --temp-prefix) skip=1 ;;'
        echo '    --temp-prefix=*) ;;'
        echo '    *) set -- "$@" "$a" ;;'
        echo '  esac'
        echo 'done'
        printf 'exec "%s" dlltool "$@"\n' "$zig"
      } >"$wrap/dlltool"
      chmod +x "$wrap/cc" "$wrap/ar" "$wrap/dlltool"
      export CC_x86_64_pc_windows_gnu="$wrap/cc" AR_x86_64_pc_windows_gnu="$wrap/ar"
      export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER="$wrap/cc"
      # the linker is zig, not a MinGW gcc: rustc must not add MinGW's own crt
      RUSTFLAGS="$RUSTFLAGS -C link-self-contained=no -C dlltool=$wrap/dlltool" build x86_64-pc-windows-gnu "$OUT/x86_64-pc-windows-gnu"
      ;;
  esac
done
cp "$SRC/rs/moq-iroh-c/include/moq_iroh.h" "$OUT/moq_iroh.h"
cut -d' ' -f1 "$SRC/.pinned" | tr -d '\n' >"$OUT/.pinned"
