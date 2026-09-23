#!/usr/bin/env bash
# Sourced by tools/fetch-vendor.sh and tools/build-moq-iroh.sh: `ensure_rust`
# puts the Rust toolchain pinned in toolchain.env (RUST_VERSION, RUST_*_SHA256)
# on PATH, for moq-iroh-c, the one Rust library the agent links (netlab,
# docs/NETLAB.md).
#
# In this order:
#   RUST_SYSTEM=1      whatever cargo/rustc is on PATH, as long as it is at least
#                      RUST_MIN_VERSION. This is the RPM path: mock and COPR build
#                      with Fedora's rust and cargo, offline, from the vendored
#                      crates, and a distribution does not take a toolchain from us.
#   cargo on PATH      when `rustc --version` is exactly RUST_VERSION and it has
#                      every target asked for (rustup, a runner's own install).
#   the pinned dist    rustc, cargo and rust-std components from
#                      static.rust-lang.org, each checked against its sha256 and
#                      installed under $RUST_HOME (default
#                      ${CI_CACHE_DIR:-~/.cache/ghostty-dalamud-ci}/rust-$RUST_VERSION).
#                      No rustup, no curl | sh.
#
#   ensure_rust [x86_64-pc-windows-gnu]   a target's rust-std beside the host's
#
# Exit (from the caller's shell) with a message when none of these works.
# shellcheck disable=SC2034 # RUST_BIN is used by the scripts that source this

rust_log() { printf '== rust: %s\n' "$*"; }
rust_die() { printf 'rust: error: %s\n' "$*" >&2; exit 1; }

# version_ge A B: A >= B for dotted versions
rust_version_ge() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]; }

rust_has_target() { # rustc target
  local sysroot
  sysroot="$("$1" --print sysroot 2>/dev/null)" || return 1
  [[ -d "$sysroot/lib/rustlib/$2/lib" ]]
}

rust_fetch_component() { # name target sha256 prefix
  local file="$1-$RUST_VERSION-$2.tar.xz" tmp
  tmp="$(mktemp -d)"
  curl -fsSL --retry 3 --retry-delay 5 -o "$tmp/$file" "$RUST_DIST_URL/$file" ||
    { rm -rf "$tmp"; rust_die "could not download $RUST_DIST_URL/$file"; }
  if ! echo "$3  $tmp/$file" | sha256sum -c --status -; then
    rm -rf "$tmp"
    rust_die "checksum mismatch for $file (expected $3); update toolchain.env if upstream changed on purpose"
  fi
  tar -xJf "$tmp/$file" -C "$tmp"
  "$tmp/$1-$RUST_VERSION-$2/install.sh" --prefix="$4" --disable-ldconfig >/dev/null
  rm -rf "$tmp"
}

ensure_rust() {
  local want=("$@") t
  if [[ "${RUST_SYSTEM:-0}" == 1 ]]; then
    if ! command -v cargo >/dev/null || ! command -v rustc >/dev/null; then
      rust_die 'RUST_SYSTEM=1 but there is no cargo and rustc on PATH'
    fi
    local have
    have="$(rustc --version | awk '{print $2}')"
    rust_version_ge "$have" "$RUST_MIN_VERSION" ||
      rust_die "rustc $have is older than moq-iroh-c's floor $RUST_MIN_VERSION"
    for t in "${want[@]}"; do
      rust_has_target rustc "$t" || rust_die "the system rustc has no $t standard library"
    done
    RUST_BIN="$(dirname "$(command -v cargo)")"
    rust_log "system rustc $have ($RUST_BIN)"
    return 0
  fi
  if command -v rustc >/dev/null && [[ "$(rustc --version | awk '{print $2}')" == "$RUST_VERSION" ]]; then
    local ok=1
    for t in "${want[@]}"; do rust_has_target rustc "$t" || ok=0; done
    if [[ "$ok" == 1 ]]; then
      RUST_BIN="$(dirname "$(command -v cargo)")"
      rust_log "rustc $RUST_VERSION on PATH ($RUST_BIN)"
      return 0
    fi
  fi
  [[ "$(uname -s)-$(uname -m)" == Linux-x86_64 ]] ||
    rust_die "no pinned Rust for $(uname -s)-$(uname -m); put rustc $RUST_VERSION on PATH"
  local home="${RUST_HOME:-${CI_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ghostty-dalamud-ci}/rust-$RUST_VERSION}"
  local host=x86_64-unknown-linux-gnu
  if [[ ! -x "$home/bin/rustc" ]]; then
    rust_log "installing the pinned Rust $RUST_VERSION into $home"
    rust_fetch_component rustc "$host" "$RUST_SHA256_RUSTC_X86_64_LINUX" "$home"
    rust_fetch_component cargo "$host" "$RUST_SHA256_CARGO_X86_64_LINUX" "$home"
    rust_fetch_component rust-std "$host" "$RUST_SHA256_STD_X86_64_LINUX" "$home"
  fi
  for t in "${want[@]}"; do
    rust_has_target "$home/bin/rustc" "$t" && continue
    case "$t" in
      x86_64-pc-windows-gnu) rust_fetch_component rust-std "$t" "$RUST_SHA256_STD_X86_64_WINDOWS_GNU" "$home" ;;
      *) rust_die "no pinned rust-std for $t in toolchain.env" ;;
    esac
  done
  RUST_BIN="$home/bin"
  export PATH="$RUST_BIN:$PATH"
  rust_log "rustc $("$RUST_BIN/rustc" --version | awk '{print $2}') ($RUST_BIN)"
}
