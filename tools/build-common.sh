#!/usr/bin/env bash
# Shared build helpers. Callers provide ROOT; this file does not change cwd.
# The C compiler is Zig through tools/zig-cc.sh: one pinned toolchain builds
# the Nelua compiler, the Lua objects and every Nelua target, host and
# Windows alike, and the build needs no system gcc. Set CC to override.
BUILD_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC="${CC:-$BUILD_COMMON_DIR/zig-cc.sh}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1)}"
case "$JOBS" in ''|*[!0-9]*|0) JOBS=1 ;; esac
require_linux_build_host() {
  [[ "$(uname -s)" == Linux ]] || {
    echo 'The full plugin build currently requires Linux. macOS agent support is experimental.' >&2
    return 2
  }
}
build_nelua() {
  # nelua is a tracked executable launcher, not evidence of a built compiler.
  command -v "$CC" >/dev/null || { echo "C compiler not found: $CC" >&2; return 127; }
  make -C "$ROOT/vendor/nelua-lang" -j"$JOBS" CC="$CC"
  [[ -x "$ROOT/vendor/nelua-lang/nelua-lua" ]] || {
    echo 'Nelua build did not produce nelua-lua.' >&2; return 1;
  }
}

# --- crates/ghostty-iroh (docs/IROH.md) --------------------------------------
# An optional Rust staticlib, off by default. IROH=1 turns it on. Without that,
# without the crate, or without cargo, every function below is a no-op and the
# build is the build it was before -- the crate is not a dependency until it
# works. Nothing here has been built or run; see docs/iroh-build-wiring.md.
IROH_CRATE_DIR="${IROH_CRATE_DIR:-$ROOT/crates/ghostty-iroh}"
IROH_WIN_TARGET="${RUST_WINDOWS_TARGET:-x86_64-pc-windows-gnu}"
# Windows system libraries the crate's objects need, named AFTER -lghostty_iroh
# because the MinGW link is single pass (docs/IROH.md, "The two risks").
# oleaut32/propsys: the ipconfig crate (hickory-resolver's Windows DNS config)
# calls SafeArray*, Variant{Clear,Copy} and the VariantTo* family through COM.
# -lgcc_eh stays last: the MinGW link is single pass.
IROH_WIN_SYSLIBS="-lws2_32 -lbcrypt -lntdll -luserenv -ladvapi32 -liphlpapi -lsecur32 -lcrypt32 -loleaut32 -lpropsys -lole32 -lgcc_eh"
# Resolved by iroh_probe; empty means "no iroh in this build".
IROH_HOST_LIBDIR=""
IROH_WIN_LIBDIR=""

# Decide once whether this build has iroh, and say why when it does not.
iroh_probe() {
  IROH_HOST_LIBDIR=""; IROH_WIN_LIBDIR=""
  [[ "${IROH:-0}" == 1 ]] || return 0
  if [[ ! -f "$IROH_CRATE_DIR/Cargo.toml" ]]; then
    echo "IROH=1 but $IROH_CRATE_DIR/Cargo.toml is missing: building without iroh" >&2
    return 0
  fi
  if ! command -v "${CARGO:-cargo}" >/dev/null; then
    echo "IROH=1 but cargo is not on PATH: building without iroh (tools/build-container.sh update installs it)" >&2
    return 0
  fi
  IROH_HOST_LIBDIR="$ROOT/build/lib"
  [[ "${SKIP_WIN:-0}" == 1 ]] || IROH_WIN_LIBDIR="$ROOT/build/win/lib"
  return 0
}

# Linker flags to splice into a Nelua --cflags string. Both print nothing at all
# when iroh is off, so an unconditional "$(iroh_host_ldflags)" is the no-op it
# looks like.
iroh_host_ldflags() {
  # -lunwind: the shipped rust-std references _Unwind_* even with panic=abort,
  # so the staticlib does not link without an unwinder (libunwind-devel is in
  # BUILD_PKGS for it).
  [[ -n "$IROH_HOST_LIBDIR" ]] && printf ' -L"%s" -lghostty_iroh -lpthread -ldl -lm -lunwind' "$IROH_HOST_LIBDIR"
  return 0
}
iroh_win_ldflags() {
  [[ -n "$IROH_WIN_LIBDIR" ]] && printf ' -L"%s" -lghostty_iroh %s' "$IROH_WIN_LIBDIR" "$IROH_WIN_SYSLIBS"
  return 0
}

# Nelua needs to know whether the symbols are there to link against, not only
# where to find them: code that declares gi_* unconditionally fails at link
# when the crate is off. Guard it with `## if IROH then` and splice this in.
# Prints nothing when iroh is off, so an unconditional use is a no-op.
iroh_nelua_host_define() {
  [[ -n "$IROH_HOST_LIBDIR" ]] && printf ' -DIROH'
  return 0
}
iroh_nelua_win_define() {
  [[ -n "$IROH_WIN_LIBDIR" ]] && printf ' -DIROH'
  return 0
}

# Build the staticlib for whichever targets iroh_probe enabled. Offline and
# --locked: the dependency tree comes from vendor/cargo (tools/fetch-vendor.sh),
# so this step never reaches crates.io, like every other dependency here.
build_iroh() {
  [[ -n "$IROH_HOST_LIBDIR" || -n "$IROH_WIN_LIBDIR" ]] || return 0
  local cargo="${CARGO:-cargo}"
  local flags=(--locked --release --manifest-path "$IROH_CRATE_DIR/Cargo.toml")
  # A fixed absolute target dir: it is part of every sccache key, so the build
  # container sets CARGO_TARGET_DIR in its profile and this keeps it.
  export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/build/cargo}"
  if [[ -f "$ROOT/vendor/cargo/config.toml" ]]; then
    export CARGO_HOME="$ROOT/vendor/cargo"
    flags+=(--offline)
  else
    echo "warning: vendor/cargo is missing (tools/fetch-vendor.sh); cargo will resolve online" >&2
  fi
  mkdir -p "$CARGO_TARGET_DIR"
  if [[ -n "$IROH_HOST_LIBDIR" ]]; then
    echo '== ghostty-iroh (host)'
    "$cargo" build "${flags[@]}"
    mkdir -p "$IROH_HOST_LIBDIR"
    cp "$CARGO_TARGET_DIR/release/libghostty_iroh.a" "$IROH_HOST_LIBDIR/"
  fi
  if [[ -n "$IROH_WIN_LIBDIR" ]]; then
    echo "== ghostty-iroh ($IROH_WIN_TARGET)"
    # zig-cc-win.sh cannot serve as rustc's linker here: rustc's own link line
    # carries mingw-isms zig does not resolve (-lwindows.0.52.0, -lgcc_eh,
    # -l:libpthread.a), and the cross build died in iroh-relay on them. Use
    # mingw-w64's gcc, which is what the crate was proved to cross-compile
    # with. It only links cargo's own intermediate artifacts; the staticlib is
    # an archive of rustc-compiled objects, and tools/zig-cc-win.sh still does
    # the link that matters, into the PE core.
    CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER="${MINGW_CC:-x86_64-w64-mingw32-gcc}" \
      "$cargo" build "${flags[@]}" --target "$IROH_WIN_TARGET"
    mkdir -p "$IROH_WIN_LIBDIR"
    cp "$CARGO_TARGET_DIR/$IROH_WIN_TARGET/release/libghostty_iroh.a" "$IROH_WIN_LIBDIR/"
  fi
}
