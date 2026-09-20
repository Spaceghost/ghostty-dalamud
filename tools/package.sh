#!/usr/bin/env bash
# Package a finished build for the Dalamud installer. Run after tools/build.sh;
# publishes nothing: the release workflow attaches what this writes.
#
#   tools/fetch-vendor.sh && tools/build.sh && tools/package.sh
#
# Output, all under build/release/:
#   latest.zip                 build/dist/GhosttyDalamud as Dalamud unpacks it (manifest,
#                              GhosttyDalamud.dll, ghostty_core.dll, ghostty_loader.dll,
#                              lua/), without .pdb. The name never changes, so the listing's
#                              download URL never does either.
#   GhosttyDalamud-<version>.zip   the same bytes under a self-describing name
#   pluginmaster.json          this plugin's entry for a Dalamud plugin repository; the
#                              listing at spacegho.st/mods/ffxiv/plugins.json is assembled
#                              from it (pluginmaster-testing.json with TESTING=1)
#
# Environment:
#   REPO               owner/name on GitHub (default $GITHUB_REPOSITORY, else Spaceghost/ghostty-dalamud)
#   TESTING            1 for a test build: writes pluginmaster-testing.json instead
#   SOURCE_DATE_EPOCH  timestamp for the zip entries and LastUpdate (default: the last
#                      commit's time, else 0), so the same build packs to the same bytes
#
# Exit codes: 0 done, 1 the build output is missing or incomplete, 127 a missing tool.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PLUGIN=build/dist/GhosttyDalamud
MANIFEST="$PLUGIN/GhosttyDalamud.json"
OUT=build/release
REPO="${REPO:-${GITHUB_REPOSITORY:-Spaceghost/ghostty-dalamud}}"

for tool in zip unzip python3; do
  command -v "$tool" >/dev/null || { echo "error: $tool is required" >&2; exit 127; }
done
for f in GhosttyDalamud.dll GhosttyDalamud.json ghostty_core.dll ghostty_loader.dll lua/init.lua; do
  [[ -f "$PLUGIN/$f" ]] || { echo "error: $PLUGIN/$f missing; run tools/build.sh (without SKIP_WIN or SKIP_SHIM)" >&2; exit 1; }
done

VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["AssemblyVersion"])' "$MANIFEST")"
if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
  SOURCE_DATE_EPOCH="$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || echo 0)"
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ghostty-package.XXXXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
rm -rf "$OUT" && mkdir -p "$OUT"
cp -R "$PLUGIN/." "$STAGE/"
find "$STAGE" -name '*.pdb' -delete
find "$STAGE" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
( cd "$STAGE" && find . -type f | LC_ALL=C sort | sed 's|^\./||' | TZ=UTC zip -X -D -q "$ROOT/$OUT/latest.zip" -@ )
cp "$OUT/latest.zip" "$OUT/GhosttyDalamud-$VERSION.zip"
echo "== $OUT/latest.zip"
unzip -l "$OUT/latest.zip"

CHANNEL=stable
LISTING="$OUT/pluginmaster.json"
if [[ "${TESTING:-0}" == 1 ]]; then CHANNEL=testing; LISTING="$OUT/pluginmaster-testing.json"; fi
python3 tools/pluginmaster.py --manifest "$MANIFEST" --repo "$REPO" --channel "$CHANNEL" \
  --last-update "$SOURCE_DATE_EPOCH" --out "$LISTING"
echo "== $LISTING"
cat "$LISTING"
