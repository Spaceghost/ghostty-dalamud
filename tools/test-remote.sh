#!/usr/bin/env bash
# Run the host tests in the remote build container and insist they passed.
#
#   tools/test-remote.sh [--build]
#
# It drives tools/build-remote.sh (see docs/REMOTE_BUILD.md): the worktree is
# sent to the container, `tools/ci/run.sh test` builds the host parts and runs
# tests/run.sh there, and this exits non-zero unless tests/run.sh reached
# "ALL OK" -- so "the tests ran" cannot be mistaken for "the tests passed".
# Needs no local toolchain and no game.
#
#   --build   after the tests, also build and bring build/dist/ back
#
# The environment is tools/build-remote.sh's; nothing is interpreted here.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || { echo "test-remote: run this inside a git worktree of the repository" >&2; exit 2; }
REMOTE_SH="$ROOT/tools/build-remote.sh"
[[ -x "$REMOTE_SH" ]] || { echo "test-remote: error: no executable $REMOTE_SH" >&2; exit 2; }

BUILD=0
case "${1:-}" in
  "") ;;
  --build) BUILD=1 ;;
  -h | --help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "test-remote: error: unknown argument: $1" >&2; exit 1 ;;
esac

out="$(mktemp)"
trap 'rm -f "$out"' EXIT
start=$SECONDS
set +e
"$REMOTE_SH" test 2>&1 | tee "$out"
status=${PIPESTATUS[0]}
set -e
[[ $status -eq 0 ]] || { echo "test-remote: error: the remote test run failed (exit $status)" >&2; exit "$status"; }
grep -q '^ALL OK' "$out" || { echo "test-remote: error: tests/run.sh did not print ALL OK" >&2; exit 1; }
echo "== test-remote: ALL OK in $((SECONDS - start))s"

if [[ "$BUILD" == 1 ]]; then
  "$REMOTE_SH" build
fi
