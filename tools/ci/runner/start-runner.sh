#!/usr/bin/env bash
# Start an ephemeral GitHub Actions runner container with rootless podman.
# Each container registers, runs one job and exits; --loop starts the next.
#
#   RUNNER_URL=https://github.com/OWNER/REPO \
#   RUNNER_TOKEN="$(gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token)" \
#     tools/ci/runner/start-runner.sh [--build] [--loop]
#
#   --build   build the image first (tools/ci/runner/Containerfile)
#   --loop    keep starting runners; set RUNNER_TOKEN_COMMAND so each one gets
#             a fresh token (a registration token expires after one hour)
#
# Environment:
#   RUNNER_URL            repository URL (required)
#   RUNNER_TOKEN          registration token, or
#   RUNNER_TOKEN_COMMAND  a command printing one, run before every container, e.g.
#                         'gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token'
#   RUNNER_LABELS         extra labels, comma separated (default ghostty-dalamud); the
#                         runner also carries self-hosted, Linux and X64/ARM64
#   RUNNER_NAME           default <host>-<random>
#   RUNNER_IMAGE          default localhost/ghostty-dalamud-runner:latest
#   RUNNER_CACHE_VOLUME   named volume kept across jobs at ~/.cache (toolchains,
#                         Zig caches); default ghostty-dalamud-runner-cache, empty = none
#   PODMAN                default podman
#   PODMAN_RUN_ARGS       extra `podman run` arguments, e.g. '--memory 8g --cpus 4'
#
# The token is handed to the container on stdin, never as an argument or an
# environment variable of the container, and is not written anywhere.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PODMAN="${PODMAN:-podman}"
IMAGE="${RUNNER_IMAGE:-localhost/ghostty-dalamud-runner:latest}"
VOLUME="${RUNNER_CACHE_VOLUME-ghostty-dalamud-runner-cache}"
build=0 loop=0
for a in "$@"; do
  case "$a" in
    --build) build=1 ;;
    --loop) loop=1 ;;
    -h | --help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

: "${RUNNER_URL:?set RUNNER_URL=https://github.com/OWNER/REPO}"

if [[ $build == 1 ]]; then
  "$PODMAN" build -t "$IMAGE" -f "$HERE/Containerfile" "$HERE"
fi

token() {
  if [[ -n "${RUNNER_TOKEN_COMMAND:-}" ]]; then
    bash -c "$RUNNER_TOKEN_COMMAND"
  elif [[ -n "${RUNNER_TOKEN:-}" ]]; then
    printf '%s\n' "$RUNNER_TOKEN"
  else
    echo "set RUNNER_TOKEN or RUNNER_TOKEN_COMMAND" >&2
    return 1
  fi
}

run_one() {
  local name="${RUNNER_NAME:-$(hostname -s)-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')}"
  local args=(run --rm -i --name "$name" --hostname "$name"
    -e RUNNER_URL="$RUNNER_URL" -e RUNNER_NAME="$name" -e RUNNER_LABELS="${RUNNER_LABELS:-ghostty-dalamud}")
  [[ -n "$VOLUME" ]] && args+=(-v "$VOLUME:/home/runner/.cache:U")
  # shellcheck disable=SC2206  # PODMAN_RUN_ARGS is meant to split into words
  [[ -n "${PODMAN_RUN_ARGS:-}" ]] && args+=(${PODMAN_RUN_ARGS})
  local t
  t="$(token)"
  [[ -n "$t" ]] || { echo "empty registration token" >&2; return 1; }
  printf '%s\n' "$t" | "$PODMAN" "${args[@]}" "$IMAGE"
}

if [[ $loop == 0 ]]; then
  run_one
  exit
fi
[[ -n "${RUNNER_TOKEN_COMMAND:-}" ]] || echo "warning: --loop without RUNNER_TOKEN_COMMAND stops working when RUNNER_TOKEN expires (1 hour)" >&2
while true; do
  run_one || { echo "runner exited with $?; retrying in 30 s" >&2; sleep 30; }
done
