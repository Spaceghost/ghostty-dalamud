#!/usr/bin/env bash
# The Incus build container: where every heavy build of this project runs.
#
#   tools/build-container.sh <command>
#
#   create      create the container from the pinned image, then `update`
#   update      install/refresh the toolchain; idempotent, safe to repeat
#   status      what the container has, and the cache statistics
#   shell       an interactive shell in it (`... shell -- <cmd>` runs one command)
#   publish     stop it and make an image, so it can be `incus copy`d to another host
#   delete      delete the container (the cache volume survives; --cache deletes it too)
#   cache-export FILE   tar the shared cache volume to FILE on this machine
#   cache-import FILE   unpack such a tar into the shared cache volume
#   cache-stats         sccache statistics
#   cache-reset         empty the shared cache
#
# The container is a plain Fedora 44 container pinned in toolchain.env
# (BUILD_IMAGE): the same `create` on any Incus host gives the same toolchain,
# and `publish` turns it into an image that `incus copy`/`incus move` can carry
# between hosts. tools/build-remote.sh drives it; nothing here touches the
# gaming PC's system.
#
# Environment:
#   INCUS_REMOTE   Incus remote to work on. Default: the remote named by
#                  BUILD_REMOTE_NAME when `incus remote list` has it, else `local`.
#   INCUS          the incus binary (default: incus on PATH)
#   BUILD_CONTAINER_NAME  another container name on the same remote; it shares
#                  the cache volume, which is how a second build location is added
#   BUILD_CONTAINER, BUILD_CACHE_VOLUME, BUILD_IMAGE, ...   toolchain.env
#   BUILD_CACHE_ENV   a file of SCCACHE_* settings sourced into the container's
#                     environment, for a shared object-store backend. Default
#                     ~/.config/ghostty-dalamud/build-cache.env. Never in git.
#
# See docs/BUILDING.md.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/toolchain.env"

INCUS="${INCUS:-incus}"
# A second build container on the same host shares the cache volume; this is
# how a new Incus location is added (docs/BUILDING.md).
BUILD_CONTAINER="${BUILD_CONTAINER_NAME:-$BUILD_CONTAINER}"
log() { printf '== container: %s\n' "$*"; }
warn() { printf 'container: warning: %s\n' "$*" >&2; }
die() { printf 'container: error: %s\n' "$*" >&2; exit 1; }

command -v "$INCUS" >/dev/null || die "incus is required (set INCUS=/path/to/incus)"

# The Incus remote is named per machine: BUILD_REMOTE_NAME from the
# environment, from an untracked build.env, or toolchain.env's placeholder.
[[ -f "$ROOT/build.env" ]] && source "$ROOT/build.env"
BUILD_REMOTE_NAME="${BUILD_REMOTE_NAME:-build}"

# The remote: an explicit INCUS_REMOTE, else the named build remote when this
# machine has one, else the local daemon.
if [[ -z "${INCUS_REMOTE:-}" ]]; then
  if "$INCUS" remote list --format csv 2>/dev/null | cut -d, -f1 | grep -qx "$BUILD_REMOTE_NAME"; then
    INCUS_REMOTE="$BUILD_REMOTE_NAME"
  else
    INCUS_REMOTE=local
    warn "no '$BUILD_REMOTE_NAME' Incus remote on this machine; using the local daemon.
  Add one with:  incus remote add <name> https://<build-host>:8443
  then put BUILD_REMOTE_NAME=<name> in build.env.
  Without a remote the fallback is incus over ssh: INCUS='ssh <build-host> incus'"
  fi
fi
C="$INCUS_REMOTE:$BUILD_CONTAINER"
POOL="${BUILD_POOL:-default}"
CACHE_ENV_FILE="${BUILD_CACHE_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/ghostty-dalamud/build-cache.env}"

ic() { "$INCUS" "$@"; }
inside() { "$INCUS" exec "$C" --env HOME=/root -- "$@"; }
# a login-ish shell with the build environment; stdin is passed through
insh() { "$INCUS" exec "$C" --env HOME=/root -- bash -lc "$1"; }

exists() { ic info "$C" >/dev/null 2>&1; }

ensure_cache_volume() {
  local v="$INCUS_REMOTE:$BUILD_CACHE_VOLUME"
  if ! ic storage volume show "$INCUS_REMOTE:$POOL" "$BUILD_CACHE_VOLUME" >/dev/null 2>&1; then
    log "creating the shared cache volume $POOL/$BUILD_CACHE_VOLUME on $INCUS_REMOTE"
    ic storage volume create "$INCUS_REMOTE:$POOL" "$BUILD_CACHE_VOLUME" >/dev/null
  fi
  # several build containers on this host share the volume, so it needs a
  # shifted idmap
  ic storage volume set "$INCUS_REMOTE:$POOL" "$BUILD_CACHE_VOLUME" security.shifted=true 2>/dev/null || true
  : "$v"
}

attach_cache() {
  if ! ic config device get "$C" cache source >/dev/null 2>&1; then
    log "attaching $BUILD_CACHE_VOLUME at $BUILD_CONTAINER_CACHE"
    ic config device add "$C" cache disk \
      pool="$POOL" source="$BUILD_CACHE_VOLUME" path="$BUILD_CONTAINER_CACHE" >/dev/null
  fi
}

cmd_create() {
  if exists; then
    log "$C already exists"
  else
    ensure_cache_volume
    local img="$BUILD_IMAGE_REMOTE:$BUILD_IMAGE"
    log "launching $C from $img ($BUILD_IMAGE_DESC)"
    if ! ic launch "$img" "$C" \
        -c "limits.cpu=$BUILD_CONTAINER_CPU" -c "limits.memory=$BUILD_CONTAINER_MEMORY" \
        -c "security.nesting=true" 2>/dev/null; then
      warn "the pinned image $BUILD_IMAGE is gone from $BUILD_IMAGE_REMOTE; falling back to $BUILD_IMAGE_ALIAS.
  Put the new fingerprint (incus image info $BUILD_IMAGE_REMOTE:$BUILD_IMAGE_ALIAS) into toolchain.env."
      ic launch "$BUILD_IMAGE_REMOTE:$BUILD_IMAGE_ALIAS" "$C" \
        -c "limits.cpu=$BUILD_CONTAINER_CPU" -c "limits.memory=$BUILD_CONTAINER_MEMORY" \
        -c "security.nesting=true"
    fi
    ic config device add "$C" cache disk \
      pool="$POOL" source="$BUILD_CACHE_VOLUME" path="$BUILD_CONTAINER_CACHE" >/dev/null
    wait_ready
  fi
  cmd_update
}

wait_ready() {
  log "waiting for the container network"
  for _ in $(seq 60); do
    if inside sh -c 'getent hosts kojipkgs.fedoraproject.org >/dev/null 2>&1 || getent hosts mirrors.fedoraproject.org >/dev/null 2>&1'; then return 0; fi
    sleep 1
  done
  die "the container has no working DNS after 60s"
}

start_if_stopped() {
  exists || die "$C does not exist; run: tools/build-container.sh create"
  if [[ "$(ic info "$C" | awk '/^Status:/{print tolower($2)}')" != running ]]; then
    log "starting $C"
    ic start "$C"
    wait_ready
  fi
}

# Install a pinned package; if Fedora has retired that exact build, install the
# bare name and warn, so a fresh create never dead-ends.
install_pinned() {
  local missing=() nevr name
  # RUST_PKGS_PINNED is optional (docs/IROH.md): empty in a toolchain.env that
  # does not pin Rust, and the loop then behaves exactly as it did.
  for nevr in $BUILD_PKGS_PINNED ${RUST_PKGS_PINNED:-}; do
    name="${nevr%%-[0-9]*}"
    if inside rpm -q --quiet "$nevr" 2>/dev/null; then continue; fi
    missing+=("$nevr")
    : "$name"
  done
  [[ ${#missing[@]} -eq 0 ]] && { log "pinned packages already installed"; return 0; }
  log "installing pinned packages: ${missing[*]}"
  if ! insh "dnf -y install ${missing[*]}"; then
    local names=()
    for nevr in "${missing[@]}"; do names+=("${nevr%%-[0-9]*}"); done
    warn "a pinned package build is no longer in Fedora's repositories; installing ${names[*]} unpinned.
  Refresh BUILD_PKGS_PINNED in toolchain.env from what lands (rpm -q ${names[*]})."
    insh "dnf -y install ${names[*]}"
  fi
}

cmd_update() {
  start_if_stopped
  attach_cache
  log "dnf update metadata and build tools"
  insh "dnf -y install $BUILD_PKGS >/dev/null"
  install_pinned

  # Zig: the pinned version if Fedora has it at a stable path, else the pinned
  # release tarball under /opt/zig (also a stable path, so cache keys match).
  local zv
  zv="$(insh 'command -v zig >/dev/null && zig version || true' | tr -d '\r')"
  if [[ "$zv" != "$ZIG_VERSION" ]]; then
    log "the remote's zig is '${zv:-none}', toolchain.env pins $ZIG_VERSION: fetching the pinned release"
    insh "set -e
      d=/opt/zig-$ZIG_VERSION
      if [[ ! -x \$d/zig ]]; then
        t=\$(mktemp -d)
        curl -fsSL --retry 3 -o \$t/zig.tar.xz '$ZIG_URL_BASE/$ZIG_VERSION/zig-x86_64-linux-$ZIG_VERSION.tar.xz'
        echo '$ZIG_SHA256_X86_64_LINUX  '\$t/zig.tar.xz | sha256sum -c --status -
        mkdir -p \$d && tar -xJf \$t/zig.tar.xz -C \$d --strip-components=1
        rm -rf \$t
      fi
      ln -sfn \$d/zig /usr/local/bin/zig"
  fi

  # The shared cache layout. Every directory that a rebuild can reuse lives on
  # the Incus volume, so a second container on this host starts warm.
  log "shared cache layout under $BUILD_CONTAINER_CACHE"
  inside mkdir -p \
    "$BUILD_CONTAINER_CACHE/sccache" "$BUILD_CONTAINER_CACHE/zig-global" \
    "$BUILD_CONTAINER_CACHE/zig-cache-linux" "$BUILD_CONTAINER_CACHE/zig-cache-win" \
    "$BUILD_CONTAINER_CACHE/nelua-cache" "$BUILD_CONTAINER_CACHE/win-cache" \
    "$BUILD_CONTAINER_CACHE/win-cache-agent" "$BUILD_CONTAINER_CACHE/ghostty-vt-linux" \
    "$BUILD_CONTAINER_CACHE/ghostty-vt-windows" "$BUILD_CONTAINER_CACHE/lua-linux" \
    "$BUILD_CONTAINER_CACHE/lua-win" "$BUILD_CONTAINER_CACHE/nuget" \
    "$BUILD_CONTAINER_CACHE/ci" "$BUILD_CONTAINER_CACHE/vendor" \
    "$BUILD_CONTAINER_CACHE/cargo-target" \
    "$BUILD_CONTAINER_DIR"

  write_profile
  log "ready:"
  cmd_status
}

# /etc/profile.d/ghostty-build.sh: the one place the build environment is
# defined, so `incus exec ... bash -lc` and an interactive shell agree.
write_profile() {
  local extra=""
  if [[ -f "$CACHE_ENV_FILE" ]]; then
    log "cache backend settings from $CACHE_ENV_FILE"
    extra="$(grep -E '^[A-Z_]+=' "$CACHE_ENV_FILE" | sed 's/^/export /')"
  fi
  # shellcheck disable=SC2016
  ic file push - "$C/etc/profile.d/ghostty-build.sh" --mode 0644 <<EOF
# written by tools/build-container.sh; do not edit in the container
export ROOTDIR=$BUILD_CONTAINER_DIR
export CACHE=$BUILD_CONTAINER_CACHE
export ZIG_GLOBAL_CACHE_DIR=\$CACHE/zig-global
export NUGET_PACKAGES=\$CACHE/nuget
export CI_CACHE_DIR=\$CACHE/ci
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
# sccache: local disk cache on the shared Incus volume by default; a
# SCCACHE_BUCKET/SCCACHE_WEBDAV_ENDPOINT in BUILD_CACHE_ENV overrides it.
# cargo (crates/ghostty-iroh, docs/IROH.md): a fixed absolute target dir on the
# shared volume, for the same reason everything else has one -- absolute paths
# are part of every sccache key. RUSTC_WRAPPER only matters once the crate
# exists; it is harmless before then.
export CARGO_TARGET_DIR=\$CACHE/cargo-target
export RUSTC_WRAPPER=sccache
export CARGO_NET_OFFLINE=true
export SCCACHE_DIR=\$CACHE/sccache
export SCCACHE_CACHE_SIZE=\${SCCACHE_CACHE_SIZE:-20G}
export SCCACHE_IDLE_TIMEOUT=0
# tests/run.sh runs a real wlroots compositor; wayland-server needs a runtime dir
export XDG_RUNTIME_DIR=/run/user/0
[ -d "\$XDG_RUNTIME_DIR" ] || { mkdir -p "\$XDG_RUNTIME_DIR" && chmod 700 "\$XDG_RUNTIME_DIR"; }
$extra
PATH=/usr/local/bin:\$PATH
EOF
}

cmd_status() {
  start_if_stopped
  # shellcheck disable=SC2016 # expanded inside the container
  insh 'echo "image:    $(cat /etc/fedora-release)"
    echo "zig:      $(zig version 2>/dev/null || echo MISSING) ($(command -v zig))"
    echo "dotnet:   $(dotnet --version 2>/dev/null || echo MISSING) sdk=$(dotnet --list-sdks 2>/dev/null | tr "\n" " ")"
    echo "gcc:      $(gcc -dumpfullversion 2>/dev/null || echo MISSING)"
    echo "sccache:  $(sccache --version 2>/dev/null || echo MISSING)"
    echo "cargo:    $(cargo --version 2>/dev/null || echo MISSING) rustc=$(rustc --version 2>/dev/null || echo MISSING)"
    echo "rust-std: $(rpm -q rust-std-static-x86_64-pc-windows-gnu 2>/dev/null || echo MISSING)"
    echo "wayland:  $(rpm -q wlroots libwayland-server libxkbcommon pixman 2>&1 | tr "\n" " ")"
    echo "libwlroots-0.20.so: $(ls -l /usr/lib64/libwlroots-0.20.so 2>&1 | head -1)"
    echo "cache:    $(du -sh $CACHE 2>/dev/null | cut -f1) at $CACHE"
    echo "vendor:   $(ls $CACHE/vendor 2>/dev/null | tr "\n" " ")"
    echo "dalamud:  $(ls /build/dalamud-dev/*.dll 2>/dev/null | wc -l) reference assemblies"'
}

cmd_shell() {
  start_if_stopped
  if [[ $# -gt 0 ]]; then
    ic exec "$C" --env HOME=/root -- bash -lc "cd $BUILD_CONTAINER_DIR 2>/dev/null; $*"
  else
    ic exec "$C" --env HOME=/root -- bash -l
  fi
}

cmd_publish() {
  exists || die "$C does not exist"
  local alias="${1:-$BUILD_CONTAINER}"
  log "stopping $C to publish it"
  ic stop "$C" 2>/dev/null || true
  # the cache volume is not part of the image: it is shared state, not toolchain
  log "publishing image '$alias' on $INCUS_REMOTE"
  # the target remote must be named, or incus publishes to the local daemon
  ic publish "$C" "$INCUS_REMOTE:" --alias "$alias" --reuse --public=false 2>&1 | tail -2
  ic start "$C" >/dev/null 2>&1 || true
  cat <<EOF

The image '$alias' now exists on the '$INCUS_REMOTE' remote. To carry the
toolchain to another Incus host, or back to this machine:

  incus image copy $INCUS_REMOTE:$alias local: --alias $alias
  incus launch $alias ghostty-build            # a ready container from it

To move or copy the container itself (its cache volume does not follow; use
cache-export/cache-import for that):

  incus copy $INCUS_REMOTE:$BUILD_CONTAINER local:$BUILD_CONTAINER
  incus move $INCUS_REMOTE:$BUILD_CONTAINER other:$BUILD_CONTAINER
EOF
}

cmd_delete() {
  exists && { log "deleting $C"; ic delete -f "$C"; }
  if [[ "${1:-}" == --cache ]]; then
    log "deleting the cache volume $POOL/$BUILD_CACHE_VOLUME"
    ic storage volume delete "$INCUS_REMOTE:$POOL" "$BUILD_CACHE_VOLUME" || true
  fi
}

cmd_cache_export() {
  local f="${1:?usage: cache-export FILE.tar.zst}"
  start_if_stopped
  log "tarring $BUILD_CONTAINER_CACHE out of $C into $f"
  insh "cd $BUILD_CONTAINER_CACHE && tar --zstd -cf - ." >"$f"
  ls -la "$f"
  cat <<EOF

Prime another host's build container from it:

  INCUS_REMOTE=<other> tools/build-container.sh create
  INCUS_REMOTE=<other> tools/build-container.sh cache-import $f
EOF
}

cmd_cache_import() {
  local f="${1:?usage: cache-import FILE.tar.zst}"
  [[ -f "$f" ]] || die "no such file: $f"
  start_if_stopped
  log "unpacking $f into $BUILD_CONTAINER_CACHE of $C"
  insh "cd $BUILD_CONTAINER_CACHE && tar --zstd -xf - --keep-newer-files" <"$f" || true
  cmd_cache_stats
}

cmd_cache_stats() {
  start_if_stopped
  # shellcheck disable=SC2016 # expanded inside the container
  insh 'sccache --show-stats 2>&1 | head -25; echo; du -sh $CACHE/* 2>/dev/null'
}

cmd_cache_reset() {
  start_if_stopped
  log "emptying the shared cache"
  # shellcheck disable=SC2016 # expanded inside the container
  insh 'sccache --stop-server >/dev/null 2>&1 || true
    rm -rf $CACHE/sccache/* $CACHE/zig-global/* $CACHE/zig-cache-linux/* $CACHE/zig-cache-win/* \
           $CACHE/nelua-cache/* $CACHE/win-cache/* $CACHE/win-cache-agent/* \
           $CACHE/ghostty-vt-linux/* $CACHE/ghostty-vt-windows/* $CACHE/lua-linux/* $CACHE/lua-win/*'
}

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  create) shift; cmd_create "$@" ;;
  update) shift; cmd_update "$@" ;;
  status) shift; cmd_status "$@" ;;
  shell) shift; [[ "${1:-}" == -- ]] && shift; cmd_shell "$@" ;;
  publish) shift; cmd_publish "$@" ;;
  delete) shift; cmd_delete "$@" ;;
  cache-export) shift; cmd_cache_export "$@" ;;
  cache-import) shift; cmd_cache_import "$@" ;;
  cache-stats) shift; cmd_cache_stats "$@" ;;
  cache-reset) shift; cmd_cache_reset "$@" ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
