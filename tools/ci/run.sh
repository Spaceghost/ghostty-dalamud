#!/usr/bin/env bash
# The one CI entry point: GitHub Actions, self-hosted runners and a local shell
# all run this.
#
#   tools/ci/run.sh <stage>...      stages: deps test build package all ingame
#                                           ingame-dryrun lint fuzz static massif
#
#   deps     pinned Zig, pinned Dalamud reference assemblies, tools/fetch-vendor.sh
#   test     host parts of tools/build.sh (Nelua, libghostty-vt, Lua), then tests/run.sh
#   build    tools/build.sh -> build/dist/
#   package  tools/package.sh when the checkout has one; its .zip and
#            pluginmaster .json files are collected into build/release/
#   all      deps test build package
#   lint     shellcheck over every shell script, luacheck over lua/ and
#            tests/*.lua (.luacheckrc), actionlint over .github/workflows
#   fuzz     the host parts, then tools/ci/fuzz.sh (time-boxed, sanitizers on)
#   static   tools/ci/static.sh: warning budget, cppcheck, clang --analyze, clang-tidy
#   massif   the host parts, then tools/ci/massif.sh (a heap profile in build/massif)
#   SAN=asan,ubsan with the test stage runs tests/run.sh under sanitizers
#   ingame   tools/ci/ingame.sh: the built core into the running game through the
#            loader's hot swap, `/term selftest all` through XivMcp, the report
#            in build/ingame/ (exit 3: skipped, game not available). Only on the
#            gaming PC's runner; never part of `all`
#   ingame-dryrun
#            tools/ci/ingame-dryrun.sh: the same script against a stand-in for
#            XivMcp and the game (tools/ci/mock-xivmcp.py). No build, no game,
#            no secret, no network: this is what ordinary CI runs so the
#            in-game path keeps working between the rare real runs
#
# Configured only by the environment (see docs/CI.md):
#   ZIG, DOTNET              binaries; unset = PATH, else fetched (Zig) or ~/.dotnet (dotnet)
#   DALAMUD_LIB_PATH         Dalamud reference assemblies; unset = the pinned
#                            dalamud-distrib zip, fetched into the cache
#   UMBRA_LIB_PATH           Umbra reference assemblies; unset = vendor/umbra-dist/dist
#   SKIP_SHIM, SKIP_UMBRA, SKIP_WIN, SKIP_DEPS   as for tools/build.sh
#   CI_CACHE_DIR             download cache, default ${XDG_CACHE_HOME:-~/.cache}/ghostty-dalamud-ci
#
# Every download is pinned in toolchain.env and checked against its sha256.
# Only the ingame stage needs a secret (XIVMCP_CI_TOKEN, docs/CI.md).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/toolchain.env"
cd "$ROOT"

CACHE="${CI_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ghostty-dalamud-ci}"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/zig-global}"
# CI runs where it was scheduled: never route a stage somewhere else from here
# (docs/BUILD_PLACEMENT.md).
export BUILD_PLACEMENT=0
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1

log() { printf '== ci: %s\n' "$*"; }
die() { printf 'ci: error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "$1 is required"; }

usage() { sed -n '2,39p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# fetch URL to FILE and check its sha256; the file only appears when it matches
fetch_checked() { # url sha256 file
  local tmp="$3.part"
  need curl; need sha256sum
  curl -fsSL --retry 3 --retry-delay 5 -o "$tmp" "$1"
  if ! echo "$2  $tmp" | sha256sum -c --status -; then
    rm -f "$tmp"
    die "checksum mismatch for $1 (expected $2); update the pin in toolchain.env if upstream changed on purpose"
  fi
  mv -f "$tmp" "$3"
}

ensure_zig() {
  if [[ -n "${ZIG:-}" ]]; then
    command -v "$ZIG" >/dev/null || die "ZIG=$ZIG is not executable"
  elif command -v zig >/dev/null && [[ "$(zig version)" == "$ZIG_VERSION" ]]; then
    ZIG="$(command -v zig)"
  else
    local arch sha
    case "$(uname -m)" in
      x86_64) arch=x86_64; sha="$ZIG_SHA256_X86_64_LINUX" ;;
      aarch64 | arm64) arch=aarch64; sha="$ZIG_SHA256_AARCH64_LINUX" ;;
      *) die "no pinned Zig for $(uname -m); set ZIG=/path/to/zig $ZIG_VERSION" ;;
    esac
    local name="zig-$arch-linux-$ZIG_VERSION" dir="$CACHE/zig"
    if [[ ! -x "$dir/$name/zig" ]]; then
      log "fetching $name"
      need tar; need xz
      mkdir -p "$dir"
      fetch_checked "$ZIG_URL_BASE/$ZIG_VERSION/$name.tar.xz" "$sha" "$dir/$name.tar.xz"
      rm -rf "${dir:?}/$name"
      tar -xJf "$dir/$name.tar.xz" -C "$dir"
      rm -f "$dir/$name.tar.xz"
    fi
    ZIG="$dir/$name/zig"
  fi
  export ZIG
  log "zig $("$ZIG" version) ($ZIG)"
}

ensure_dotnet() {
  [[ "${SKIP_SHIM:-0}" == 1 ]] && return 0
  if [[ -z "${DOTNET:-}" ]]; then
    if command -v dotnet >/dev/null; then DOTNET="$(command -v dotnet)"
    elif [[ -x "$HOME/.dotnet/dotnet" ]]; then DOTNET="$HOME/.dotnet/dotnet"
    else die "the .NET $DOTNET_CHANNEL SDK is required (set DOTNET=/path/to/dotnet, or SKIP_SHIM=1)"
    fi
  fi
  "$DOTNET" --list-sdks | grep -q "^${DOTNET_CHANNEL}\." ||
    die "$DOTNET has no .NET $DOTNET_CHANNEL SDK ($("$DOTNET" --list-sdks | tr '\n' ' '))"
  export DOTNET
  log "dotnet $("$DOTNET" --version) ($DOTNET)"
}

ensure_dalamud() {
  if [[ -n "${DALAMUD_LIB_PATH:-}" ]]; then
    [[ "${SKIP_SHIM:-0}" == 1 || -f "$DALAMUD_LIB_PATH/Dalamud.dll" ]] || die "no Dalamud.dll in DALAMUD_LIB_PATH=$DALAMUD_LIB_PATH"
  else
    local dir="$CACHE/dalamud-api$DALAMUD_API_LEVEL-${DALAMUD_DISTRIB_COMMIT:0:12}"
    if [[ ! -f "$dir/Dalamud.dll" ]]; then
      local base="https://raw.githubusercontent.com/goatcorp/dalamud-distrib/$DALAMUD_DISTRIB_COMMIT"
      log "fetching Dalamud reference assemblies (dalamud-distrib ${DALAMUD_DISTRIB_COMMIT:0:12})"
      need python3
      mkdir -p "$CACHE"
      rm -rf "$dir.tmp" && mkdir -p "$dir.tmp"
      fetch_checked "$base/latest.zip" "$DALAMUD_DISTRIB_SHA256" "$dir.tmp/latest.zip"
      python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$dir.tmp/latest.zip" "$dir.tmp"
      rm -f "$dir.tmp/latest.zip"
      # the version file is informational; the zip's checksum is what pins it
      local ver
      ver="$(curl -fsSL --retry 3 "$base/version" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AssemblyVersion"])')"
      [[ "${ver%%.*}" == "$DALAMUD_API_LEVEL" ]] || die "pinned Dalamud is $ver, toolchain.env expects API $DALAMUD_API_LEVEL"
      echo "$ver" >"$dir.tmp/ci-version.txt"
      [[ -f "$dir.tmp/Dalamud.dll" ]] || die "no Dalamud.dll in the pinned dalamud-distrib zip"
      rm -rf "$dir" && mv "$dir.tmp" "$dir"
    fi
    DALAMUD_LIB_PATH="$dir"
  fi
  export DALAMUD_LIB_PATH
  log "dalamud reference assemblies $(cat "$DALAMUD_LIB_PATH/ci-version.txt" 2>/dev/null || echo '(version unknown)') in $DALAMUD_LIB_PATH"
}

ensure_umbra() {
  [[ "${SKIP_SHIM:-0}" == 1 || "${SKIP_UMBRA:-0}" == 1 ]] && return 0
  local dir="${UMBRA_LIB_PATH:-$ROOT/vendor/umbra-dist/dist}"
  if [[ -f "$dir/Umbra.dll" ]]; then
    log "umbra reference assemblies in $dir"
  else
    log "no Umbra.dll in $dir: building without the Umbra widget (SKIP_UMBRA=1)"
    export SKIP_UMBRA=1
  fi
}

fetch_vendor() {
  # DALAMUD_LIB_PATH is exported, so fetch-vendor.sh reuses the pinned copy
  "$ROOT/tools/fetch-vendor.sh"
}

stage_deps() {
  ensure_zig
  ensure_dotnet
  ensure_dalamud
  fetch_vendor
  ensure_umbra
}

stage_test() {
  # cheap and first: CHANGELOG.md is generated from lua/changelog.lua
  log "tools/changelog.py --check"
  need python3
  python3 "$ROOT/tools/changelog.py" --check
  if [[ "${SKIP_DEPS:-0}" != 1 ]]; then
    ensure_zig
    ensure_dalamud # fetch-vendor.sh wants a Dalamud directory; it is cached
    fetch_vendor
    log "host dependencies (tools/build.sh with SKIP_WIN=1 SKIP_SHIM=1)"
    SKIP_WIN=1 SKIP_SHIM=1 "$ROOT/tools/build.sh"
  fi
  log "tests/run.sh"
  "$ROOT/tests/run.sh"
}

host_parts() {
  ensure_zig
  ensure_dalamud
  fetch_vendor
  SKIP_WIN=1 SKIP_SHIM=1 "$ROOT/tools/build.sh"
}

stage_fuzz() {
  [[ "${SKIP_DEPS:-0}" == 1 ]] || host_parts
  "$ROOT/tools/ci/fuzz.sh"
}

stage_static() {
  [[ "${SKIP_DEPS:-0}" == 1 ]] || { ensure_dalamud; fetch_vendor; }
  "$ROOT/tools/ci/static.sh"
}

stage_massif() {
  [[ "${SKIP_DEPS:-0}" == 1 ]] || host_parts
  "$ROOT/tools/ci/massif.sh"
}

stage_lint() {
  need shellcheck; need luacheck
  log "shellcheck"
  git ls-files -z '*.sh' | xargs -0 -r shellcheck -x
  log "luacheck"
  luacheck -q lua tests
  if command -v actionlint >/dev/null; then log "actionlint"; actionlint; else log "actionlint not installed: skipped"; fi
}

stage_build() {
  stage_deps
  log "tools/build.sh"
  "$ROOT/tools/build.sh"
}

stage_ingame() {
  log "tools/ci/ingame.sh"
  "$ROOT/tools/ci/ingame.sh"
}

stage_ingame_dryrun() {
  log "tools/ci/ingame-dryrun.sh"
  "$ROOT/tools/ci/ingame-dryrun.sh"
}

stage_package() {
  local out="$ROOT/build/release"
  if [[ ! -x "$ROOT/tools/package.sh" ]]; then
    log "tools/package.sh not in this checkout: nothing to package"
    return 0
  fi
  [[ -d "$ROOT/build/dist" ]] || die "no build/dist; run the build stage first"
  local mark
  mark="$(mktemp)"
  log "tools/package.sh"
  "$ROOT/tools/package.sh"
  rm -rf "$out" && mkdir -p "$out"
  # whatever package.sh wrote under build/ this run: the plugin zip and the pluginmaster JSON
  find "$ROOT/build" -path "$out" -prune -o -type f -newer "$mark" \
    \( -name '*.zip' -o -name 'pluginmaster*.json' -o -name 'repo.json' \) -print0 |
    xargs -0 -r cp -t "$out"
  rm -f "$mark"
  compgen -G "$out/*.zip" >/dev/null || die "tools/package.sh produced no .zip under build/"
  log "release files in build/release:"
  ls -la "$out"
}

[[ $# -gt 0 ]] || { usage; exit 2; }
for s in "$@"; do
  case "$s" in
    deps | test | build | package | all | ingame | ingame-dryrun | lint | fuzz | static | massif) ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown stage: $s" ;;
  esac
done
for s in "$@"; do
  case "$s" in
    deps) stage_deps ;;
    test) stage_test ;;
    build) stage_build ;;
    package) stage_package ;;
    ingame) stage_ingame ;;
    ingame-dryrun) stage_ingame_dryrun ;;
    lint) stage_lint ;;
    fuzz) stage_fuzz ;;
    static) stage_static ;;
    massif) stage_massif ;;
    all) stage_test; stage_build; stage_package ;;
  esac
done
log "done: $*"
