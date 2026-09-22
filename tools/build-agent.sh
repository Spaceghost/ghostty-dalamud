#!/usr/bin/env bash
# Standalone agent build. Darwin support remains experimental until tested there.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
case "$(uname -s)" in Linux|Darwin) ;; *) echo 'The agent requires Linux or macOS.' >&2; exit 2 ;; esac
CC="${CC:-cc}"
source "$ROOT/tools/build-common.sh"
[[ -d vendor/nelua-lang && -d vendor/ghostty ]] || { echo 'Fetch the pinned dependencies before building.' >&2; exit 1; }
build_nelua
mkdir -p build/dist build/nelua-cache
# Optional iroh staticlib (docs/IROH.md). iroh_probe leaves everything empty
# unless IROH=1 and crates/ghostty-iroh exists, so the flags below are unchanged
# in a checkout without the crate. Host only: this script never builds Windows.
SKIP_WIN=1 iroh_probe
build_iroh
"$ROOT/vendor/nelua-lang/nelua" --cc "$CC" -P nogc --cflags="-I\"$ROOT/compat\"$(iroh_host_ldflags)" --cache-dir build/nelua-cache -L . -o build/dist/ghostty-agent -b agent/agent.nelua
