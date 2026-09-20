#!/usr/bin/env bash
# The in-game path, exercised without the game: tools/ci/ingame.sh against
# tools/ci/mock-xivmcp.py and a fake plugin folder in a temporary directory.
#
#   tools/ci/ingame-dryrun.sh [scenario...]     (or tools/ci/run.sh ingame-dryrun)
#
# Scenarios, each its own mock and its own throwaway game tree:
#
#   pass       every case passes                     expects exit 0 and a report
#   fail       one case fails                        expects exit 1
#   nogame     nothing listens on the endpoint       expects exit 3 (skipped)
#   noplayer   no character logged in                expects exit 3 (skipped)
#   noswap     the loader never takes the new core   expects exit 1
#   stale      the report names an older build        expects exit 1
#   nosecret   XIVMCP_CI_TOKEN unset                 expects exit 2 (setup)
#   badsuites  INGAME_SUITES is not suite names      expects exit 2 (setup)
#   badcmd     the client tries a command that is
#              not /term selftest                    expects the mock to refuse
#
# With no arguments every scenario runs. Needs python3, curl and jq and
# nothing else: no build, no game, no network, no secret. This is what
# .github/workflows/ci.yml runs on every push, so ingame.sh and the workflow's
# shape stay honest between the rare runs that do touch the game.
#
# What it does NOT prove: that the real XivMcp answers this way, that the real
# loader swaps a core, or that `/term selftest` passes in the game. It proves
# only that tools/ci/ingame.sh drives the protocol and the file handshake
# correctly and reports the right exit status. See docs/CI.md.
#
# Environment:
#   INGAME_DRYRUN_OUT   where the throwaway trees go, default a mktemp dir
#   KEEP=1              keep them, and say where
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

ALL=(pass fail nogame noplayer noswap stale nosecret badsuites badcmd)
WANT=("$@")
[[ ${#WANT[@]} -gt 0 ]] || WANT=("${ALL[@]}")

log() { printf '== dryrun: %s\n' "$*"; }
fail() { printf 'dryrun: FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

for c in python3 curl jq; do
  command -v "$c" >/dev/null || { printf 'dryrun: %s is required\n' "$c" >&2; exit 2; }
done

BASE="${INGAME_DRYRUN_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/ingame-dryrun.XXXXXX")}"
mkdir -p "$BASE"
cleanup_base() {
  if [[ "${KEEP:-0}" == 1 ]]; then
    log "kept: $BASE"
  else
    rm -rf "$BASE"
  fi
}
trap cleanup_base EXIT

BUILD_ID="dryrun-$(date -u +%Y%m%d%H%M%S)"
COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf '%040d' 0)"
TOKEN="mock-token-$RANDOM$RANDOM"

# A plugin folder and a build/dist that look like the real ones to ingame.sh.
# Nothing here is a real binary; ingame.sh only copies these files.
make_tree() { # make_tree <dir>
  local d="$1"
  mkdir -p "$d/plugin/lua" "$d/config/selftest" "$d/dist/lua"
  printf 'not a real assembly\n' >"$d/plugin/GhosttyDalamud.dll"
  printf 'not a real loader\n' >"$d/plugin/ghostty_loader.dll"
  printf '{}\n' >"$d/plugin/GhosttyDalamud.json"
  printf 'old core\n' >"$d/plugin/ghostty_core.dll"
  # an installed init.lua: it may hold the agent token, so ingame.sh must keep it
  printf -- '-- installed\nreturn { keep_me = true }\n' >"$d/plugin/lua/init.lua"
  printf 'new core %s\n' "$BUILD_ID" >"$d/dist/ghostty_core.dll"
  printf -- '-- shipped init.lua\nreturn {}\n' >"$d/dist/lua/init.lua"
  printf -- 'return {}\n' >"$d/dist/lua/themes.lua"
  jq -n --arg b "$BUILD_ID" --arg c "$COMMIT" \
    '{build_id: $b, commit: $c, built: "1970-01-01T00:00:00Z"}' >"$d/dist/build-info.json"
}

start_mock() { # start_mock <dir> <mode>; echoes the URL
  local d="$1" mode="$2"
  python3 "$ROOT/tools/ci/mock-xivmcp.py" \
    --plugin-dir "$d/plugin" --config-dir "$d/config" \
    --build-id "$BUILD_ID" --commit "$COMMIT" --token "$TOKEN" --mode "$mode" \
    --port-file "$d/port" --ready-file "$d/ready" >"$d/mock.log" 2>&1 &
  echo $! >"$d/mock.pid"
  local n=0
  while [[ ! -f "$d/ready" || ! -s "$d/port" ]]; do
    n=$((n + 1))
    ((n < 200)) || { printf 'dryrun: the mock did not start:\n' >&2; cat "$d/mock.log" >&2; return 1; }
    sleep 0.05
  done
  printf 'http://127.0.0.1:%s/mcp\n' "$(cat "$d/port")"
}

stop_mock() { # stop_mock <dir>
  local p
  p="$(cat "$1/mock.pid" 2>/dev/null || true)"
  [[ -n "$p" ]] && kill "$p" 2>/dev/null || true
  wait "$p" 2>/dev/null || true
}

# One scenario: set the environment ingame.sh reads, run it, report the status.
run_ingame() { # run_ingame <dir> <url> [env assignments...]; echoes the exit code
  local d="$1" url="$2"
  shift 2
  local rc=0
  (
    cd "$ROOT"
    env "$@" \
      XIVMCP_URL="$url" \
      GHOSTTY_DEV_PLUGIN_DIR="$d/plugin" \
      GHOSTTY_CONFIG_DIR="$d/config" \
      INGAME_DIST="$d/dist" \
      INGAME_OUT="$d/out" \
      INGAME_LOAD_TIMEOUT=20 \
      INGAME_RUN_TIMEOUT=30 \
      GITHUB_STEP_SUMMARY="$d/summary.md" \
      tools/ci/ingame.sh
  ) >"$d/ingame.log" 2>&1 || rc=$?
  echo "$rc"
}

expect() { # expect <scenario> <got> <want>
  if [[ "$2" == "$3" ]]; then
    log "$1: exit $2 as expected"
  else
    fail "$1: exit $2, expected $3"
    sed -n '1,60p' "$BASE/$1/ingame.log" >&2 || true
  fi
}

failures=0
for sc in "${WANT[@]}"; do
  d="$BASE/$sc"
  make_tree "$d"
  case "$sc" in
    pass | fail | nogame | noplayer | noswap | stale)
      url="$(start_mock "$d" "$sc")"
      rc="$(run_ingame "$d" "$url" "XIVMCP_CI_TOKEN=$TOKEN" INGAME_SUITES=all)"
      stop_mock "$d"
      case "$sc" in
        pass) want=0 ;;
        nogame | noplayer) want=3 ;;
        *) want=1 ;;
      esac
      expect "$sc" "$rc" "$want"
      if [[ "$sc" == pass ]]; then
        # the report must exist, name this build, and pass
        if ! jq -e --arg b "$BUILD_ID" \
          '.header.expected_build == $b and .selftest.ok == true and .selftest.summary.failed == 0
           and (.header.plugins | length) == 2 and (.header.xivmcp.name | length) > 0' \
          "$d/out/ingame-report.json" >/dev/null 2>&1; then
          fail "pass: build/ingame/ingame-report.json is not the report expected"
          cat "$d/out/ingame-report.json" >&2 2>/dev/null || true
        else
          log "pass: report ok ($(jq -r '.selftest.summary | "\(.passed) passed, \(.failed) failed, \(.skipped) skipped"' "$d/out/ingame-report.json"))"
        fi
        # the step summary must carry the table ingame.yml shows
        grep -q '^| suite | case | status | ms | message |$' "$d/summary.md" ||
          fail "pass: no case table in the step summary"
        # the installed lua/init.lua must have survived the swap
        grep -q keep_me "$d/plugin/lua/init.lua" ||
          fail "pass: the installed lua/init.lua was overwritten"
        # the managed assemblies must not have been touched
        grep -q 'not a real assembly' "$d/plugin/GhosttyDalamud.dll" ||
          fail "pass: GhosttyDalamud.dll was written; Dalamud would reload managed code"
        grep -q 'not a real loader' "$d/plugin/ghostty_loader.dll" ||
          fail "pass: ghostty_loader.dll was written"
      fi
      if [[ "$sc" == nogame || "$sc" == noplayer ]]; then
        grep -q 'skipped: game not available' "$d/ingame.log" ||
          fail "$sc: no 'skipped: game not available' line"
        grep -q 'skipped: game not available' "$d/summary.md" ||
          fail "$sc: the skip is not in the step summary"
      fi
      ;;
    nosecret)
      url="$(start_mock "$d" pass)"
      rc="$(run_ingame "$d" "$url" INGAME_SUITES=all XIVMCP_CI_TOKEN=)"
      stop_mock "$d"
      expect "$sc" "$rc" 2
      ;;
    badsuites)
      url="$(start_mock "$d" pass)"
      rc="$(run_ingame "$d" "$url" "XIVMCP_CI_TOKEN=$TOKEN" 'INGAME_SUITES=all; rm -rf /')"
      stop_mock "$d"
      expect "$sc" "$rc" 2
      ;;
    badcmd)
      # the mock must refuse anything but /term selftest: the allowlist the real
      # ghostty-ci client is given is the only thing standing between this token
      # and the rest of the game's commands
      url="$(start_mock "$d" pass)"
      sid="$(curl -sS -D - -o /dev/null -X POST -H "Authorization: Bearer $TOKEN" \
        -H 'Content-Type: application/json' \
        --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' "$url" |
        tr -d '\r' | awk -F': ' 'tolower($1) == "mcp-session-id" {print $2}' | tail -n1)"
      body="$(curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Mcp-Session-Id: $sid" \
        -H 'Content-Type: application/json' \
        --data '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"execute_command","arguments":{"command":"/echo hello"}}}' "$url")"
      if jq -e '.result.isError == true' >/dev/null <<<"$body"; then
        log "badcmd: refused as expected"
      else
        fail "badcmd: the mock allowed a command that is not /term selftest: $body"
      fi
      # and an unauthenticated request must be refused
      code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
        --data '{"jsonrpc":"2.0","id":3,"method":"initialize","params":{}}' "$url")"
      [[ "$code" == 401 ]] || fail "badcmd: an unauthenticated request got HTTP $code, expected 401"
      stop_mock "$d"
      ;;
    *)
      printf 'dryrun: unknown scenario: %s\n' "$sc" >&2
      exit 2
      ;;
  esac
done

if ((failures > 0)); then
  printf 'dryrun: %d scenario(s) failed\n' "$failures" >&2
  exit 1
fi
log "all ${#WANT[@]} scenario(s) behaved as expected"
