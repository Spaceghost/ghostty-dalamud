#!/usr/bin/env bash
# Run exactly what CI runs, from a local shell, without spending a GitHub
# Actions minute and without asking anyone to watch it.
#
#   tools/ci/local.sh [stage...]        default: test build
#
# Stages are tools/ci/run.sh's: deps test build package all ingame ingame-dryrun.
#
# Where it runs, in this order:
#
#   1. the Incus build container on the BUILD_REMOTE_NAME remote, through
#      tools/build-remote.sh, when this checkout has that script and an Incus
#      remote to reach. That is the default because the gaming PC runs the game:
#      a full build here competes with it for memory and gets killed.
#   2. this machine, tools/ci/run.sh directly, when there is no remote (or
#      CI_LOCAL_REMOTE=0), or for a stage that only makes sense here.
#
# Stages that are always local, because they are about this machine:
#   ingame          needs the running game and XivMcp on this host
#   ingame-dryrun   costs nothing and needs no toolchain
#
# Environment:
#   CI_LOCAL_REMOTE=0   never use the remote; run everything here
#   CI_LOCAL_REMOTE=1   insist on the remote; fail instead of falling back
#   INCUS_REMOTE        which Incus remote (tools/build-remote.sh's default is
#                       the BUILD_REMOTE_NAME remote when `incus remote list` has it)
#   everything tools/ci/run.sh and tools/build-remote.sh read
#
# This is the entry point to reach for; CI calls tools/ci/run.sh directly with
# the same stage names, so what you see here is what CI sees. docs/CI.md.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

log() { printf '== local: %s\n' "$*"; }
die() { printf 'local: error: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  -h | --help) sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

STAGES=("$@")
[[ ${#STAGES[@]} -gt 0 ]] || STAGES=(test build)
for s in "${STAGES[@]}"; do
  case "$s" in
    deps | test | build | package | all | ingame | ingame-dryrun) ;;
    *) die "unknown stage: $s (see tools/ci/run.sh --help)" ;;
  esac
done

REMOTE_SH="$ROOT/tools/build-remote.sh"

# Is there a remote to build on? tools/build-remote.sh owns the details; this
# only decides whether to hand over to it.
have_remote() {
  [[ "${CI_LOCAL_REMOTE:-}" == 0 ]] && return 1
  [[ -x "$REMOTE_SH" ]] || return 1
  [[ -n "${INCUS_REMOTE:-}" ]] && return 0
  command -v "${INCUS:-incus}" >/dev/null || return 1
  # shellcheck source=/dev/null  # build.env is untracked and optional
  [[ -f "$ROOT/build.env" ]] && source "$ROOT/build.env"
  "${INCUS:-incus}" remote list --format csv 2>/dev/null | cut -d, -f1 | grep -qx "${BUILD_REMOTE_NAME:-build}"
}

if have_remote; then
  where=remote
elif [[ "${CI_LOCAL_REMOTE:-}" == 1 ]]; then
  die "CI_LOCAL_REMOTE=1 but there is no usable remote: tools/build-remote.sh is $([[ -x "$REMOTE_SH" ]] && echo present || echo missing) and no Incus remote answered"
else
  where=local
  log "no Incus remote (or CI_LOCAL_REMOTE=0): running here. A full build wants
  several GB of memory; if the game is running, expect it to be killed."
fi

for s in "${STAGES[@]}"; do
  case "$s" in
    ingame | ingame-dryrun)
      log "$s here (it is about this machine)"
      "$ROOT/tools/ci/run.sh" "$s"
      ;;
    *)
      if [[ "$where" == remote ]]; then
        log "$s on the Incus build container (tools/build-remote.sh)"
        case "$s" in
          # tools/build-remote.sh speaks test/build/all itself and brings
          # build/dist back; anything else goes through its shell
          test | build | all) "$REMOTE_SH" "$s" ;;
          *) "$REMOTE_SH" push && "$REMOTE_SH" shell -- "tools/ci/run.sh $s" ;;
        esac
      else
        log "$s here (tools/ci/run.sh)"
        "$ROOT/tools/ci/run.sh" "$s"
      fi
      ;;
  esac
done
log "done: ${STAGES[*]}"
