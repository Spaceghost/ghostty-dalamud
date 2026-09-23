#!/usr/bin/env bash
# Run a command in a Fedora 44 container on a GitHub-hosted runner, with this
# checkout mounted: the static-analysis counts in tests/static-budget.txt were
# taken with Fedora's gcc, clang and cppcheck, and another distribution's
# versions count differently. The agent's RPMs are built here for the same
# reason — a Fedora package is built on Fedora, never repacked from elsewhere.
#
#   tools/ci/in-fedora.sh tools/ci/run.sh static
#   IN_FEDORA_PKGS='rpm-build ...' tools/ci/in-fedora.sh tools/ci/agent-rpm.sh --out build/release
#
# Environment:
#   IN_FEDORA_PKGS   packages to install first (default: the static-analysis set)
#   IN_FEDORA_IMAGE  the image (default: the pinned registry.fedoraproject.org/fedora:44)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKGS="${IN_FEDORA_PKGS:-gcc make clang clang-tools-extra cppcheck git curl python3 tar xz unzip findutils which}"
IMAGE="${IN_FEDORA_IMAGE:-registry.fedoraproject.org/fedora:44}"
exec docker run --rm -v "$ROOT:/w" -w /w \
  -e HOME=/tmp/home -e SKIP_DEPS -e SOURCE_DATE_EPOCH -e RELEASE_TAG -e AGENT_GLIBC_MAX \
  -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" -e "IN_FEDORA_PKGS=$PKGS" \
  "$IMAGE" bash -ec '
  mkdir -p "$HOME"
  # shellcheck disable=SC2086
  dnf -y -q install $IN_FEDORA_PKGS >/dev/null
  git config --global --add safe.directory "*"
  exec "$@"' -- "$@"
