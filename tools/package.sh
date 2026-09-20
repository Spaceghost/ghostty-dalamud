#!/usr/bin/env bash
# Package a finished build for Windows players (and anyone installing without
# building). Run after tools/build.sh; publishes nothing.
#
#   tools/build.sh && tools/package.sh
#
# Output, all under build/dist/ (<version> is AssemblyVersion from
# shim/GhosttyDalamud/GhosttyDalamud.json):
#   latest.zip                                the plugin folder (manifest, GhosttyDalamud.dll,
#                                             ghostty_loader.dll, ghostty_core.dll, lua/, themes/), as
#                                             Dalamud installs it from a plugin repository. The name
#                                             never changes, so the listing's download URL
#                                             (.../releases/latest/download/latest.zip) never does either.
#   GhosttyDalamud-<version>.zip              the same bytes under a self-describing name
#   ghostty-agent-<version>-windows-x64.zip   ghostty-agent.exe
#   pluginmaster.json                         this plugin's entry for a Dalamud plugin repository;
#                                             spacegho.st/mods/ffxiv/plugins.json is assembled from it
#   pluginmaster-testing.json                 the same for a test build, with TESTING=1
#
# Environment:
#   REPO               owner/name on GitHub (default: $GITHUB_REPOSITORY, else Spaceghost/ghostty-dalamud)
#   TESTING            1 to write pluginmaster-testing.json instead of pluginmaster.json
#   RELEASE_TAG        the tag being released; the listing then carries the changelog
#   SOURCE_DATE_EPOCH  timestamp for the zip entries and LastUpdate (default: the last
#                      commit's time, else 0), so the same build packs to the same bytes
#
# Exit codes: 0 done, 1 a build output is missing (run tools/build.sh), 127 zip missing.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
DIST=build/dist
PLUGIN="$DIST/GhosttyDalamud"
MANIFEST="$PLUGIN/GhosttyDalamud.json"

command -v zip >/dev/null || { echo "error: zip is required" >&2; exit 127; }
command -v python3 >/dev/null || { echo "error: python3 is required" >&2; exit 127; }
for f in GhosttyDalamud.dll GhosttyDalamud.json ghostty_loader.dll ghostty_core.dll lua/init.lua lua/platform.lua; do
  [[ -f "$PLUGIN/$f" ]] || { echo "error: $PLUGIN/$f missing; run tools/build.sh first" >&2; exit 1; }
done
[[ -f "$DIST/ghostty-agent.exe" ]] || { echo "error: $DIST/ghostty-agent.exe missing; run tools/build.sh (without SKIP_WIN)" >&2; exit 1; }

VERSION="$(sed -n 's/^[[:space:]]*"AssemblyVersion"[[:space:]]*:[[:space:]]*"\([0-9.]*\)".*/\1/p' "$MANIFEST" | head -n1)"
[[ -n "$VERSION" ]] || { echo "error: no AssemblyVersion in $MANIFEST" >&2; exit 1; }
if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
  SOURCE_DATE_EPOCH="$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || echo 0)"
fi
REPO="${REPO:-${GITHUB_REPOSITORY:-Spaceghost/ghostty-dalamud}}"

PLUGIN_ZIP="GhosttyDalamud-$VERSION.zip"
AGENT_ZIP="ghostty-agent-$VERSION-windows-x64.zip"
STAGE="build/package-stage"

# zip the files under $1 (relative names, sorted, fixed times, no extra attributes)
pack() {
  local dir="$1" out="$2"
  find "$dir" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
  rm -f "$out"
  ( cd "$dir" && find . -type f | LC_ALL=C sort | sed 's|^\./||' | TZ=UTC zip -X -D -q "$ROOT/$out" -@ )
}

echo "== $PLUGIN_ZIP"
rm -rf "$STAGE" && mkdir -p "$STAGE/plugin/lua" "$STAGE/plugin/themes" "$STAGE/agent"
cp "$PLUGIN/GhosttyDalamud.dll" "$PLUGIN/GhosttyDalamud.json" "$PLUGIN/ghostty_loader.dll" "$PLUGIN/ghostty_core.dll" "$STAGE/plugin/"
cp "$PLUGIN"/lua/*.lua "$STAGE/plugin/lua/"
cp "$PLUGIN"/themes/*.theme "$STAGE/plugin/themes/"
pack "$STAGE/plugin" "$DIST/$PLUGIN_ZIP"
# The stable name the plugin repository points at; same bytes.
cp "$DIST/$PLUGIN_ZIP" "$DIST/latest.zip"

echo "== $AGENT_ZIP"
cp "$DIST/ghostty-agent.exe" "$STAGE/agent/"
pack "$STAGE/agent" "$DIST/$AGENT_ZIP"

CHANNEL=stable
LISTING="$DIST/pluginmaster.json"
if [[ "${TESTING:-0}" == 1 ]]; then CHANNEL=testing; LISTING="$DIST/pluginmaster-testing.json"; fi
echo "== $(basename "$LISTING")"
# The manifest as it ships, plus the fields a repository listing adds (download links for
# both channels, LastUpdate). tools/pluginmaster.py is shared with the other plugins here.
# With RELEASE_TAG (the release workflow sets it), the listing also carries what changed,
# from the changelog, for the installer to show.
NOTES=()
if [[ -n "${RELEASE_TAG:-}" ]]; then
  NOTES=(--changelog "$(python3 "$ROOT/tools/releasekit.py" installer-notes "$RELEASE_TAG")")
fi
python3 "$ROOT/tools/pluginmaster.py" \
  --manifest "$MANIFEST" --repo "$REPO" --channel "$CHANNEL" \
  --last-update "$SOURCE_DATE_EPOCH" "${NOTES[@]}" --out "$LISTING"
cat "$LISTING"
rm -rf "$STAGE"

echo "== done"
ls -la "$DIST/latest.zip" "$DIST/$PLUGIN_ZIP" "$DIST/$AGENT_ZIP" "$LISTING"
