#!/usr/bin/env bash
# Explicit, one-time privacy maintenance. Work only in a disposable clone.
# This rewrites remote branch histories. It does not touch this checkout's files.
set -euo pipefail
[[ "${1:-}" == --apply && $# == 1 ]] || { echo 'usage: tools/scrub-history.sh --apply' >&2; exit 2; }
remote="$(git remote get-url origin)"
python3 - "$remote" <<'PY'
import sys
url = sys.argv[1].lower().removesuffix('.git')
if url not in ('https://github.com/spaceghost/ghostty-dalamud',
               'git@github.com:spaceghost/ghostty-dalamud',
               'ssh://git@github.com/spaceghost/ghostty-dalamud'):
    raise SystemExit('Refusing maintenance outside Spaceghost/ghostty-dalamud.')
PY
work="$(mktemp -d "${TMPDIR:-/tmp}/ghostty-privacy.XXXXXXXX")"
chmod 700 "$work"
trap 'rm -rf -- "$work"' EXIT
export PYTHONDONTWRITEBYTECODE=1
git clone --no-single-branch "$remote" "$work/repo"
cd "$work/repo"
git switch master
git fetch origin '+refs/heads/*:refs/remotes/origin/*'
git ls-remote --heads --tags origin > "$work/refs"
python3 tools/rewrite-branches.py "$work/refs"
printf '%s\n' 'Branch rewrite completed. Re-clone other working copies; do not merge the old history back.'
