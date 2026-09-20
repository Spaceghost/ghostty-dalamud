#!/usr/bin/env bash
# Run a command in a Fedora 44 container on a GitHub-hosted runner, with this
# checkout mounted: the static-analysis counts in tests/static-budget.txt were
# taken with Fedora's gcc, clang and cppcheck, and another distribution's
# versions count differently.
#   tools/ci/in-fedora.sh tools/ci/run.sh static
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec docker run --rm -v "$ROOT:/w" -w /w -e HOME=/tmp/home -e SKIP_DEPS registry.fedoraproject.org/fedora:44 bash -ec '
  dnf -y -q install gcc clang clang-tools-extra cppcheck git curl python3 tar xz unzip findutils which >/dev/null
  git config --global --add safe.directory "*"
  exec "$@"' -- "$@"
