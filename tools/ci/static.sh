#!/usr/bin/env bash
# Static analysis of the C this project compiles: what Nelua generates for the
# core, the loader and the agent (the generated file is what ships, so that is
# what gets analysed). Needs vendor/ (tools/fetch-vendor.sh); compiles nothing
# but the analysers' own passes.
#
#   tools/ci/static.sh [warnings] [cppcheck] [analyze] [tidy]     default: all
#
# warnings  gcc -fsyntax-only -Wall -Wextra -Wconversion, counted per unit
# cppcheck  warning,portability
# analyze   clang --analyze (the scan-build checkers)
# tidy      clang-tidy with bugprone-*, cert-*, clang-analyzer-* minus the
#           checks generated code cannot satisfy (.clang-tidy)
#
# Every count is held to tests/static-budget.txt: the job fails when one rises,
# so a new finding is caught the day it appears while the ones already there
# are worked down. After fixing some, lower the budget with `--update`. The
# counts were taken with Fedora 44's tools (tools/ci/in-fedora.sh).
# Reports land in build/static/.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
OUT="$ROOT/build/static"; GEN="$OUT/c"; mkdir -p "$GEN"
NELUA="$ROOT/vendor/nelua-lang/nelua"
# Every vendored header counts as a system header, so its own warnings are not
# ours: libghostty-vt, cimgui, Lua and stb (stb_truetype.h is compiled into the
# core with its implementation, so its -Wconversion findings, 178 with Fedora
# 44's gcc, were counted as the host's), and the agent's WireGuard
# (docs/WIREGUARD.md). lwipopts.h is generated into the Nelua cache by
# agent/wg_netstack.nelua. What Nelua generates from core/, agent/ and lua/,
# and Nelua's own standard library, is still analysed in full.
VENDOR_INC=("$ROOT/vendor/ghostty/include" "$ROOT/vendor/gc-cimgui" "$ROOT/vendor/lua/src" "$ROOT/vendor/stb")
INC=()
INC_CPPCHECK=() # cppcheck knows no -isystem: its reports from vendor/ are suppressed below instead
for d in "${VENDOR_INC[@]}"; do INC+=(-isystem "$d"); INC_CPPCHECK+=(-I"$d"); done
INC+=(-isystem "$ROOT/vendor/monocypher/src" -isystem "$ROOT/vendor/lwip/src/include" -isystem "$OUT/nelua/lwip-port"
  -isystem "$ROOT/vendor/qrcodegen")
UNITS=(core/host:host core/loader:loader agent/agent:agent)
update=0; steps=()
for a in "$@"; do if [[ "$a" == --update ]]; then update=1; else steps+=("$a"); fi; done
[[ ${#steps[@]} -gt 0 ]] || steps=(warnings cppcheck analyze tidy)

for u in "${UNITS[@]}"; do
  src="${u%%:*}" name="${u##*:}"
  flags=(-P nogc); [[ "$name" != agent ]] && flags+=(-P noentrypoint)
  "$NELUA" "${flags[@]}" --cache-dir "$OUT/nelua" -L . -c -o "$GEN/$name.c" "$src.nelua" >/dev/null ||
    { echo "static: cannot generate C for $src" >&2; exit 1; }
done

fail=0
BUDGET="$ROOT/tests/static-budget.txt"; touch "$BUDGET"
budget() { # key count report
  local have
  have="$(awk -v k="$1" '$1==k{print $2}' "$BUDGET")"
  if [[ $update == 1 ]]; then
    grep -v "^$1 " "$BUDGET" >"$BUDGET.tmp" || true
    echo "$1 $2" >>"$BUDGET.tmp"; sort -o "$BUDGET" "$BUDGET.tmp"; rm -f "$BUDGET.tmp"; have="$2"
  fi
  echo "$1: $2 (budget ${have:-none}) $3"
  if [[ -z "$have" || "$2" -gt "$have" ]]; then fail=1; echo "  over budget"; fi
}
for step in "${steps[@]}"; do
  case "$step" in
    warnings)
      : >"$OUT/warnings.txt"
      for u in "${UNITS[@]}"; do
        name="${u##*:}"
        gcc -fsyntax-only -Wall -Wextra -Wconversion "${INC[@]}" "$GEN/$name.c" 2>"$OUT/warnings-$name.log"
        echo "$name $(grep -c 'warning:' "$OUT/warnings-$name.log")" >>"$OUT/warnings.txt"
      done
      while read -r name n; do budget "warnings-$name" "$n" "build/static/warnings-$name.log"; done <"$OUT/warnings.txt" ;;
    cppcheck)
      # constStatement: Nelua writes every value-producing block as a GNU
      # statement expression, `({ T _tmp = ...; ...; _tmp; })`, and cppcheck
      # takes the closing `_tmp;` for a statement with no effect. Nelua source
      # has no expression statements, so the check cannot find one of ours.
      cppcheck --quiet --enable=warning,portability --inline-suppr \
        --suppress=missingIncludeSystem --suppress=unknownMacro "--suppress=*:$ROOT/vendor/*" --suppress=constStatement \
        "${INC_CPPCHECK[@]}" "$GEN" 2>"$OUT/cppcheck.log"
      budget cppcheck "$(grep -c ': \(error\|warning\|portability\)' "$OUT/cppcheck.log")" build/static/cppcheck.log ;;
    analyze)
      : >"$OUT/analyze.log"
      for u in "${UNITS[@]}"; do
        clang --analyze -Xclang -analyzer-output=text "${INC[@]}" "$GEN/${u##*:}.c" -o /dev/null 2>>"$OUT/analyze.log"
      done
      budget analyze "$(grep -c 'warning:' "$OUT/analyze.log")" build/static/analyze.log ;;
    tidy)
      : >"$OUT/tidy.log"
      for u in "${UNITS[@]}"; do
        clang-tidy --quiet "$GEN/${u##*:}.c" -- "${INC[@]}" >>"$OUT/tidy.log" 2>/dev/null
      done
      budget tidy "$(grep -c 'warning:\|error:' "$OUT/tidy.log")" build/static/tidy.log ;;
    *) echo "static: unknown step $step" >&2; exit 2 ;;
  esac
done
exit "$fail"
