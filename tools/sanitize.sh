#!/usr/bin/env bash
# Sourced by tests/run.sh when SAN is set: picks the compiler and the runtime
# options for a sanitizer run of the host tests. Never sourced by a normal run,
# so an ordinary `tests/run.sh` is unchanged.
#
#   SAN=asan            AddressSanitizer + LeakSanitizer (gcc)
#   SAN=ubsan           UndefinedBehaviorSanitizer (gcc), errors are fatal
#   SAN=asan,ubsan      both; also what SAN=1 means
#   SAN=tsan            ThreadSanitizer (gcc); meant for ONLY=agent, the threaded part
#   SAN=valgrind        no instrumentation; every test binary runs under
#                       valgrind memcheck: definite, indirect and possible
#                       leaks, uninitialised reads and invalid frees are errors
#   SAN=helgrind, drd   valgrind's two thread checkers (again for ONLY=agent)
#
# MemorySanitizer is not offered: it needs every linked library instrumented,
# and libghostty-vt (built by Zig) and liblua are not, so each value that
# crosses into them would be reported as uninitialised.
#
# Why gcc and not tools/zig-cc.sh: Zig 0.16 compiles -fsanitize=address but
# ships no AddressSanitizer runtime for x86_64-linux-gnu, so the link fails
# with `undefined symbol: __asan_report_store1`. UBSan alone does link under
# zig cc; the sanitizer job uses one compiler for both so a report's line
# numbers come from one build. Set SAN_CC=clang to use clang instead.
#
# Exports, read by tests/run.sh:
#   SAN_CC SAN_CFLAGS   for tools/san-cc.sh
#   SAN_SUFFIX          appended to build/nelua-cache and to built binaries,
#                       so an instrumented object never lands in the normal cache
#   SAN_PREFIX          array: a command prefix for every test binary (valgrind)
#   plus ASAN_OPTIONS / UBSAN_OPTIONS / LSAN_OPTIONS in the environment
set -uo pipefail
: "${ROOT:?tools/sanitize.sh needs ROOT}"

san_want() { case ",${SAN}," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

case "${SAN:-}" in
  1 | yes | true | on) SAN=asan,ubsan ;;
esac

SAN_CC="${SAN_CC:-gcc}"
SAN_CFLAGS=""
SAN_PREFIX=()
SAN_SUFFIX="-san"

if san_want helgrind || san_want drd; then
  command -v valgrind >/dev/null || { echo "SAN=$SAN but valgrind is not installed" >&2; exit 1; }
  SAN_SUFFIX="-vg"
  SAN_CFLAGS="-g -O1 -fno-omit-frame-pointer"
  vg_tool=helgrind; if san_want drd; then vg_tool=drd; fi
  SAN_PREFIX=(valgrind --quiet "--tool=$vg_tool" --error-exitcode=9 --num-callers=25
    "--suppressions=$ROOT/tests/valgrind.supp")
elif san_want valgrind; then
  command -v valgrind >/dev/null || { echo "SAN=valgrind but valgrind is not installed" >&2; exit 1; }
  SAN_SUFFIX="-vg"
  SAN_CFLAGS="-g -O1 -fno-omit-frame-pointer"
  # shellcheck disable=SC2054 # the commas are valgrind's
  SAN_PREFIX=(valgrind --quiet --error-exitcode=9 --leak-check=full --errors-for-leak-kinds=definite,indirect,possible
    --show-leak-kinds=definite,indirect,possible --track-origins=yes --num-callers=25
    "--suppressions=$ROOT/tests/valgrind.supp")
else
  command -v "$SAN_CC" >/dev/null || { echo "SAN=$SAN but $SAN_CC is not installed" >&2; exit 1; }
  SAN_CFLAGS="-g -O1 -fno-omit-frame-pointer"
  if san_want asan; then SAN_CFLAGS="$SAN_CFLAGS -fsanitize=address"; fi
  if san_want tsan; then SAN_CFLAGS="$SAN_CFLAGS -fsanitize=thread"; SAN_SUFFIX="-tsan"; fi
  if san_want ubsan; then
    SAN_CFLAGS="$SAN_CFLAGS -fsanitize=undefined -fno-sanitize-recover=undefined"
    # Nelua emits `x + 0` on pointers and signed shifts that C calls undefined
    # but the generated code relies on; those two are off, everything else is fatal.
    SAN_CFLAGS="$SAN_CFLAGS -fno-sanitize=pointer-overflow,shift-base"
  fi
  # a link check, so a missing runtime is one clear line and not 200 link errors
  # shellcheck disable=SC2086 # SAN_CFLAGS is a flag list, splitting is the point
  if ! echo 'int main(void){return 0;}' | "$SAN_CC" $SAN_CFLAGS -x c - -o /dev/null 2>/dev/null; then
    echo "SAN=$SAN: $SAN_CC cannot link $SAN_CFLAGS (install libasan/libubsan, or the clang compiler-rt)" >&2
    exit 1
  fi
fi

# detect_leaks is on for asan runs; the vendored libraries keep allocations
# alive on purpose, so tests/lsan.supp names them instead of failing the run.
leaks=0
if san_want asan; then leaks=1; fi
export ASAN_OPTIONS="detect_leaks=$leaks:detect_stack_use_after_return=1:strict_string_checks=1:check_initialization_order=1:detect_odr_violation=0:abort_on_error=0:halt_on_error=1:log_path=stderr:${ASAN_OPTIONS:-}"
export LSAN_OPTIONS="suppressions=$ROOT/tests/lsan.supp:print_suppressions=0:${LSAN_OPTIONS:-}"
export TSAN_OPTIONS="halt_on_error=1:second_deadlock_stack=1:${TSAN_OPTIONS:-}"
export UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1:${UBSAN_OPTIONS:-}"
export SAN SAN_CC SAN_CFLAGS SAN_SUFFIX

printf '== sanitizers: SAN=%s cc=%s cflags=%s%s\n' "$SAN" "$SAN_CC" "$SAN_CFLAGS" "${SAN_PREFIX[0]+ under ${SAN_PREFIX[*]}}"
