#!/usr/bin/env bash
# Watch for a new Dalamud appcrash log and answer the crash dialog with
# "Restart normally" + "Restart" by running build/dist/crash-restart.exe inside
# the running XIVLauncher.Core flatpak sandbox (it must share the game's wineserver).
#
# Usage: tools/crash-restart.sh [--once]      (--once: run the exe now, do not watch)
# As a user service (not installed or enabled by default):
#   ExecStart=/path/to/ghostty-dalamud/tools/crash-restart.sh   Restart=on-failure
#
# Environment overrides: XL_APP, XLCORE, WINE_BIN, CRASH_EXE, DIALOG_TIMEOUT, POLL_SECONDS.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XL_APP="${XL_APP:-dev.goats.xivlauncher}"
XLCORE="${XLCORE:-$HOME/.xlcore}"
# default: the newest Wine build XIVLauncher.Core installed
newest_wine() { { find "$XLCORE/compatibilitytool/wine" -mindepth 3 -maxdepth 3 -path '*/bin/wine' 2>/dev/null || true; } | sort -V | tail -n1; }
WINE_BIN="${WINE_BIN:-$(newest_wine)}"
CRASH_EXE="${CRASH_EXE:-$ROOT/build/dist/crash-restart.exe}"
DIALOG_TIMEOUT="${DIALOG_TIMEOUT:-30}"
POLL_SECONDS="${POLL_SECONDS:-2}"
LOGS="$XLCORE/logs"

log() { printf '%s crash-restart: %s\n' "$(date '+%F %T')" "$*" >&2; }

# Windows path for Wine's Z: drive. Where /home is a symlink, the flatpak
# sandbox sees the /home form.
win_path() {
  local p="$1" real
  real="$(readlink -f /home)"
  if [[ "$real" != /home && "$p" == "$real"/* ]]; then p="/home${p#"$real"}"; fi
  printf 'Z:%s' "${p//\//\\}"
}

run_exe() {
  local pid
  pid="$(flatpak ps --columns=pid,application 2>/dev/null | awk -v app="$XL_APP" '$2 == app { print $1; exit }')"
  if [[ -z "$pid" ]]; then log "no running $XL_APP instance"; return 1; fi
  # flatpak enter does not propagate the exit status, so report it on stdout.
  local out
  # shellcheck disable=SC2016  # expanded by the inner sh
  out="$(flatpak enter "$pid" sh -c '
    env HOME="$1" WINEPREFIX="$2" WINEFSYNC=1 WINEDEBUG=-all "$3" "$4" --timeout "$5"
    echo "crash-restart-exit=$?"' sh "$HOME" "$XLCORE/wineprefix" "$WINE_BIN" "$(win_path "$CRASH_EXE")" "$DIALOG_TIMEOUT" 2>&1)" || true
  printf '%s\n' "$out" | grep -v '^crash-restart-exit=' >&2 || true
  local code
  code="$(printf '%s\n' "$out" | sed -n 's/^crash-restart-exit=//p' | tail -n1)"
  log "exe exit=${code:-unknown}"
  [[ "$code" == 0 ]]
}

[[ -f "$CRASH_EXE" ]] || { log "missing $CRASH_EXE (build it first)"; exit 1; }
[[ -n "$WINE_BIN" ]] || { log "no Wine build under $XLCORE/compatibilitytool/wine; set WINE_BIN"; exit 1; }
if [[ "${1:-}" == --once ]]; then run_exe; exit; fi

mkdir -p "$LOGS"
latest() { find "$LOGS" -maxdepth 1 -name 'dalamud_appcrash_*.log' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n1 | cut -d' ' -f2-; }
seen="$(latest)"
log "watching $LOGS (last seen: ${seen:-none})"
while true; do
  if command -v inotifywait >/dev/null; then
    inotifywait -qq -t 60 -e create -e moved_to "$LOGS" || true
  else
    sleep "$POLL_SECONDS"
  fi
  cur="$(latest)"
  if [[ -n "$cur" && "$cur" != "$seen" ]]; then
    seen="$cur"
    log "new crash log: $cur"
    run_exe || log "dialog not answered"
  fi
done
