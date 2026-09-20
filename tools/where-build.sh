#!/usr/bin/env bash
# Decide where heavy work runs: this machine, or the build host.
#
#   tools/where-build.sh           prints `local` or `remote`
#   tools/where-build.sh --why     ... and the reason on stderr
#   tools/where-build.sh --json    one JSON object with every input
#
# The rule, made mechanical:
#
#   heavy work runs on the BUILD HOST unless the game is not running AND this
#   machine has memory to spare. Anything else goes remote.
#
# So the default is remote, and `local` has to be earned. That is deliberate:
# the failure mode of guessing "local" wrong is a stuttering game or an
# OOM-killed build, and the failure mode of guessing "remote" wrong is a build
# that took the network.
#
# Exit status:
#   0  a decision was made (`local` or `remote` on stdout)
#   3  the work must not run here and the build host is not reachable
#   2  usage
#
# Environment:
#   FORCE_BUILD_HOST     local | remote (or the remote's name) — skips the rule
#   BUILD_MIN_AVAIL_MB   MemAvailable needed to build here (default 6144)
#   BUILD_MAX_SWAP_PCT   swap-used percentage above which this machine is
#                        considered under memory pressure (default 80)
#   BUILD_GAME_PATTERN   extended regex matched against process command lines
#   BUILD_REMOTE         Incus remote that hosts the build container
#                        (default: $INCUS_REMOTE, else BUILD_REMOTE_NAME)
#   INCUS                the incus binary (default: incus on PATH)
#   BUILD_REMOTE_PROBE   0 to skip the reachability probe
#
# This file is also a library: `source tools/where-build.sh` (with
# WHERE_BUILD_LIB=1) defines wb_game_running, wb_mem_ok, wb_remote_up and
# wb_decide without running anything.
set -euo pipefail

BUILD_MIN_AVAIL_MB="${BUILD_MIN_AVAIL_MB:-6144}"
BUILD_MAX_SWAP_PCT="${BUILD_MAX_SWAP_PCT:-80}"
[[ -f "$(dirname "${BASH_SOURCE[0]}")/../build.env" ]] && source "$(dirname "${BASH_SOURCE[0]}")/../build.env"  # this machine's remote name
BUILD_REMOTE="${BUILD_REMOTE:-${INCUS_REMOTE:-${BUILD_REMOTE_NAME:-build}}}"
INCUS="${INCUS:-incus}"
# The game, the launcher, and the dedicated login session that starts both.
# Kept as one regex so a site can replace it wholesale from the environment.
BUILD_GAME_PATTERN="${BUILD_GAME_PATTERN:-(^|/)ffxiv_dx11\.exe([[:space:]]|$)|(^|/)ffxivlauncher\.exe([[:space:]]|$)|(^|/)XIVLauncher(\.Core)?([[:space:]]|$)|(^|/)ffxiv-session([[:space:]]|$)}"

# The reason for the last wb_* answer, for logs and --why.
WB_HOST=""
WB_REASON=""
WB_GAME_MATCH=""
WB_MEM_AVAIL_MB=0
WB_SWAP_PCT=0

# Is the game (or its launcher, or its session) running right now?
# Never matches this process or any of its ancestors, so a shell whose command
# line happens to mention the game does not look like the game.
wb_game_running() {
  WB_GAME_MATCH=""
  command -v pgrep >/dev/null || return 1
  local mine=() p=$$
  while [[ "$p" -gt 1 ]]; do
    mine+=("$p")
    p="$(awk '/^PPid:/{print $2}' "/proc/$p/status" 2>/dev/null || echo 1)"
    [[ -n "$p" ]] || break
  done
  local line pid
  while IFS= read -r line; do
    pid="${line%% *}"
    local skip=0 m
    for m in "${mine[@]}"; do [[ "$pid" == "$m" ]] && skip=1; done
    [[ "$skip" == 1 ]] && continue
    WB_GAME_MATCH="$line"
    return 0
  done < <(pgrep -af -- "$BUILD_GAME_PATTERN" 2>/dev/null || true)
  return 1
}

# Enough memory here to compile without fighting the game or the OOM killer?
wb_mem_ok() {
  local avail_kb swap_total swap_free
  avail_kb="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
  swap_total="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)"
  swap_free="$(awk '/^SwapFree:/{print $2}' /proc/meminfo)"
  WB_MEM_AVAIL_MB=$(( avail_kb / 1024 ))
  WB_SWAP_PCT=0
  if [[ "${swap_total:-0}" -gt 0 ]]; then
    WB_SWAP_PCT=$(( (swap_total - swap_free) * 100 / swap_total ))
  fi
  if [[ "$WB_MEM_AVAIL_MB" -lt "$BUILD_MIN_AVAIL_MB" ]]; then
    WB_REASON="only ${WB_MEM_AVAIL_MB} MB available, ${BUILD_MIN_AVAIL_MB} MB needed"
    return 1
  fi
  if [[ "$WB_SWAP_PCT" -gt "$BUILD_MAX_SWAP_PCT" ]]; then
    WB_REASON="swap ${WB_SWAP_PCT}% used, over ${BUILD_MAX_SWAP_PCT}%"
    return 1
  fi
  return 0
}

# Is the build host answering? Cheap (a /1.0 query over the existing TLS
# client certificate), so it is safe on every decision.
wb_remote_up() {
  [[ "${BUILD_REMOTE_PROBE:-1}" == 0 ]] && return 0
  command -v "$INCUS" >/dev/null || return 1
  timeout 5 "$INCUS" query "$BUILD_REMOTE:/1.0" >/dev/null 2>&1
}

# Sets WB_HOST to `local` or `remote` and WB_REASON to why, and prints WB_HOST.
# Exit 3 when the work must not run here and the build host is unreachable.
wb_decide() {
  WB_HOST=""
  case "${FORCE_BUILD_HOST:-}" in
    local) WB_REASON="FORCE_BUILD_HOST=local"; WB_HOST=local; echo local; return 0 ;;
    "") ;;
    *)
      WB_REASON="FORCE_BUILD_HOST=${FORCE_BUILD_HOST}"
      [[ "$FORCE_BUILD_HOST" != remote ]] && BUILD_REMOTE="$FORCE_BUILD_HOST"
      WB_HOST=remote; echo remote; return 0 ;;
  esac

  if wb_game_running; then
    WB_REASON="the game is running (${WB_GAME_MATCH})"
    if wb_remote_up; then WB_HOST=remote; echo remote; return 0; fi
    # Refusing is the whole point: the owner's rule has no branch that lets a
    # compile run next to the game.
    WB_REASON="$WB_REASON and $BUILD_REMOTE is not reachable"
    return 3
  fi

  if ! wb_mem_ok; then
    if wb_remote_up; then WB_HOST=remote; echo remote; return 0; fi
    # No game, just a tight machine: running here is slow, not harmful.
    WB_REASON="$WB_REASON, but $BUILD_REMOTE is not reachable — running here anyway"
    WB_HOST=local; echo local; return 0
  fi

  WB_REASON="the game is not running and ${WB_MEM_AVAIL_MB} MB are available"
  WB_HOST=local
  echo local
}

if [[ -n "${WHERE_BUILD_LIB:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

main() {
  local mode=plain
  case "${1:-}" in
    "") ;;
    --why) mode=why ;;
    --json) mode=json ;;
    -h | --help) sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "where-build: unknown argument: $1" >&2; exit 2 ;;
  esac

  local rc=0
  # --json reports every input, including the ones FORCE_BUILD_HOST skips.
  if [[ "$mode" == json ]]; then
    wb_mem_ok || true
    wb_game_running || true
  fi
  # Not in a subshell: wb_decide's reason has to survive.
  wb_decide >/dev/null || rc=$?
  if [[ "$rc" == 3 ]]; then
    echo "where-build: refusing: $WB_REASON" >&2
    exit 3
  fi

  case "$mode" in
    plain) echo "$WB_HOST" ;;
    why) echo "$WB_HOST"; echo "where-build: $WB_HOST — $WB_REASON" >&2 ;;
    json)
      printf '{"host":"%s","reason":"%s","remote":"%s","game_running":%s,"mem_available_mb":%s,"swap_used_pct":%s,"min_available_mb":%s}\n' \
        "$WB_HOST" "${WB_REASON//\"/\'}" "$BUILD_REMOTE" \
        "$([[ -n "$WB_GAME_MATCH" ]] && echo true || echo false)" \
        "$WB_MEM_AVAIL_MB" "$WB_SWAP_PCT" "$BUILD_MIN_AVAIL_MB" ;;
  esac
}
main "$@"
