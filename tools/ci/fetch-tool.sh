#!/usr/bin/env bash
# Fetch a pinned, sha256-checked release binary into ~/.local/bin.
#   tools/ci/fetch-tool.sh gitleaks | actionlint
set -euo pipefail
case "${1:-}" in
  gitleaks) url=https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz
    sha=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb ;;
  actionlint) url=https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz
    sha=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 ;;
  *) echo "usage: fetch-tool.sh gitleaks|actionlint" >&2; exit 2 ;;
esac
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 3 -o "$tmp/t.tgz" "$url"
echo "$sha  $tmp/t.tgz" | sha256sum -c --status - || { echo "checksum mismatch for $url" >&2; exit 1; }
mkdir -p "$HOME/.local/bin"
tar -xzf "$tmp/t.tgz" -C "$HOME/.local/bin" "$1"
echo "$HOME/.local/bin/$1"
