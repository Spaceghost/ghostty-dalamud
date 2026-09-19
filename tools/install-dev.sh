#!/usr/bin/env bash
# Stage the dev build of the GhosttyDalamud plugin where Dalamud loads it.
# A convenience for building on Linux (it prints the Wine Z:\ path); on
# Windows, copy build/dist/GhosttyDalamud/ yourself (README, "Windows").
#
#   tools/build.sh && tools/install-dev.sh [--widget]
#
# Copies build/dist/GhosttyDalamud/ (GhosttyDalamud.dll, .json, .pdb,
# ghostty_loader.dll, ghostty_core.dll, lua/) into $GHOSTTY_DEV_PLUGIN_DIR, by
# default build/dev-plugin/GhosttyDalamud in this checkout. Once, in game: /xlsettings ->
# Experimental -> Dev Plugin Locations, add the GhosttyDalamud.dll path this
# script prints, then /xlplugins -> Dev Tools -> enable Ghostty (and "load on
# boot").
#
# The plugin loads ghostty_loader.dll, which runs a copy of ghostty_core.dll
# and swaps it within about two seconds of the file changing (also on
# `/term reload-core`); the new core reads lua/ again. So core and Lua changes
# never rewrite GhosttyDalamud.dll: it, its .json and .pdb, and the loader are
# written only when their bytes differ, and the script says whether Dalamud
# will reload the managed plugin (every managed reload leaks memory in game).
#
# --widget also stages the Umbra toolbar widget at $UMBRA_WIDGET_DLL, by
# default Umbra.Ghostty/Umbra.Ghostty.dll beside the plugin folder. Add that
# file once in Umbra's Settings -> Plugins; Umbra restarts itself when it
# changes.
#
# Every file is written beside its target and renamed over it, lua/ first and
# the managed DLL last, so a watching Dalamud never sees half a plugin. An
# installed lua/init.lua is never replaced (it may carry the agent token).
# Nothing under ~/.xlcore is touched: the plugin moves its config itself on
# first start (lua/migrate.lua).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/build/dist/GhosttyDalamud"
DEST="${GHOSTTY_DEV_PLUGIN_DIR:-$ROOT/build/dev-plugin/GhosttyDalamud}"
WIDGET_DLL="${UMBRA_WIDGET_DLL:-$(dirname "$DEST")/Umbra.Ghostty/Umbra.Ghostty.dll}"
widget=0
for a in "$@"; do
  case "$a" in
    --widget) widget=1 ;;
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

for f in GhosttyDalamud.dll GhosttyDalamud.json ghostty_loader.dll ghostty_core.dll lua/init.lua lua/migrate.lua; do
  [[ -f "$SRC/$f" ]] || { echo "missing $SRC/$f; run tools/build.sh first" >&2; exit 1; }
done
if [[ $widget == 1 && ! -f "$ROOT/build/dist/Umbra.Ghostty.dll" ]]; then
  echo "missing build/dist/Umbra.Ghostty.dll; run tools/build.sh without SKIP_UMBRA" >&2
  exit 1
fi

# copy to <target>.tmp, then rename over the target
put() {
  cp "$1" "$2.tmp"
  mv -f "$2.tmp" "$2"
}
# put only when the bytes differ; true when it wrote
put_changed() {
  if [[ -f "$2" ]] && cmp -s "$1" "$2"; then return 1; fi
  put "$1" "$2"
}

mkdir -p "$DEST"
rm -rf "$DEST/lua.tmp" "$DEST/lua.old"
cp -r "$SRC/lua" "$DEST/lua.tmp"
if [[ -f "$DEST/lua/init.lua" ]]; then
  cp -p "$DEST/lua/init.lua" "$DEST/lua.tmp/init.lua"
  cmp -s "$SRC/lua/init.lua" "$DEST/lua/init.lua" ||
    echo "kept the installed lua/init.lua; the shipped one differs: $SRC/lua/init.lua"
fi
[[ -d "$DEST/lua" ]] && mv "$DEST/lua" "$DEST/lua.old"
mv "$DEST/lua.tmp" "$DEST/lua"
rm -rf "$DEST/lua.old"

loader_changed=0
put_changed "$SRC/ghostty_loader.dll" "$DEST/ghostty_loader.dll" && loader_changed=1
# always rewritten: its new write time is what makes the loader swap (and reread lua/)
put "$SRC/ghostty_core.dll" "$DEST/ghostty_core.dll"

managed_changed=0
put_changed "$SRC/GhosttyDalamud.json" "$DEST/GhosttyDalamud.json" && managed_changed=1
if [[ -f "$SRC/GhosttyDalamud.pdb" ]] && ! cmp -s "$SRC/GhosttyDalamud.dll" "$DEST/GhosttyDalamud.dll" 2>/dev/null; then
  put "$SRC/GhosttyDalamud.pdb" "$DEST/GhosttyDalamud.pdb"
fi
put_changed "$SRC/GhosttyDalamud.dll" "$DEST/GhosttyDalamud.dll" && managed_changed=1
echo "staged $DEST"

if [[ $managed_changed == 1 ]]; then
  echo "managed reload: yes (GhosttyDalamud.dll or .json changed; Dalamud reloads the plugin, which loads the loader and core anew)"
else
  echo "managed reload: no (the running loader swaps in the new ghostty_core.dll within ~2 s)"
  if [[ $loader_changed == 1 ]]; then
    echo "note: ghostty_loader.dll changed; the running game keeps the old loader until the plugin is reloaded or the game restarts"
  fi
fi

if [[ $widget == 1 ]]; then
  mkdir -p "$(dirname "$WIDGET_DLL")"
  if put_changed "$ROOT/build/dist/Umbra.Ghostty.dll" "$WIDGET_DLL"; then
    echo "staged $WIDGET_DLL (Umbra restarts)"
  else
    echo "unchanged $WIDGET_DLL"
  fi
fi

# Dalamud runs under Wine with / mapped to Z:
win_path="Z:${DEST//\//\\}\\GhosttyDalamud.dll"
echo "dev plugin location: $win_path"
