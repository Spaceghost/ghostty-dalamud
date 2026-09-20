#!/usr/bin/env bash
# Run a build/test command wherever it belongs, and move it if the game starts.
#
#   tools/run-placed.sh --name test --local 'tests/run.sh' \
#                       --remote 'tools/test-remote.sh'
#   tools/run-placed.sh --name lint -- ./scripts/lint --all
#
#   tools/run-placed.sh jobs            recent jobs, newest first
#   tools/run-placed.sh show <id>       one job's record
#   tools/run-placed.sh log <id>        its output (`log latest -f` follows)
#   tools/run-placed.sh resume <id>     re-dispatch an evicted job to the build
#                                       host (the guard does this by itself)
#   tools/run-placed.sh where           the placement decision for this project
#
# tools/where-build.sh decides. When it says `local` the command runs here, in
# a process group of its own, and is recorded as a job; when the game starts,
# tools/ffxiv-guard.sh kills that process group and this wrapper re-dispatches
# the same job to the build host. The caller sees one exit status and gets the
# artifacts either way, so a build interrupted by a game launch looks to its
# caller like a build that took longer.
#
# Options:
#   --name NAME        job name (default: the command's first word)
#   --project DIR      project root (default: the git worktree of $PWD)
#   --local 'CMD'      shell command to run here
#   --remote 'CMD'     shell command, run HERE, that dispatches the same work
#                      to the build host (e.g. tools/build-remote.sh). Without
#                      one, the generic container path below is used.
#   --pull 'PATHS'     generic path only: paths under the project to bring back
#   --local-only       this work belongs on this machine (installing into the
#                      game, the agent, git): never routed away, never evicted
#   -- ARGV...         the local command as argv instead of --local
#
# Per-project settings come from the project's `.build-placement`, else
# ${XDG_CONFIG_HOME:-~/.config}/build-placement/projects/<name>.env:
#
#   PLACE_REMOTE_DISPATCH='tools/build-remote.sh'   # optional
#   PLACE_CONTAINER=ghostty-build                   # generic path
#   PLACE_REMOTE_DIR=/build/<project>
#   PLACE_PULL='build/dist'
#   PLACE_REMOTE_SETUP='dnf -y install ...'         # run once per push
#
# Environment: FORCE_BUILD_HOST and everything tools/where-build.sh reads,
# plus BUILD_REMOTE (Incus remote, default BUILD_REMOTE_NAME), INCUS,
# BUILD_PLACEMENT=0 to run the local command with no placement at all, and
# BUILD_PLACEMENT_STATE (default ~/.local/state/ghostty-build).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${BUILD_PLACEMENT_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/ghostty-build}"
JOBS="$STATE/jobs"
INCUS="${INCUS:-incus}"
[[ -f "$HERE/../build.env" ]] && source "$HERE/../build.env"  # this machine's remote name
BUILD_REMOTE="${BUILD_REMOTE:-${INCUS_REMOTE:-${BUILD_REMOTE_NAME:-build}}}"

log() { printf '== placed: %s\n' "$*"; }
die() { printf 'run-placed: error: %s\n' "$*" >&2; exit 2; }
usage() { sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------- job records

# A job is a directory of small files. Nothing here needs jq, a daemon or a
# database: `cat`, `grep` and `kill` are the whole debugging toolkit.
meta_set() { # meta_set DIR KEY VALUE
  local d="$1" k="$2" v="$3" t
  t="$(mktemp "$d/.meta.XXXXXX")"
  grep -v "^$k=" "$d/meta" 2>/dev/null >"$t" || true
  printf '%s=%s\n' "$k" "$v" >>"$t"
  mv "$t" "$d/meta"
}
meta_get() { # meta_get DIR KEY
  sed -n "s/^$2=//p" "$1/meta" 2>/dev/null | tail -1
}
job_dir() { # job_dir ID  (accepts `latest`)
  local id="$1"
  [[ "$id" == latest ]] && id="$(cat "$JOBS/latest" 2>/dev/null || true)"
  [[ -n "$id" && -d "$JOBS/$id" ]] || die "no such job: $1"
  printf '%s\n' "$JOBS/$id"
}

new_job() { # new_job NAME -> prints the directory
  local name="$1" id
  id="$name-$(date -u +%Y%m%dT%H%M%SZ)-$(tr -dc a-f0-9 </dev/urandom | head -c4)"
  mkdir -p "$JOBS/$id"
  printf '%s' "$id" >"$JOBS/latest"
  printf '%s\n' "$JOBS/$id"
}

# ------------------------------------------------------------- project config

load_project() {
  PROJECT="${PROJECT:-}"
  if [[ -z "$PROJECT" ]]; then
    PROJECT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [[ -n "$PROJECT" ]] || PROJECT="$PWD"
  fi
  PROJECT="$(cd "$PROJECT" && pwd)"
  PROJECT_NAME="$(basename "$PROJECT")"
  PLACE_REMOTE_DISPATCH=""
  PLACE_CONTAINER="ghostty-build"
  PLACE_REMOTE_DIR=""
  PLACE_PULL=""
  PLACE_REMOTE_SETUP=""
  local cfg
  for cfg in "$PROJECT/.build-placement" \
             "${XDG_CONFIG_HOME:-$HOME/.config}/build-placement/projects/$PROJECT_NAME.env"; do
    if [[ -f "$cfg" ]]; then
      # shellcheck disable=SC1090
      source "$cfg"
      break
    fi
  done
  PLACE_REMOTE_DIR="${PLACE_REMOTE_DIR:-/build/$PROJECT_NAME}"
}

# ------------------------------------------------------------- the two paths

run_local() { # run_local DIR CMD -> exit status of CMD
  local d="$1" cmd="$2" rc=0
  meta_set "$d" host local
  meta_set "$d" state running
  log "on this machine: $cmd"
  # Its own session, so the guard can stop the whole tree with one signal and
  # can never reach this wrapper, the shell that called it, or the game.
  set +e
  PLACED_CMD="$cmd" PLACED_PGID_FILE="$d/pgid" PLACED_DIR="$PROJECT" \
  BUILD_PLACEMENT=0 \
    setsid --wait bash -c 'echo $$ >"$PLACED_PGID_FILE"; cd "$PLACED_DIR"; exec bash -c "$PLACED_CMD"'
  rc=$?
  set -e
  rm -f "$d/pgid"
  return "$rc"
}

# Everything that talks to the build host. Either the project's own dispatcher
# (ghostty-dalamud has tools/build-remote.sh) or the generic container path.
run_remote() { # run_remote DIR CMD -> exit status
  local d="$1" cmd="$2" rc=0
  meta_set "$d" host remote
  meta_set "$d" state running
  if [[ -n "$cmd" ]]; then
    log "dispatching to $BUILD_REMOTE: $cmd"
    set +e
    ( cd "$PROJECT" && BUILD_PLACEMENT=0 FORCE_BUILD_HOST=remote bash -c "$cmd" )
    rc=$?
    set -e
  else
    set +e
    generic_remote "$d"
    rc=$?
    set -e
  fi
  return "$rc"
}

# The generic path: push the worktree into a container on the build host, run
# the command there under the shared build lock, bring the named paths back.
# This is what a project without its own build-remote.sh gets.
generic_remote() {
  local d="$1"
  local C="$BUILD_REMOTE:$PLACE_CONTAINER" D="$PLACE_REMOTE_DIR"
  command -v "$INCUS" >/dev/null || { echo "run-placed: no incus client" >&2; return 4; }
  "$INCUS" info "$C" >/dev/null 2>&1 || { echo "run-placed: no container $C" >&2; return 4; }
  if [[ "$("$INCUS" info "$C" | awk '/^Status:/{print tolower($2)}')" != running ]]; then
    "$INCUS" start "$C"; sleep 3
  fi
  log "sending $PROJECT to $C:$D"
  local list; list="$(mktemp)"
  if git -C "$PROJECT" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$PROJECT" ls-files -z --cached --others --exclude-standard >"$list"
  else
    ( cd "$PROJECT" && find . -mindepth 1 -not -path './.git/*' -type f -print0 ) >"$list"
  fi
  "$INCUS" exec "$C" -- bash -c "mkdir -p $D && find $D -mindepth 1 -maxdepth 1 ! -name build ! -name node_modules ! -name obj -exec rm -rf {} +"
  tar -C "$PROJECT" --null -T "$list" -czf - | "$INCUS" exec "$C" -- tar -xzf - -C "$D"
  rm -f "$list"
  if [[ -n "$PLACE_REMOTE_SETUP" ]]; then "$INCUS" exec "$C" -- bash -lc "$PLACE_REMOTE_SETUP"; fi
  local cmd; cmd="$(meta_get "$d" local_cmd)"
  log "running in $C: $cmd"
  # flock -o: the lock fd is closed before the command runs, so a build daemon
  # the command starts (sccache, VBCSCompiler) cannot inherit and hold it.
  # flock -w: never wait forever for another build.
  local rc=0
  set +e
  "$INCUS" exec "$C" --env HOME=/root --env BUILD_PLACEMENT=0 --env XDG_RUNTIME_DIR=/run/user/0 -- \
    bash -lc "mkdir -p /run/user/0; cd $D && flock -o -w ${PLACE_LOCK_WAIT:-7200} /tmp/$PROJECT_NAME.build.lock -c $(printf '%q' "$cmd")"
  rc=$?
  set -e
  local p
  for p in $PLACE_PULL; do
    log "fetching $p"
    mkdir -p "$PROJECT/$(dirname "$p")"
    "$INCUS" exec "$C" -- tar -C "$D" -cf - "$p" 2>/dev/null | tar -xf - -C "$PROJECT" || true
  done
  return "$rc"
}

# --------------------------------------------------------------- the wrapper

dispatch() { # dispatch DIR — remote path, recording the outcome
  local d="$1" rc=0
  run_remote "$d" "$REMOTE_CMD" || rc=$?
  meta_set "$d" state "done"
  meta_set "$d" exit "$rc"
  meta_set "$d" ended "$(date -uIs)"
  printf '%s' "$rc" >"$d/status"
  return "$rc"
}

cmd_run() {
  load_project
  [[ -n "$LOCAL_CMD" ]] || die "nothing to run (--local or -- ARGV)"
  [[ -n "$REMOTE_CMD" ]] || REMOTE_CMD="$PLACE_REMOTE_DISPATCH"
  if [[ -n "$PULL_OVERRIDE" ]]; then PLACE_PULL="$PULL_OVERRIDE"; fi
  NAME="${NAME:-$(basename "${LOCAL_CMD%% *}")}"
  NAME="${NAME//[^A-Za-z0-9_.-]/_}"

  local d; d="$(new_job "$NAME")"
  : >"$d/log"
  meta_set "$d" id "$(basename "$d")"
  meta_set "$d" name "$NAME"
  meta_set "$d" project "$PROJECT"
  meta_set "$d" local_cmd "$LOCAL_CMD"
  meta_set "$d" remote_cmd "$REMOTE_CMD"
  meta_set "$d" pull "$PLACE_PULL"
  # FORCE_BUILD_HOST=local is a human saying "here, I mean it": not evicted.
  if [[ "${FORCE_BUILD_HOST:-}" == local ]]; then LOCAL_ONLY_EFFECTIVE=1; else LOCAL_ONLY_EFFECTIVE="$LOCAL_ONLY"; fi
  meta_set "$d" local_only "$LOCAL_ONLY_EFFECTIVE"
  meta_set "$d" wrapper_pid "$$"
  meta_set "$d" started "$(date -uIs)"
  meta_set "$d" state starting

  # Everything from here on is both on the terminal and in the job log.
  exec 3>&1 4>&2
  exec > >(tee -a "$d/log") 2>&1
  local tee_pid=$!
  # On exit: give tee its EOF first, then wait for it, or the wait never ends.
  # shellcheck disable=SC2064
  trap "exec 1>&3 2>&4; wait $tee_pid 2>/dev/null || true" EXIT

  log "job $(basename "$d")"

  local host rc=0
  if [[ "$LOCAL_ONLY" == 1 ]]; then
    host=local
    log "--local-only: this work stays on this machine"
  else
    # stdout is the host, stderr is the reason: never interleaved.
    local why; why="$(mktemp)"
    set +e
    host="$("$HERE/where-build.sh" --why 2>"$why")"
    rc=$?
    set -e
    cat "$why" >&2
    local reason; reason="$(sed 's/^where-build: //' "$why" | tail -1)"
    rm -f "$why"
    if [[ "$rc" == 3 ]]; then
      meta_set "$d" state refused
      meta_set "$d" reason "$reason"
      meta_set "$d" exit 3
      printf '3' >"$d/status"
      return 3
    fi
    meta_set "$d" reason "$reason"
  fi

  if [[ "$host" == remote ]]; then
    dispatch "$d"
    return $?
  fi

  rc=0
  run_local "$d" "$LOCAL_CMD" || rc=$?

  # Evicted? The guard wrote the marker before it signalled, so this is not a
  # guess about what a 143 means.
  if [[ "$LOCAL_ONLY" != 1 && -f "$d/evict" ]]; then
    log "evicted after $(cat "$d/evict"): re-dispatching to $BUILD_REMOTE"
    meta_set "$d" evicted 1
    rm -f "$d/evict"
    dispatch "$d"
    return $?
  fi

  meta_set "$d" state "done"
  meta_set "$d" exit "$rc"
  meta_set "$d" ended "$(date -uIs)"
  printf '%s' "$rc" >"$d/status"
  return "$rc"
}

cmd_resume() { # the guard's fallback when the wrapper itself is gone
  local d; d="$(job_dir "$1")"
  PROJECT="$(meta_get "$d" project)"
  load_project
  REMOTE_CMD="$(meta_get "$d" remote_cmd)"
  PLACE_PULL="$(meta_get "$d" pull)"
  rm -f "$d/evict"
  meta_set "$d" evicted 1
  exec >>"$d/log" 2>&1
  log "resume $(basename "$d") on $BUILD_REMOTE"
  dispatch "$d"
}

cmd_jobs() {
  [[ -d "$JOBS" ]] || { echo "no jobs yet ($JOBS)"; return 0; }
  printf '%-40s %-7s %-8s %-6s %s\n' ID HOST STATE EXIT NAME
  local d
  while IFS= read -r d; do
    [[ -f "$d/meta" ]] || continue
    printf '%-40s %-7s %-8s %-6s %s\n' \
      "$(basename "$d")" "$(meta_get "$d" host)" "$(meta_get "$d" state)" \
      "$(meta_get "$d" exit)" "$(meta_get "$d" name)$([[ "$(meta_get "$d" evicted)" == 1 ]] && echo ' (evicted)')"
  done < <(find "$JOBS" -mindepth 1 -maxdepth 1 -type d | sort -r | head -"${1:-20}")
}

# ------------------------------------------------------------------ dispatch

NAME=""; PROJECT=""; LOCAL_CMD=""; REMOTE_CMD=""; PULL_OVERRIDE=""; LOCAL_ONLY=0
case "${1:-}" in
  jobs | list) shift; mkdir -p "$JOBS"; cmd_jobs "$@"; exit 0 ;;
  show) shift; cat "$(job_dir "${1:?job id}")/meta"; exit 0 ;;
  log)
    shift; d="$(job_dir "${1:?job id}")"; shift || true
    if [[ $# -eq 0 ]]; then cat "$d/log"; else tail "$@" "$d/log"; fi; exit 0 ;;
  resume) shift; mkdir -p "$JOBS"; cmd_resume "${1:?job id}"; exit $? ;;
  where) shift; load_project; exec "$HERE/where-build.sh" "${1:---why}" ;;
  -h | --help) usage; exit 0 ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --local) LOCAL_CMD="$2"; shift 2 ;;
    --remote) REMOTE_CMD="$2"; shift 2 ;;
    --pull) PULL_OVERRIDE="$2"; shift 2 ;;
    --local-only) LOCAL_ONLY=1; shift ;;
    --) shift; LOCAL_CMD="$(printf '%q ' "$@")"; break ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

mkdir -p "$JOBS"

# BUILD_PLACEMENT=0 means "you are already where you belong" — inside the build
# container, under CI, or under a wrapper that has already decided.
if [[ "${BUILD_PLACEMENT:-1}" == 0 ]]; then
  load_project
  cd "$PROJECT"
  exec bash -c "$LOCAL_CMD"
fi

cmd_run
