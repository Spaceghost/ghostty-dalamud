#!/usr/bin/env bash
# Pack the plugin together with an agent, for players who would rather not
# install a system package. Run after tools/build.sh, and after
# tools/ci/agent-rpm.sh when the Linux agent is wanted; publishes nothing.
#
#   tools/build.sh && tools/package.sh && tools/package-bundle.sh
#
# Output, under build/dist by default (<version> is AssemblyVersion from
# shim/GhosttyDalamud/GhosttyDalamud.json):
#   GhosttyDalamud-<version>-with-agent-windows-x64.zip
#   GhosttyDalamud-<version>-with-agent-linux-x86_64.zip
#
# Each is the plugin folder exactly as latest.zip has it, plus `agent/` holding
# the agent for that platform and its README. A bundle whose agent was not
# built is skipped and said so; this never fails a build for a missing one.
#
# The plugin repository never serves these: `latest.zip` stays free of the
# agent (tests/test_release.py rejects it as an unapproved payload), so the
# reviewed package a player installs in one click carries no server. These are
# separate downloads for people who want one file and no package manager.
#
# The plugin does not start the agent; you do. That is on purpose: the agent
# holds your terminals and they are meant to outlive the plugin, so it must not
# be replaced under a live session by a plugin update. Copy it somewhere of
# your own and run it from there.
#
# Environment:
#   SOURCE_DATE_EPOCH   entry times (default: the last commit's time)
#
# Exit codes: 0 done, 1 the plugin folder is missing, 127 zip missing.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
DIST=build/dist
PLUGIN="$DIST/GhosttyDalamud"

command -v zip >/dev/null || { echo "error: zip is required" >&2; exit 127; }
[[ -f "$PLUGIN/GhosttyDalamud.json" ]] || {
  echo "error: $PLUGIN is not a built plugin folder; run tools/build.sh first" >&2
  exit 1
}
VERSION="$(sed -n 's/^[[:space:]]*"AssemblyVersion"[[:space:]]*:[[:space:]]*"\([0-9.]*\)".*/\1/p' \
  "$PLUGIN/GhosttyDalamud.json" | head -n1)"
[[ -n "$VERSION" ]] || { echo "error: no AssemblyVersion in the manifest" >&2; exit 1; }
if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
  SOURCE_DATE_EPOCH="$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || echo 0)"
fi

STAGE=build/bundle-stage

pack_bundle() { # label agent-binary agent-name
  local label="$1" agent="$2" name="$3"
  local out="$DIST/GhosttyDalamud-$VERSION-with-agent-$label.zip"
  if [[ ! -f "$agent" ]]; then
    echo "== skipping the $label bundle: $agent was not built"
    return 0
  fi
  echo "== $(basename "$out")"
  rm -rf "$STAGE"
  mkdir -p "$STAGE/agent"
  cp -r "$PLUGIN/." "$STAGE/"
  install -m0755 "$agent" "$STAGE/agent/$name"
  cp -p packaging/README-agent.md "$STAGE/agent/README-agent.md"
  if [[ -f packaging/ghostty-agent.service ]]; then
    cp -p packaging/ghostty-agent.service "$STAGE/agent/ghostty-agent.service"
  fi
  if [[ -f LICENSE ]]; then cp -p LICENSE "$STAGE/agent/LICENSE"; fi
  find "$STAGE" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
  rm -f "$out"
  ( cd "$STAGE" && find . -type f | LC_ALL=C sort | sed 's|^\./||' |
    TZ=UTC zip -X -D -q "$ROOT/$out" -@ )
  rm -rf "$STAGE"
  ls -la "$out"
}

pack_bundle windows-x64 "$DIST/ghostty-agent.exe" ghostty-agent.exe
# The Linux agent from the packaging run when there is one, else this host's build.
LINUX_AGENT="$DIST/ghostty-agent"
if [[ -f build/release/ghostty-agent ]]; then LINUX_AGENT=build/release/ghostty-agent; fi
pack_bundle linux-x86_64 "$LINUX_AGENT" ghostty-agent

echo "== done"
