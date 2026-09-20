#!/usr/bin/env bash
# Container entrypoint: register an ephemeral runner, run one job, exit.
# The runner deregisters itself after that job.
#
#   RUNNER_URL     https://github.com/OWNER/REPO (required)
#   RUNNER_LABELS  extra labels, comma separated (default: ghostty-dalamud)
#   RUNNER_NAME    default: the container's hostname
#   RUNNER_TOKEN   registration token; when unset, read from the first line of
#                  stdin (start-runner.sh passes it that way, so it never shows
#                  up in the container's environment or `podman inspect`)
set -euo pipefail
: "${RUNNER_URL:?set RUNNER_URL=https://github.com/OWNER/REPO}"
token="${RUNNER_TOKEN:-}"
unset RUNNER_TOKEN
if [[ -z "$token" ]]; then
  IFS= read -r token || true
fi
[[ -n "$token" ]] || { echo "no registration token (RUNNER_TOKEN or stdin)" >&2; exit 2; }

cd "$HOME/actions-runner"
./config.sh --unattended --ephemeral --disableupdate --replace \
  --url "$RUNNER_URL" --token "$token" \
  --name "${RUNNER_NAME:-$(hostname)}" \
  --labels "${RUNNER_LABELS:-ghostty-dalamud}" \
  --work "$HOME/_work"
unset token
exec ./run.sh </dev/null
