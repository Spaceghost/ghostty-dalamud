#!/usr/bin/env bash
# LINUX / WINE ONLY: bring the game up on the machine that runs it, and keep it
# up, so a crash does not need somebody at the keyboard.
#
#   tools/ffxiv-session.sh start       launch it if it is not up; wait until XivMcp answers
#   tools/ffxiv-session.sh status      what is running, and whether XivMcp answers
#   tools/ffxiv-session.sh stop        close the game (SIGTERM to the launcher and the game)
#   tools/ffxiv-session.sh watch       keep it up: relaunch whenever it goes away
#   tools/ffxiv-session.sh install     install and start the systemd --user unit for watch
#   tools/ffxiv-session.sh uninstall   stop and remove it
#
# This does NOT know your password and never will. Logging in is XIVLauncher's
# own saved login: turn on "Auto-login" in XIVLauncher once, by hand, and it
# keeps the credentials in your keyring. `start` checks that the setting is on
# and says what to do when it is not, rather than typing anything into a login
# box. A machine that has to be logged into by hand cannot be brought back by a
# service, which is the whole point of this script.
#
# `start` is done when XivMcp answers on MCP_PORT, not when the process exists:
# the game takes a while to reach the character, and something that only waits
# for a pid reports success long before the game is usable.
#
# It pairs with tools/crash-restart.sh, which answers Dalamud's crash dialog and
# presses Restart. That covers a crash the dialog catches. This covers the rest:
# a hard crash that takes the process down with no dialog (an ImGui stack
# underflow used to do exactly that -- see 68728c9), a machine that rebooted, or
# a game nobody has started yet.
#
# Environment: XL_APP, XLCORE, MCP_HOST, MCP_PORT, START_TIMEOUT, POLL_SECONDS,
# WATCH_BACKOFF.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XL_APP="${XL_APP:-dev.goats.xivlauncher}"
XLCORE="${XLCORE:-$HOME/.xlcore}"
MCP_HOST="${MCP_HOST:-127.0.0.1}"
MCP_PORT="${MCP_PORT:-41800}"
START_TIMEOUT="${START_TIMEOUT:-300}"   # login, patch check and the character screen
POLL_SECONDS="${POLL_SECONDS:-3}"
WATCH_BACKOFF="${WATCH_BACKOFF:-30}"    # after the game goes away, before relaunching
UNIT="ffxiv-session.service"

log() { printf '%s ffxiv-session: %s\n' "$(date '+%F %T')" "$*" >&2; }
die() { log "$*"; exit 1; }

# The game itself, not the launcher: the launcher exits once the game is up.
game_pid() { pgrep -f 'ffxiv_dx11\.exe' 2>/dev/null | head -n1; }
launcher_pid() { pgrep -f 'XIVLauncher\.Core' 2>/dev/null | head -n1; }

mcp_up() {
  # bash's /dev/tcp, so this needs no curl and no token: a refused connection
  # means the plugin is not listening, which is what we are asking.
  timeout 2 bash -c "echo >/dev/tcp/$MCP_HOST/$MCP_PORT" 2>/dev/null
}

autologin_on() {
  local ini="$XLCORE/launcher.ini"
  [[ -f "$ini" ]] || return 1
  grep -qiE '^\s*AutoLogin\s*=\s*true\s*$' "$ini"
}

do_status() {
  local g l
  g="$(game_pid || true)"; l="$(launcher_pid || true)"
  printf 'game:      %s\n' "${g:-not running}"
  printf 'launcher:  %s\n' "${l:-not running}"
  printf 'XivMcp:    %s (%s:%s)\n' \
    "$(mcp_up && echo answering || echo 'not answering')" "$MCP_HOST" "$MCP_PORT"
  printf 'autologin: %s\n' "$(autologin_on && echo on || echo 'off -- start cannot log in')"
}

do_start() {
  if mcp_up; then log 'already up (XivMcp answers)'; return 0; fi
  if [[ -n "$(game_pid || true)" ]]; then
    log 'the game is running but XivMcp does not answer yet; waiting'
  else
    autologin_on || die "auto-login is off in $XLCORE/launcher.ini.
  Start XIVLauncher by hand once, tick Auto-login, and log in. The credentials
  stay in your keyring; this script never sees them. Until then nothing can
  bring the game back unattended."
    command -v flatpak >/dev/null || die 'no flatpak on PATH'
    flatpak info "$XL_APP" >/dev/null 2>&1 || die "$XL_APP is not installed"
    log "launching $XL_APP"
    # Detached and with its own log: a service must not die with this shell,
    # and a launch that fails silently is the thing that wastes an evening.
    mkdir -p "$XLCORE/logs"
    setsid flatpak run "$XL_APP" >>"$XLCORE/logs/ffxiv-session.log" 2>&1 < /dev/null &
  fi

  local waited=0
  while (( waited < START_TIMEOUT )); do
    if mcp_up; then log "up after ${waited}s"; return 0; fi
    sleep "$POLL_SECONDS"; waited=$(( waited + POLL_SECONDS ))
  done
  die "XivMcp did not answer within ${START_TIMEOUT}s (see $XLCORE/logs/ffxiv-session.log)"
}

do_stop() {
  local g l
  g="$(game_pid || true)"; l="$(launcher_pid || true)"
  if [[ -z "$g$l" ]]; then
    log 'nothing to stop'
    return 0
  fi
  [[ -n "$l" ]] && kill -TERM "$l" 2>/dev/null || true
  [[ -n "$g" ]] && kill -TERM "$g" 2>/dev/null || true
  log 'asked the game to close'
}

do_watch() {
  log "watching (relaunch ${WATCH_BACKOFF}s after the game goes away)"
  while true; do
    if [[ -z "$(game_pid || true)" ]]; then
      log 'the game is not running'
      sleep "$WATCH_BACKOFF"
      # Check again: `stop`, a patch, or somebody closing it on purpose should
      # not be fought over. Only a game that is still gone gets relaunched.
      if [[ -z "$(game_pid || true)" ]]; then
        do_start || log 'relaunch failed; will try again'
      fi
    fi
    sleep "$POLL_SECONDS"
  done
}

do_install() {
  local dir="$HOME/.config/systemd/user"
  mkdir -p "$dir"
  cat > "$dir/$UNIT" <<UNITEOF
[Unit]
Description=Keep FFXIV (XIVLauncher.Core) running for the Ghostty Dalamud plugin
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=$ROOT/tools/ffxiv-session.sh watch
Restart=on-failure
RestartSec=30

[Install]
WantedBy=graphical-session.target
UNITEOF
  systemctl --user daemon-reload
  systemctl --user enable --now "$UNIT"
  log "installed and started $UNIT"
  systemctl --user --no-pager status "$UNIT" | head -5 || true
}

do_uninstall() {
  systemctl --user disable --now "$UNIT" 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/$UNIT"
  systemctl --user daemon-reload
  log "removed $UNIT"
}

case "${1:-status}" in
  start) do_start ;;
  status) do_status ;;
  stop) do_stop ;;
  watch) do_watch ;;
  install) do_install ;;
  uninstall) do_uninstall ;;
  *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
