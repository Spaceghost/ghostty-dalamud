#!/usr/bin/env bash
# In-game tests: put a freshly built ghostty_core.dll into the running game
# through the loader's hot swap, run `/term selftest all` there through
# XivMcp's MCP endpoint, and collect the JSON report. docs/CI.md, "In-game
# tests", has the picture and the one-time setup.
#
#   tools/ci/ingame.sh            (or tools/ci/run.sh ingame)
#
# Needs build/dist/ from tools/build.sh (ghostty_core.dll, lua/,
# build-info.json), curl and jq, and a game with the GhosttyDalamud dev
# plugin and XivMcp loaded on this machine.
#
#   1. asks XivMcp whether the game runs and a character is logged in
#      (get_player); if not: "skipped: game not available", exit 3
#   2. records get_dalamud_info and list_plugins (Ghostty and XivMcp only)
#   3. copies lua/ and then ghostty_core.dll into the dev plugin folder;
#      GhosttyDalamud.dll, its .json, the loader and an installed
#      lua/init.lua are never written, so Dalamud never reloads managed code
#   4. waits until the swapped-in core writes selftest/core-loaded.json with
#      this build's id
#   5. sends `/term selftest all` (execute_command) and waits for
#      selftest/latest.json of a new, complete run of this build
#   6. writes build/ingame/ingame-report.json (header + report), prints it,
#      and fails on any failed case
#
# Exit status: 0 every case passed or skipped, 1 a case failed or something
# went wrong, 2 bad setup, 3 skipped: game not available.
#
# Environment:
#   XIVMCP_CI_TOKEN         bearer token of XivMcp's "ghostty-ci" client (required;
#                           never read from a file, never printed)
#   XIVMCP_URL              default http://127.0.0.1:41800/mcp
#   GHOSTTY_DEV_PLUGIN_DIR  the dev plugin folder the game loads (required), the
#                           one holding GhosttyDalamud.dll and ghostty_loader.dll
#   GHOSTTY_CONFIG_DIR      the plugin's config directory, default
#                           ~/.xlcore/pluginConfigs/GhosttyDalamud
#   INGAME_DIST             default build/dist
#   INGAME_OUT              default build/ingame
#   INGAME_SUITES           default all (anything /term selftest takes)
#   INGAME_LOAD_TIMEOUT     seconds for the new core to report, default 60
#   INGAME_RUN_TIMEOUT      seconds for the self-test, default 240
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

URL="${XIVMCP_URL:-http://127.0.0.1:41800/mcp}"
DIST="${INGAME_DIST:-$ROOT/build/dist}"
OUT="${INGAME_OUT:-$ROOT/build/ingame}"
CONFIG_DIR="${GHOSTTY_CONFIG_DIR:-$HOME/.xlcore/pluginConfigs/GhosttyDalamud}"
PLUGIN_DIR="${GHOSTTY_DEV_PLUGIN_DIR:-}"
SUITES="${INGAME_SUITES:-all}"
LOAD_TIMEOUT="${INGAME_LOAD_TIMEOUT:-60}"
RUN_TIMEOUT="${INGAME_RUN_TIMEOUT:-240}"
SELFTEST="$CONFIG_DIR/selftest"

log() { printf '== ingame: %s\n' "$*"; }
fail() { printf 'ingame: error: %s\n' "$*" >&2; exit 1; }
setup() { printf 'ingame: setup: %s\n' "$*" >&2; exit 2; }
skip() {
  printf 'skipped: game not available (%s)\n' "$*"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '### In-game tests\n\nskipped: game not available (%s)\n' "$*" >>"$GITHUB_STEP_SUMMARY"
  fi
  exit 3
}

command -v curl >/dev/null || setup "curl is required"
command -v jq >/dev/null || setup "jq is required"
[[ "$SUITES" =~ ^[a-z][a-z\ ,]{0,120}$ ]] || setup "INGAME_SUITES must be suite names (see /term selftest list), got: $SUITES"
[[ -n "${XIVMCP_CI_TOKEN:-}" ]] || setup "XIVMCP_CI_TOKEN is not set (the ghostty-ci client's token, from the environment only)"
[[ -n "$PLUGIN_DIR" ]] || setup "GHOSTTY_DEV_PLUGIN_DIR is not set (the dev plugin folder the game loads)"
[[ -f "$PLUGIN_DIR/GhosttyDalamud.dll" && -f "$PLUGIN_DIR/ghostty_loader.dll" ]] ||
  setup "$PLUGIN_DIR has no GhosttyDalamud.dll and ghostty_loader.dll: install the plugin once with tools/install-dev.sh"
for f in ghostty_core.dll build-info.json lua/init.lua; do
  [[ -f "$DIST/$f" ]] || setup "$DIST/$f missing: run tools/build.sh (or download the ci.yml artifact) first"
done
BUILD_ID="$(jq -r .build_id "$DIST/build-info.json")"
COMMIT="$(jq -r .commit "$DIST/build-info.json")"
[[ "$BUILD_ID" =~ ^[A-Za-z0-9._-]+$ ]] || setup "no usable build_id in $DIST/build-info.json"

mkdir -p "$OUT"
WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ingame.XXXXXX")"
chmod 700 "$WORK"
SESSION=""
cleanup() {
  if [[ -n "$SESSION" ]]; then
    printf 'header = "Authorization: Bearer %s"\n' "$XIVMCP_CI_TOKEN" |
      curl -s -o /dev/null -m 5 -K - -X DELETE -H "Mcp-Session-Id: $SESSION" "$URL" || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# One JSON-RPC request; the response body goes to stdout. The token reaches
# curl on stdin (-K -), so it is neither an argument nor a file.
rpc_n=0
rpc() { # method params-json
  rpc_n=$((rpc_n + 1))
  jq -cn --arg m "$1" --argjson p "$2" --argjson id "$rpc_n" '{jsonrpc: "2.0", id: $id, method: $m, params: $p}' >"$WORK/req.json"
  local extra=()
  [[ -n "$SESSION" ]] && extra=(-H "Mcp-Session-Id: $SESSION")
  printf 'header = "Authorization: Bearer %s"\n' "$XIVMCP_CI_TOKEN" |
    curl -sS -m 30 -K - -D "$WORK/headers" -o "$WORK/resp.json" -w '%{http_code}' \
      -H 'Content-Type: application/json' -H 'Accept: application/json' "${extra[@]}" \
      --data-binary @"$WORK/req.json" "$URL" >"$WORK/status" || return 7
  local code
  code="$(cat "$WORK/status")"
  [[ "$code" == 200 ]] || { printf 'HTTP %s: %s\n' "$code" "$(head -c 300 "$WORK/resp.json")" >&2; return 8; }
  cat "$WORK/resp.json"
}

# tools/call; prints the tool's result object ({content, structuredContent?, isError?})
tool() { # name args-json
  local r
  r="$(rpc tools/call "$(jq -cn --arg n "$1" --argjson a "$2" '{name: $n, arguments: $a}')")" || return $?
  if jq -e '.error' >/dev/null <<<"$r"; then
    printf '%s\n' "$(jq -c '.error' <<<"$r")" >&2
    return 9
  fi
  jq -c '.result' <<<"$r"
}

# the structured result, else the first text block parsed as JSON, else that text
tool_value() { jq -c '.structuredContent // (.content[0].text | (try fromjson catch .))' ; }

# 1. is there a game, and a character in it? ------------------------------------------
log "XivMcp at $URL"
init="$(rpc initialize '{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"ghostty-ci","version":"1"}}')" ||
  skip "no answer from XivMcp at $URL; is the game running with XivMcp loaded?"
SESSION="$(tr -d '\r' <"$WORK/headers" | awk -F': ' 'tolower($1) == "mcp-session-id" { print $2 }' | tail -n1)"
[[ -n "$SESSION" ]] || fail "XivMcp answered initialize without an Mcp-Session-Id: $(head -c 200 <<<"$init")"
rpc notifications/initialized '{}' >/dev/null 2>&1 || true
server="$(jq -c '.result.serverInfo // {}' <<<"$init")"

player="$(tool get_player '{}')" || skip "get_player failed; XivMcp's Read tier may be off for ghostty-ci"
if [[ "$(jq -r '.isError // false' <<<"$player")" == true ]]; then
  skip "no character logged in ($(jq -r '.content[0].text // ""' <<<"$player" | head -c 120))"
fi
# only whether someone is logged in is kept: nothing about the character goes into the report
unset player

# 2. what the game runs ------------------------------------------------------------------
dalamud="$( (tool get_dalamud_info '{}' || echo '{}') | tool_value 2>/dev/null || echo 'null')"
plugins="$( (tool list_plugins '{}' || echo '{}') | tool_value 2>/dev/null |
  jq -c '[.. | objects | select(((.internalName // .InternalName // .name // .Name // "") | tostring | test("ghostty|xivmcp"; "i")))] | unique' 2>/dev/null ||
  echo '[]')"
log "dalamud: $(jq -c '{dalamudVersion, gameVersion} // .' <<<"$dalamud" 2>/dev/null || echo "$dalamud")"

# 3. the new core, through the loader's hot swap --------------------------------------------
log "installing build $BUILD_ID (commit $COMMIT) into $PLUGIN_DIR (core and lua/ only)"
install_start="$(date +%s)"
rm -rf "$PLUGIN_DIR/lua.tmp" "$PLUGIN_DIR/lua.old"
cp -r "$DIST/lua" "$PLUGIN_DIR/lua.tmp"
[[ -f "$PLUGIN_DIR/lua/init.lua" ]] && cp -p "$PLUGIN_DIR/lua/init.lua" "$PLUGIN_DIR/lua.tmp/init.lua" # it may carry the agent token
[[ -d "$PLUGIN_DIR/lua" ]] && mv "$PLUGIN_DIR/lua" "$PLUGIN_DIR/lua.old"
mv "$PLUGIN_DIR/lua.tmp" "$PLUGIN_DIR/lua"
rm -rf "$PLUGIN_DIR/lua.old"
cp "$DIST/ghostty_core.dll" "$PLUGIN_DIR/ghostty_core.dll.tmp"
mv -f "$PLUGIN_DIR/ghostty_core.dll.tmp" "$PLUGIN_DIR/ghostty_core.dll" # its new write time makes the loader swap

# 4. the swapped-in core reports its build ------------------------------------------------------
log "waiting up to ${LOAD_TIMEOUT}s for the loader to swap in build $BUILD_ID"
deadline=$(($(date +%s) + LOAD_TIMEOUT))
while :; do
  f="$SELFTEST/core-loaded.json"
  if [[ -f "$f" && "$(stat -c %Y "$f")" -ge "$install_start" && "$(jq -r .build_id "$f" 2>/dev/null)" == "$BUILD_ID" ]]; then
    break
  fi
  if (($(date +%s) > deadline)); then
    now="$(jq -r .build_id "$f" 2>/dev/null || echo none)"
    fail "the game did not load build $BUILD_ID within ${LOAD_TIMEOUT}s (core-loaded.json says: $now). Is the plugin enabled, the kill switch off, and the game window drawing?"
  fi
  sleep 1
done
log "loaded: $(cat "$SELFTEST/core-loaded.json")"

# 5. run the self-test -------------------------------------------------------------------------
before_run="$(jq -r .run_id "$SELFTEST/latest.json" 2>/dev/null || echo none)"
log "/term selftest $SUITES"
res="$(tool execute_command "$(jq -cn --arg c "/term selftest $SUITES" '{command: $c}')")" ||
  fail "execute_command failed; XivMcp must allow ghostty-ci to run exactly '/term selftest' without confirmation"
if [[ "$(jq -r '.isError // false' <<<"$res")" == true ]]; then
  fail "execute_command refused: $(jq -r '.content[0].text // ""' <<<"$res" | head -c 300)"
fi

log "waiting up to ${RUN_TIMEOUT}s for the report"
deadline=$(($(date +%s) + RUN_TIMEOUT))
report="$SELFTEST/latest.json"
while :; do
  if [[ -f "$report" ]] && jq -e --arg b "$BUILD_ID" --arg r "$before_run" \
      '.complete == true and .build.id == $b and .run_id != $r' "$report" >/dev/null 2>&1; then
    break
  fi
  if (($(date +%s) > deadline)); then
    state="$(jq -r '"\(.state) \(.run_id) build \(.build.id)"' "$report" 2>/dev/null || echo 'no report')"
    fail "no complete report of build $BUILD_ID within ${RUN_TIMEOUT}s (latest.json: $state)"
  fi
  sleep 2
done

# 6. the report ----------------------------------------------------------------------------------
jq --argjson server "$server" --argjson dalamud "$dalamud" --argjson plugins "$plugins" \
  --arg build "$BUILD_ID" --arg commit "$COMMIT" --arg sha "${GITHUB_SHA:-}" --arg run "${GITHUB_RUN_ID:-}" \
  '{header: {expected_build: $build, expected_commit: $commit, github_sha: $sha, github_run_id: $run,
     xivmcp: $server, dalamud: $dalamud, plugins: $plugins}, selftest: .}' "$report" >"$OUT/ingame-report.json"
cat "$OUT/ingame-report.json"

summary="$(jq -r '.selftest.summary | "\(.passed) passed, \(.failed) failed, \(.skipped) skipped"' "$OUT/ingame-report.json")"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    printf '### In-game tests: build %s\n\n%s\n\n| suite | case | status | ms | message |\n| --- | --- | --- | --- | --- |\n' "$BUILD_ID" "$summary"
    jq -r '.selftest.cases[] | "| \(.suite) | \(.case) | \(.status) | \(.ms) | \(.message | gsub("\\|"; "/")) |"' "$OUT/ingame-report.json"
  } >>"$GITHUB_STEP_SUMMARY"
fi
if ! jq -e '.selftest.ok == true and .selftest.summary.failed == 0' "$OUT/ingame-report.json" >/dev/null; then
  jq -r '.selftest.cases[] | select(.status == "fail") | "FAIL \(.suite)/\(.case): \(.message)"' "$OUT/ingame-report.json" >&2
  fail "in-game self-test: $summary"
fi
log "in-game self-test: $summary"
