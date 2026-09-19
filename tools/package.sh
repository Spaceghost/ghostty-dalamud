#!/usr/bin/env bash
# Package a finished build for Windows players (and anyone installing without
# building). Run after tools/build.sh; publishes nothing.
#
#   tools/build.sh && tools/package.sh
#
# Output, all under build/dist/ (<version> is AssemblyVersion from
# shim/GhosttyDalamud/GhosttyDalamud.json):
#   GhosttyDalamud-<version>.zip              the plugin folder (manifest, GhosttyDalamud.dll,
#                                             ghostty_loader.dll, ghostty_core.dll, lua/), as
#                                             Dalamud installs it from a custom repository
#   ghostty-agent-<version>-windows-x64.zip   ghostty-agent.exe
#   pluginmaster.json                         a Dalamud custom-repository listing for the plugin zip
#
# Environment:
#   DOWNLOAD_BASE_URL  where the zip will be downloadable from, without the file
#                      name (default: https://github.com/$GITHUB_REPOSITORY/releases/download/v<version>
#                      when GITHUB_REPOSITORY is set; otherwise a placeholder, with a warning)
#   REPO_URL           the project page for the listing (default: https://github.com/$GITHUB_REPOSITORY
#                      when set, else empty)
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
for f in GhosttyDalamud.dll GhosttyDalamud.json ghostty_loader.dll ghostty_core.dll lua/init.lua lua/platform.lua; do
  [[ -f "$PLUGIN/$f" ]] || { echo "error: $PLUGIN/$f missing; run tools/build.sh first" >&2; exit 1; }
done
[[ -f "$DIST/ghostty-agent.exe" ]] || { echo "error: $DIST/ghostty-agent.exe missing; run tools/build.sh (without SKIP_WIN)" >&2; exit 1; }

VERSION="$(sed -n 's/^[[:space:]]*"AssemblyVersion"[[:space:]]*:[[:space:]]*"\([0-9.]*\)".*/\1/p' "$MANIFEST" | head -n1)"
[[ -n "$VERSION" ]] || { echo "error: no AssemblyVersion in $MANIFEST" >&2; exit 1; }
if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
  SOURCE_DATE_EPOCH="$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || echo 0)"
fi
REPO_URL="${REPO_URL:-${GITHUB_REPOSITORY:+https://github.com/$GITHUB_REPOSITORY}}"
if [[ -z "${DOWNLOAD_BASE_URL:-}" ]]; then
  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    DOWNLOAD_BASE_URL="https://github.com/$GITHUB_REPOSITORY/releases/download/v$VERSION"
  else
    DOWNLOAD_BASE_URL="https://example.invalid/set-DOWNLOAD_BASE_URL"
    echo "warning: DOWNLOAD_BASE_URL is not set; pluginmaster.json points at a placeholder" >&2
  fi
fi
DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL%/}"

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

echo "== $AGENT_ZIP"
cp "$DIST/ghostty-agent.exe" "$STAGE/agent/"
pack "$STAGE/agent" "$DIST/$AGENT_ZIP"

echo "== pluginmaster.json"
# the manifest as it ships, plus the fields a repository listing adds
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
body="$(sed -e '$!b' -e '/^[[:space:]]*}[[:space:]]*$/d' "$MANIFEST" | sed -e 's/^/  /')"
[[ "$(tail -n1 "$MANIFEST" | tr -d '[:space:]')" == "}" ]] || { echo "error: $MANIFEST must end with a closing brace line" >&2; exit 1; }
url="$(json_escape "$DOWNLOAD_BASE_URL/$PLUGIN_ZIP")"
{
  echo "["
  printf '%s,\n' "$body"
  printf '    "RepoUrl": "%s",\n' "$(json_escape "$REPO_URL")"
  printf '    "DownloadLinkInstall": "%s",\n' "$url"
  printf '    "DownloadLinkUpdate": "%s",\n' "$url"
  printf '    "DownloadLinkTesting": "%s",\n' "$url"
  printf '    "IsHide": false,\n'
  printf '    "IsTestingExclusive": false,\n'
  printf '    "DownloadCount": 0,\n'
  printf '    "LastUpdate": %s\n' "$SOURCE_DATE_EPOCH"
  echo "  }"
  echo "]"
} > "$DIST/pluginmaster.json"
rm -rf "$STAGE"

echo "== done"
ls -la "$DIST/$PLUGIN_ZIP" "$DIST/$AGENT_ZIP" "$DIST/pluginmaster.json"
