#!/usr/bin/env bash
# Time-boxed fuzzing of tests/fuzz.nelua (VT streams into libghostty, wire
# frames into core/protocol.nelua, agent strings), built with AddressSanitizer
# and UBSan. Needs the host parts of tools/build.sh (tools/ci/run.sh fuzz does
# them first).
#
#   FUZZ_SECONDS   time budget, default 1500
#   FUZZ_ITERS     iterations per seed, default 400
#   SAN            sanitizers, default asan,ubsan (tools/sanitize.sh)
#   FUZZ_ENGINE    seed (default): tests/fuzz.nelua with random seeds.
#                  libfuzzer: tests/fuzz_libfuzzer.nelua, coverage-guided, clang;
#                  the corpus persists in build/fuzz/corpus (cached between CI
#                  runs), crashers land in build/fuzz/crashers
#
# First every seed in tests/fuzz-seeds.txt (seeds that once failed) is
# replayed, then fresh random seeds until the budget is spent. A failing seed
# and its output land in build/fuzz/crashers/; exit 1 when there is any.
# Replay one by hand: SAN=asan,ubsan tools/ci/fuzz.sh --seed N
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
export SAN="${SAN:-asan,ubsan}" ZIG="${ZIG:-zig}"
# shellcheck source=tools/sanitize.sh
source "$ROOT/tools/sanitize.sh"
NCACHE="build/nelua-cache$SAN_SUFFIX"
INC="-I$ROOT/vendor/ghostty/include -I$ROOT/vendor/gc-cimgui -I$ROOT/vendor/lua/src -I$ROOT/vendor/stb"
LIBS="-L$ROOT/build/ghostty-vt-linux/lib -L$ROOT/build/lua-linux -lm"
export LD_LIBRARY_PATH="$ROOT/build/ghostty-vt-linux/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
OUT="$ROOT/build/fuzz"; mkdir -p "$OUT/crashers"
if [[ "${FUZZ_ENGINE:-seed}" == libfuzzer ]]; then
  export SAN_CC=clang SAN_CFLAGS="-g -O1 -fno-omit-frame-pointer -fsanitize=fuzzer,address,undefined -fno-sanitize=pointer-overflow,shift-base -Dmain=nelua_entry_main"
  "$ROOT/vendor/nelua-lang/nelua" --cc "$ROOT/tools/san-cc.sh" -P nogc --cflags="$INC $LIBS" --cache-dir build/nelua-cache-libfuzzer -L . -b tests/fuzz_libfuzzer.nelua
  mkdir -p "$OUT/corpus"
  exec build/nelua-cache-libfuzzer/fuzz_libfuzzer "$OUT/corpus" "-max_total_time=${FUZZ_SECONDS:-1500}" -max_len=4096 \
    "-artifact_prefix=$OUT/crashers/" -print_final_stats=1
fi
"$ROOT/vendor/nelua-lang/nelua" --cc "$ROOT/tools/san-cc.sh" -P nogc --cflags="$INC $LIBS" --cache-dir "$NCACHE" -L . -b tests/fuzz.nelua
ITERS="${FUZZ_ITERS:-400}"
fails=0 runs=0
one() { # seed
  runs=$((runs + 1))
  if ! "${SAN_PREFIX[@]}" "$NCACHE/fuzz" "$1" "$ITERS" >"$OUT/last.log" 2>&1; then
    fails=$((fails + 1))
    cp "$OUT/last.log" "$OUT/crashers/seed-$1.log"
    echo "$1" >>"$OUT/crashers/seeds.txt"
    echo "FAIL seed $1 (build/fuzz/crashers/seed-$1.log)"; tail -30 "$OUT/last.log"
  fi
}
if [[ "${1:-}" == --seed ]]; then one "$2"; cat "$OUT/last.log"; exit "$fails"; fi
while read -r seed _; do
  [[ "$seed" =~ ^[0-9]+$ ]] && one "$seed"
done <"$ROOT/tests/fuzz-seeds.txt"
end=$((SECONDS + ${FUZZ_SECONDS:-1500}))
while ((SECONDS < end && fails < 10)); do
  one "$(od -An -N6 -tu8 /dev/urandom | tr -d ' ')"
done
echo "fuzz: $runs seeds x $ITERS iterations, $fails failed"
[[ $fails -eq 0 ]]
