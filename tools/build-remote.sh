#!/usr/bin/env bash
# Build this checkout in the Incus build container and bring the artifacts back.
# This is the default way to build: the gaming PC runs the game in the same
# 15 GB of RAM, so a full build there gets killed for low memory.
#
#   tools/build-remote.sh [build]       tools/ci/run.sh build in the container
#                                       (pinned toolchains, vendor/, tools/build.sh),
#                                       then build/dist/ comes back here
#   tools/build-remote.sh test          tools/ci/run.sh test in the container
#                                       (tests/run.sh), output streamed
#   tools/build-remote.sh all           test, then build
#   tools/build-remote.sh push          only send this checkout over
#   tools/build-remote.sh pull          only fetch build/dist/ back
#   tools/build-remote.sh shell [cmd]   a shell in the container, in the checkout
#   tools/build-remote.sh stats         shared-cache statistics
#
# The container is tools/build-container.sh's; this creates it if it is not
# there yet. Two runs at once are safe: the container serializes them on
# /cache/build.lock.
#
# Passed through to tools/build.sh unchanged:
#   SKIP_WIN, SKIP_SHIM, SKIP_UMBRA, SKIP_DEPS, SKIP_WAYLAND, MAC
# Also:
#   INCUS_REMOTE       which Incus host (default: the BUILD_REMOTE_NAME remote)
#   DALAMUD_LIB_PATH   Dalamud reference assemblies to push in, default
#                      ~/.xlcore/dalamud/Hooks/dev. They are game binaries:
#                      they are pushed per build, never into the image or git.
#                      Without them the container falls back to the pinned
#                      dalamud-distrib download (tools/ci/run.sh).
#   NO_DALAMUD_PUSH=1  skip that push and use the pinned download
#
# What stays on this machine: installing into the game (tools/install-dev.sh),
# restarting the agent, and `/term selftest` in the running game. See
# docs/BUILDING.md.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/toolchain.env"
cd "$ROOT"

INCUS="${INCUS:-incus}"
# A second build container on the same host shares the cache volume; this is
# how a new Incus location is added (docs/BUILDING.md).
BUILD_CONTAINER="${BUILD_CONTAINER_NAME:-$BUILD_CONTAINER}"
CONTAINER_SH="$ROOT/tools/build-container.sh"
log() { printf '== remote: %s\n' "$*"; }
die() { printf 'remote: error: %s\n' "$*" >&2; exit 1; }

# The Incus remote is named per machine: BUILD_REMOTE_NAME from the
# environment, from an untracked build.env, or toolchain.env's placeholder.
[[ -f "$ROOT/build.env" ]] && source "$ROOT/build.env"
BUILD_REMOTE_NAME="${BUILD_REMOTE_NAME:-build}"
if [[ -z "${INCUS_REMOTE:-}" ]]; then
  if "$INCUS" remote list --format csv 2>/dev/null | cut -d, -f1 | grep -qx "$BUILD_REMOTE_NAME"; then
    INCUS_REMOTE="$BUILD_REMOTE_NAME"
  else
    INCUS_REMOTE=local
  fi
fi
export INCUS_REMOTE
C="$INCUS_REMOTE:$BUILD_CONTAINER"
D="$BUILD_CONTAINER_DIR"

ensure_container() {
  if ! "$INCUS" info "$C" >/dev/null 2>&1; then
    log "no $C yet: creating it (tools/build-container.sh create)"
    "$CONTAINER_SH" create
  elif [[ "$("$INCUS" info "$C" | awk '/^Status:/{print tolower($2)}')" != running ]]; then
    log "starting $C"
    "$INCUS" start "$C"
    sleep 3
  fi
}

# One place the build environment is assembled, so build, test and shell agree.
remote_env() {
  local e=()
  e+=(--env HOME=/root)
  # The container is the destination: never let a script in there route again.
  e+=(--env BUILD_PLACEMENT=0)
  e+=(--env "ROOT=$D")
  # sccache drives the Nelua C compiles through tools/zig-cc*.sh
  e+=(--env GHOSTTY_SCCACHE=1)
  # a build of the same commit hashes the same, wherever it runs
  local epoch
  epoch="$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || echo 1)"
  e+=(--env "SOURCE_DATE_EPOCH=$epoch")
  local v
  # SAN and its option strings travel too, so the sanitizer suites can run here
  # rather than on the machine the game is on.
  for v in SKIP_WIN SKIP_SHIM SKIP_UMBRA SKIP_DEPS SKIP_WAYLAND MAC BUILD_COMMIT BUILD_ID \
           SAN ASAN_OPTIONS UBSAN_OPTIONS LSAN_OPTIONS; do
    [[ -n "${!v:-}" ]] && e+=(--env "$v=${!v}")
  done
  printf '%s\n' "${e[@]}"
}

run_in() { # run_in <bash -lc script>
  local env_args=()
  mapfile -t env_args < <(remote_env)
  "$INCUS" exec "$C" "${env_args[@]}" -- bash -lc "$1"
}

dalamud_remote_dir=/build/dalamud-dev

push_dalamud() {
  [[ "${NO_DALAMUD_PUSH:-0}" == 1 ]] && { log "NO_DALAMUD_PUSH=1: the container uses the pinned dalamud-distrib"; return 0; }
  [[ "${SKIP_SHIM:-0}" == 1 ]] && return 0
  local dd="${DALAMUD_LIB_PATH:-$HOME/.xlcore/dalamud/Hooks/dev}"
  if [[ ! -f "$dd/Dalamud.dll" ]]; then
    log "no Dalamud.dll in $dd: the container falls back to the pinned dalamud-distrib"
    return 0
  fi
  # Game binaries. Pushed per build, never committed and never baked into the
  # published image. Re-pushed only when the set of files changes.
  local sum
  sum="$(find "$dd" -maxdepth 1 -name '*.dll' -printf '%f %s %T@\n' | sort | sha256sum | cut -c1-16)"
  if [[ "$("$INCUS" exec "$C" -- cat "$dalamud_remote_dir/.stamp" 2>/dev/null || true)" == "$sum" ]]; then
    log "Dalamud reference assemblies already in the container ($sum)"
    return 0
  fi
  log "pushing $(find "$dd" -maxdepth 1 -name '*.dll' | wc -l) Dalamud reference assemblies from $dd"
  "$INCUS" exec "$C" -- rm -rf "$dalamud_remote_dir"
  "$INCUS" exec "$C" -- mkdir -p "$dalamud_remote_dir"
  ( cd "$dd" && find . -maxdepth 1 -name '*.dll' -print0 | tar --null -T - -cf - ) |
    "$INCUS" exec "$C" -- tar -xf - -C "$dalamud_remote_dir"
  "$INCUS" exec "$C" -- sh -c "printf '%s' '$sum' > $dalamud_remote_dir/.stamp"
}

push_source() {
  ensure_container
  log "sending the checkout to $C:$D"
  # Everything git would consider part of this worktree: tracked files plus
  # untracked ones that .gitignore does not exclude. build/ and vendor/ are
  # ignored, so they stay where they are (the container's shared cache volume).
  local list
  list="$(mktemp)"
  git -C "$ROOT" ls-files -z --cached --others --exclude-standard >"$list"
  # clear the old source but keep build/ and the vendor symlink
  "$INCUS" exec "$C" -- bash -c "mkdir -p $D && find $D -mindepth 1 -maxdepth 1 ! -name build ! -name vendor -exec rm -rf {} +"
  tar -C "$ROOT" --null -T "$list" -czf - | "$INCUS" exec "$C" -- tar -xzf - -C "$D"
  rm -f "$list"
  # the shared cache: vendor checkouts and every reusable build directory live
  # on the Incus volume, so a second container on this host starts warm
  "$INCUS" exec "$C" -- bash -c "set -e
    cd $D
    ln -sfn $BUILD_CONTAINER_CACHE/vendor vendor
    mkdir -p build/win build/dist
    for d in zig-cache-linux zig-cache-win nelua-cache ghostty-vt-linux ghostty-vt-windows lua-linux lua-win; do
      ln -sfn $BUILD_CONTAINER_CACHE/\$d build/\$d
    done
    ln -sfn $BUILD_CONTAINER_CACHE/win-cache build/win/cache
    ln -sfn $BUILD_CONTAINER_CACHE/win-cache-agent build/win/cache-agent
    chmod +x tools/*.sh tools/ci/*.sh tests/run.sh 2>/dev/null || true"
  push_dalamud
}

# The build/test body, run under a lock so two runs never share the caches.
remote_run() { # remote_run <label> <script>
  local dd_env=""
  if "$INCUS" exec "$C" -- test -f "$dalamud_remote_dir/Dalamud.dll" 2>/dev/null; then
    dd_env="export DALAMUD_LIB_PATH=$dalamud_remote_dir;"
  fi
  log "$1 in $C"
  run_in "set -e
    cd $D
    $dd_env
    export UMBRA_LIB_PATH=\${UMBRA_LIB_PATH:-$D/vendor/umbra-dist/dist}
    sccache --start-server >/dev/null 2>&1 || true
    flock -o -w \${BUILD_LOCK_WAIT:-7200} $BUILD_CONTAINER_CACHE/build.lock -c '$2'
    echo '--- sccache'
    sccache --show-stats 2>/dev/null | sed -n '1,8p'"
}

pull_dist() {
  log "fetching build/dist back to $ROOT/build/dist"
  mkdir -p "$ROOT/build"
  rm -rf "$ROOT/build/dist.incoming"
  mkdir -p "$ROOT/build/dist.incoming"
  "$INCUS" exec "$C" -- tar -C "$D/build" -cf - dist | tar -xf - -C "$ROOT/build/dist.incoming"
  rm -rf "$ROOT/build/dist.prev"
  if [[ -d "$ROOT/build/dist" ]]; then mv "$ROOT/build/dist" "$ROOT/build/dist.prev"; fi
  mv "$ROOT/build/dist.incoming/dist" "$ROOT/build/dist"
  rmdir "$ROOT/build/dist.incoming"
  rm -rf "$ROOT/build/dist.prev"
  ls -la "$ROOT/build/dist"
}

cmd_build() {
  push_source
  remote_run "tools/ci/run.sh build" "tools/ci/run.sh build"
  pull_dist
  cat <<EOF

Built in the container; nothing on this machine was installed or restarted.
Next, on this machine: tools/install-dev.sh, then /term reload in the game.
EOF
}

cmd_test() {
  push_source
  # ci/run.sh test = the host half of tools/build.sh, then tests/run.sh
  remote_run "tools/ci/run.sh test" "tools/ci/run.sh test"
}

case "${1:-build}" in
  build) cmd_build ;;
  test) cmd_test ;;
  all) cmd_test; cmd_build ;;
  push) push_source ;;
  pull) ensure_container; pull_dist ;;
  shell) shift; ensure_container; "$CONTAINER_SH" shell "$@" ;;
  stats) ensure_container; "$CONTAINER_SH" cache-stats ;;
  -h | --help) sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command: $1 (try --help)" ;;
esac
