# Quality battery

Everything here runs by itself on GitHub-hosted runners; nobody has to watch
it. Every check is one matrix row that writes a row in the job summary,
uploads its logs as an artifact, and on `master` keeps one issue labelled
`quality-<kind>` up to date: a comment per failure, closed when it passes
again (`tools/ci/report-issue.sh`). Pull requests, forks included, run the same
checks with a read-only token and never touch issues or a self-hosted runner.

| Workflow | When | Checks |
| --- | --- | --- |
| `quality.yml` | push and pull request to `master` | `lint`, `secrets`, `asan`, `ubsan`, `static` |
| `quality-nightly.yml` | nightly | `fuzz`, `fuzz-coverage`, `soak`, `tsan-agent` |
| `quality-deep.yml` | weekly | `valgrind`, `helgrind-agent`, `drd-agent`, `massif`, `soak-long`, `fuzz-long`, `fuzz-coverage-long` |
| `codeql.yml` | push, pull request, weekly | CodeQL over the C# shim and the workflows |
| `scorecard.yml` | push to `master`, weekly | OpenSSF Scorecard |
| `.github/dependabot.yml` | weekly | action and NuGet updates |

## What each check is

| Kind | Command | Catches |
| --- | --- | --- |
| `asan` | `SAN=asan tools/ci/run.sh test` | out-of-bounds, use-after-free, double free; LeakSanitizer fails any test binary that exits with memory it never freed |
| `ubsan` | `SAN=ubsan tools/ci/run.sh test` | undefined behaviour, fatal on the first one |
| `tsan-agent` | `SAN=tsan ONLY=agent tools/ci/run.sh test` | data races in the agent's threads |
| `valgrind` | `SAN=valgrind tools/ci/run.sh test` | memcheck over the whole host suite: definite, indirect and possible leaks, uninitialised reads, invalid frees |
| `helgrind-agent`, `drd-agent` | `SAN=helgrind` / `SAN=drd` with `ONLY=agent` | lock-order and race errors, two detectors |
| `massif` | `tools/ci/run.sh massif` | nothing by itself: a heap profile (`build/massif/*.txt`) to read |
| `soak`, `soak-long` | `GHOSTTY_HEAP_ITERS=N tools/ci/run.sh test` | a hot path whose heap keeps growing when repeated (`tests/heapcheck.nelua`): the glyph atlas fill/evict/reset loop, the core init/shutdown (hot swap) loop, agent sessions, the fuzz targets |
| `fuzz`, `fuzz-long` | `tools/ci/run.sh fuzz` | crashes and leaks on random VT streams, wire frames and agent strings; seeds replay (`tests/fuzz-seeds.txt`) |
| `fuzz-coverage` | `FUZZ_ENGINE=libfuzzer tools/ci/run.sh fuzz` | the same parsers, coverage-guided (libFuzzer); the corpus is cached between runs, crashers land in `build/fuzz/crashers` |
| `static` | `tools/ci/in-fedora.sh tools/ci/run.sh static` | `gcc -Wall -Wextra -Wconversion`, cppcheck, `clang --analyze` and clang-tidy over the C that Nelua generates, each count held to `tests/static-budget.txt`: a new finding fails, the old ones are there to work down (`tools/ci/static.sh --update` lowers the budget) |
| `lint` | `tools/ci/run.sh lint` | shellcheck, luacheck (`.luacheckrc`), actionlint |
| `secrets` | `gitleaks git --redact .` | credentials anywhere in history |

Sanitizer builds use gcc: Zig 0.16 compiles `-fsanitize=address` but ships no
AddressSanitizer runtime for x86_64-linux-gnu. MemorySanitizer is not offered:
it needs every linked library instrumented, and libghostty-vt and liblua are
not. Sanitizer builds keep their own Nelua cache and binaries. `tests/lsan.supp`
and `tests/valgrind.supp` are for vendored and system code only.

## In the game: the leak watch

Every core writes its process numbers (private bytes, working set, kernel, GDI
and USER handles) into `selftest/core-loaded.json` on its first frame. With
`/term selftest leakwatch on`, each core load also appends a line to
`selftest/leakwatch.tsv` in the plugin's config directory; after a session of
`/term reload`s, `/term selftest leakwatch` logs the growth per load, and the
file is there to read. `/term selftest leakwatch off` stops it. One sample per
load: nothing runs per frame.

## Running it yourself

In the build container, not on the gaming PC: any command from the table,
after `tools/ci/run.sh deps`. valgrind, the sanitizer runtimes (libasan,
libubsan, libtsan), clang, cppcheck, clang-tools-extra and luacheck must be
installed there.

## Not covered yet

The heap-growth loops do not yet cover remote windows, capture, or theme
reload (those paths are under LeakSanitizer and memcheck, which catch a leak
at exit but not growth that is freed at shutdown). The Lua per-frame garbage
budget is asserted for pets only (tests/test_worldpanel.nelua). The Windows
build of the core is not run by any of this; the leak watch is how it is
observed.
