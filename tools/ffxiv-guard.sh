#!/usr/bin/env bash
# Get heavy work off this machine the moment the game starts.
#
#   tools/ffxiv-guard.sh run         the watch loop (what the user unit runs)
#   tools/ffxiv-guard.sh once        one pass, then exit (for testing)
#   tools/ffxiv-guard.sh status      game state, guard state, local jobs
#   tools/ffxiv-guard.sh install     install and start the systemd --user unit
#   tools/ffxiv-guard.sh uninstall   stop and remove it
#
# The loop polls for the game (tools/where-build.sh's pattern) every
# GUARD_INTERVAL seconds. On the edge where it appears, every local build job
# tools/run-placed.sh has recorded is evicted: a marker file, then SIGTERM to
# that job's process group, then SIGKILL after GUARD_KILL_GRACE. The job's own
# wrapper sees the marker and re-dispatches the work to the build host; if the
# wrapper itself is gone, the guard runs `run-placed.sh resume` for it.
#
# Polling — not inotify, not a systemd path unit — because what matters is a
# process appearing, and a `pgrep` of four patterns once a second costs
# nothing. The game never waits for the eviction: signalling is the first
# thing the pass does, and the re-dispatch happens afterwards, in the wrapper.
#
# What it will not touch:
#   * anything that is not a running local job of tools/run-placed.sh
#   * jobs marked --local-only (installing into the game, ghostty-agent, git)
#   * any process group that contains a process matching the game pattern
#   * its own process group, and pgid 0 or 1
#
# Environment:
#   GUARD_INTERVAL       seconds between polls (default 1)
#   GUARD_KILL_GRACE     seconds between SIGTERM and SIGKILL (default 5)
#   BUILD_GAME_PATTERN   as in tools/where-build.sh
#   BUILD_PLACEMENT_STATE  job and log directory
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${BUILD_PLACEMENT_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/ghostty-build}"
JOBS="$STATE/jobs"
GUARD_LOG="$STATE/guard.log"
GUARD_INTERVAL="${GUARD_INTERVAL:-1}"
GUARD_KILL_GRACE="${GUARD_KILL_GRACE:-5}"
RUN_PLACED="$HERE/run-placed.sh"
UNIT_NAME="ghostty-build-guard.service"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

WHERE_BUILD_LIB=1
# shellcheck source=tools/where-build.sh
source "$HERE/where-build.sh"

mkdir -p "$JOBS"
glog() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')" "$*" | tee -a "$GUARD_LOG" >&2; }
meta_get() { sed -n "s/^$2=//p" "$1/meta" 2>/dev/null | tail -1; }

# A process group is safe to signal only when it is a job's own group and
# nothing in it looks like the game.
group_is_safe() { # group_is_safe PGID
  local pgid="$1" members
  [[ "$pgid" =~ ^[0-9]+$ ]] || return 1
  [[ "$pgid" -gt 1 ]] || return 1
  if [[ "$pgid" == "$(ps -o pgid= -p $$ | tr -d ' ')" ]]; then return 1; fi
  members="$(pgrep -g "$pgid" -a 2>/dev/null || true)"
  [[ -n "$members" ]] || return 1
  if grep -Eq -- "$BUILD_GAME_PATTERN" <<<"$members"; then
    glog "refusing to signal pgid $pgid: it contains a game process"
    return 1
  fi
  return 0
}

evict_all() { # evict_all REASON
  local reason="$1" d id pgid wrapper n=0
  for d in "$JOBS"/*/; do
    [[ -f "$d/meta" ]] || continue
    [[ "$(meta_get "$d" state)" == running ]] || continue
    [[ "$(meta_get "$d" host)" == local ]] || continue
    if [[ "$(meta_get "$d" local_only)" == 1 ]]; then
      glog "leaving $(basename "$d") alone: --local-only"
      continue
    fi
    id="$(basename "$d")"
    pgid="$(cat "$d/pgid" 2>/dev/null || true)"
    if [[ -z "$pgid" ]] || ! group_is_safe "$pgid"; then
      glog "$id: no safe process group to stop (pgid='${pgid:-}')"
      continue
    fi
    # The marker first: the wrapper must be able to tell an eviction from a
    # build that failed on its own.
    printf '%s' "$reason" >"$d/evict"
    kill -TERM "-$pgid" 2>/dev/null || true
    glog "$id: SIGTERM to process group $pgid ($reason)"
    n=$((n + 1))
    # Escalation happens off the hot path so the game is never held up.
    ( sleep "$GUARD_KILL_GRACE"
      if kill -0 "-$pgid" 2>/dev/null; then
        kill -KILL "-$pgid" 2>/dev/null || true
        glog "$id: SIGKILL to process group $pgid after ${GUARD_KILL_GRACE}s"
      fi ) >/dev/null 2>&1 &
    # Normally the wrapper re-dispatches. If it is gone (its terminal died,
    # someone killed it), the guard does it, detached.
    wrapper="$(meta_get "$d" wrapper_pid)"
    if [[ -z "$wrapper" ]] || ! kill -0 "$wrapper" 2>/dev/null; then
      glog "$id: wrapper $wrapper is gone; resuming on the build host from here"
      setsid "$RUN_PLACED" resume "$id" >/dev/null 2>&1 &
    fi
  done
  glog "eviction pass done: $n job(s) signalled"
}

pass() { # one poll; returns 0 when the game is up
  if wb_game_running; then
    if [[ ! -f "$STATE/game-up" ]]; then
      printf '%s\n' "$WB_GAME_MATCH" >"$STATE/game-up"
      glog "game detected: $WB_GAME_MATCH"
      evict_all "game launch"
    fi
    return 0
  fi
  if [[ -f "$STATE/game-up" ]]; then
    rm -f "$STATE/game-up"
    glog "game gone; local builds are allowed again"
  fi
  return 1
}

cmd_run() {
  glog "guard started (interval ${GUARD_INTERVAL}s, grace ${GUARD_KILL_GRACE}s, state $STATE)"
  trap 'glog "guard stopping"; exit 0' TERM INT
  while :; do
    pass || true
    sleep "$GUARD_INTERVAL"
  done
}

cmd_status() {
  if wb_game_running; then echo "game: RUNNING — $WB_GAME_MATCH"; else echo "game: not running"; fi
  echo "guard: $(systemctl --user is-active "$UNIT_NAME" 2>/dev/null || echo 'not installed')"
  echo "state: $STATE"
  echo
  "$RUN_PLACED" jobs 10
  echo
  echo "last guard log lines:"
  tail -5 "$GUARD_LOG" 2>/dev/null || echo "  (none)"
}

cmd_install() {
  mkdir -p "$UNIT_DIR" "$HOME/.local/bin"
  cat >"$UNIT_DIR/$UNIT_NAME" <<EOF
[Unit]
Description=Move heavy builds off this machine when FFXIV starts
Documentation=file://$HERE/../docs/BUILD_PLACEMENT.md

[Service]
Type=simple
ExecStart=$HERE/ffxiv-guard.sh run
Restart=always
RestartSec=2
# The guard must never be what makes the machine slow.
Nice=10
CPUWeight=20
IOWeight=20
MemoryMax=64M

[Install]
WantedBy=default.target
EOF
  # The same decision and the same job wrapper for every project on this
  # machine, not a copy per repository.
  ln -sfn "$HERE/where-build.sh" "$HOME/.local/bin/build-where"
  ln -sfn "$HERE/run-placed.sh" "$HOME/.local/bin/build-place"
  systemctl --user daemon-reload
  systemctl --user enable --now "$UNIT_NAME"
  echo "installed $UNIT_DIR/$UNIT_NAME"
  echo "installed ~/.local/bin/build-where and ~/.local/bin/build-place"
  systemctl --user --no-pager status "$UNIT_NAME" | head -5
}

cmd_uninstall() {
  systemctl --user disable --now "$UNIT_NAME" 2>/dev/null || true
  rm -f "$UNIT_DIR/$UNIT_NAME"
  systemctl --user daemon-reload
  echo "removed $UNIT_NAME (the ~/.local/bin symlinks were left in place)"
}

case "${1:-status}" in
  run) cmd_run ;;
  once) pass || true ;;
  status) cmd_status ;;
  install) cmd_install ;;
  uninstall) cmd_uninstall ;;
  -h | --help) sed -n '2,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *) echo "ffxiv-guard: unknown command: $1 (try --help)" >&2; exit 2 ;;
esac
