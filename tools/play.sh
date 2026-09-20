#!/usr/bin/env bash
# Build and stage a fresh candidate. Does not launch your personal agent or game.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[[ $# -le 1 ]] || { echo 'usage: tools/play.sh [NEW_DESTINATION]' >&2; exit 2; }
tools/build-release.sh
package="$ROOT/build/release/GhosttyDalamud.zip"
hash="$(python3 - "$package" <<'PY'
import hashlib, pathlib, sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)"
commit="$(git rev-parse --short=12 HEAD)"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
destination="${1:-$data_home/ghostty-dalamud/candidates/$commit-${hash:0:12}}"
python3 tools/candidate.py install --package "$package" --sha256 "$hash" --destination "$destination"
printf '\nFor Linux/Wine, start the agent in a separate terminal:\n  %q --listen 127.0.0.1:7777\n' "$ROOT/build/dist/ghostty-agent"
printf '\nNo agent was started and no token/configuration was copied into the package.\n'
printf 'Disable any older Ghostty dev entry before enabling this candidate. See docs/TRY_IT.md.\n'
