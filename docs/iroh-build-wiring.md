# Build wiring for crates/ghostty-iroh

> Status: this is the required direction, not a claim that it works. **Nothing
> in `docs/iroh-build-wiring.patch` has been built.** No Rust code exists yet,
> `crates/` is owned by another worker, and no `cargo build` — host or
> windows-gnu — has been run anywhere. What *has* been checked is listed under
> "What was actually verified" and is deliberately small.

`docs/IROH.md`, "Cross-compilation", names the build changes step 3 needs. This
is those changes, written as a patch rather than applied, because the build
scripts are load-bearing for every other worker on this branch right now. Apply
it when the crate is ready:

```sh
git apply docs/iroh-build-wiring.patch
```

## The guard, first, because it is the point

`IROH=1` turns the crate on. It is **off by default**, and off means the build
is the build it is today — not "nearly", but the same command strings.

Three independent gates, in `iroh_probe` (`tools/build-common.sh`):

1. `IROH=1` must be set. Unset (the default) → immediate return, nothing else
   is even looked at.
2. `crates/ghostty-iroh/Cargo.toml` must exist. Missing → one line on stderr,
   build continues without iroh.
3. `cargo` must be on `PATH`. Missing → one line on stderr, build continues
   without iroh.

`iroh_probe` sets `IROH_HOST_LIBDIR` / `IROH_WIN_LIBDIR`, both empty when any
gate fails. Everything downstream derives from those two strings:

* `build_iroh` returns 0 immediately when both are empty — the `== ghostty-iroh`
  step never runs.
* `iroh_host_ldflags` / `iroh_win_ldflags` print **nothing**, so
  `--cflags="-O2 $INC ...$(iroh_win_ldflags)"` is character-for-character the
  string it is today.
* The one link that passes no `--cflags` at all today (the host agent,
  `tools/build.sh:115`) keeps passing none: the flag goes in through an array
  that stays empty.

`SKIP_WIN=1` clears `IROH_WIN_LIBDIR` only, so `tools/ci/run.sh` behaves.
`SKIP_DEPS=1` skips `build_iroh` with the rest of the dependency block, since it
lives inside that block beside libghostty-vt and Lua.

So a checkout without `crates/` builds identically whether or not this patch is
applied, and a checkout *with* `crates/` still builds identically until someone
types `IROH=1`. The crate does not become a hard dependency by landing.

## What the patch changes

| File | Change |
| --- | --- |
| `toolchain.env` | New "Rust staticlib" section: `RUST_VERSION`, `RUST_PKGS_PINNED` (exact Fedora NEVRs), `RUST_WINDOWS_TARGET`, `IROH_VERSION`, `CARGO_VENDOR_URL`/`CARGO_VENDOR_SHA256`. |
| `tools/build-common.sh` | `iroh_probe`, `build_iroh`, `iroh_host_ldflags`, `iroh_win_ldflags`, and the Windows syslib list. All additive; nothing existing is touched. |
| `tools/build.sh` | `iroh_probe` after the `mkdir`; `build_iroh` inside the `SKIP_DEPS` block; `$(iroh_win_ldflags)` spliced into the core, loader and `ghostty-agent.exe` `--cflags`; an empty-by-default array on the host agent link. |
| `tools/build-agent.sh` | `SKIP_WIN=1 iroh_probe` + `build_iroh` (host only), and `$(iroh_host_ldflags)` appended to its existing `--cflags`. |
| `tools/build-container.sh` | `RUST_PKGS_PINNED` installed by the existing `install_pinned`; `$CACHE/cargo-target` in the shared cache layout; `CARGO_TARGET_DIR`, `RUSTC_WRAPPER=sccache`, `CARGO_NET_OFFLINE=true` in the container profile; cargo/rustc/rust-std lines in `status`. |
| `tools/fetch-vendor.sh` | Optional `CARGO_VENDOR_URL` tarball → `vendor/cargo`, sha256-verified, with the generated `config.toml`. |
| `tests/run.sh` | One `$LIBS` append, guarded on `IROH=1` **and** `build/lib/libghostty_iroh.a` existing. `$LIBS` is shared by every host link in that file, including the `core/host.nelua` shared object at `:215`, so this is the only place it needs naming. |

`tools/build-remote.sh` needs **no** change. `crates/` is tracked, so
`push_source` (`git ls-files --cached --others --exclude-standard`) already
carries it into the container; the cargo target dir comes from the profile and
is already on the shared volume.

## Pinning, and why the vendor tree is a tarball

`tools/fetch-vendor.sh` has four idioms and a bare `cargo build` matches none:
it would be the only dependency here that reaches the network at build time.
So the dependency tree is `cargo vendor`-ed **once**, published as a single
tarball, and pinned by sha256 — the `LUA_URL`/`LUA_SHA256` idiom. `--locked
--offline` against it, with `crates/ghostty-iroh/Cargo.lock` committed as the
authority for revisions.

The tree lands in `vendor/cargo`, which doubles as `CARGO_HOME` (cargo reads
`$CARGO_HOME/config.toml`, so the `replace-with` stanza needs no per-invocation
flag). That choice answers the question `docs/IROH.md` leaves open — committed
vendor tree or fetched one: **fetched**. `vendor/` inside the build container is
a symlink into the shared Incus volume and is explicitly *not* part of the
rsynced source, so a fetched tree is transferred once per container instead of
on every build, and the repo does not grow a QUIC+TLS+crypto dependency tree.

`CARGO_VENDOR_URL` and `IROH_VERSION` are **empty** in the patch. They are
placeholders for whoever lands the crate; empty means `fetch-vendor.sh` skips
the step entirely, and `build_iroh` warns that cargo will resolve online rather
than silently doing it.

The toolchain itself is pinned as Fedora NEVRs in `RUST_PKGS_PINNED`, installed
by the same `install_pinned` that handles `BUILD_PKGS_PINNED` — including its
existing "Fedora retired this build, installing unpinned and warning" fallback.
`rust-std-static-x86_64-pc-windows-gnu` is the cross std, so **no rustup**.

## The Windows link

`CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER` points at `tools/zig-cc-win.sh`.
That is the arrangement `docs/IROH.md` says to try first, for the reason it
gives: one mingw-w64, not two. It is untested.

The syslibs are named *after* `-lghostty_iroh` because the MinGW link is single
pass: `-lws2_32 -lbcrypt -lntdll -luserenv -ladvapi32 -liphlpapi -lsecur32
-lcrypt32`. That list is an educated guess at an iroh-shaped tree's needs, not a
measurement; expect to edit it once something actually links.

Note the overlap to come: when `core/sys/net.nelua` gains `## linklib
'ghostty_iroh'`, Nelua will emit its own `-lghostty_iroh` in addition to the one
here. A duplicate `-l` on a static archive is harmless, but its *position*
relative to these syslibs is not, and that is the first thing to look at if the
link fails with undefined `BCrypt*`/`__chkstk_ms` symbols.

## What was actually verified

Cheap, local, and nothing that spends a build:

* `git apply --check` succeeds against the current worktree, all seven files.
* `bash -n` on every modified script.
* `shellcheck -S warning -x` on all six scripts: clean, and identical to the
  unmodified baseline.
* The guard behaviour, exercised directly by sourcing `build-common.sh`:
  IROH unset → both flag functions empty and `build_iroh` returns 0; `IROH=1`
  with no crate → empty + one stderr line; `IROH=1` with a crate but no cargo →
  empty + one stderr line; `IROH=1` with a stub cargo → the expected `-L`/`-l`
  strings, and `SKIP_WIN=1` suppressing only the Windows half.
* `set -euo pipefail` does not abort on the `[[ -n ... ]] && arr=(...)` idiom,
  and `"${arr[@]}"` expands to nothing under `set -u` (bash 5.3.9).
* `dnf repoquery` inside `fedora:ghostty-build` lists `rust-1.98.1-1.fc44`,
  `cargo-1.98.1-1.fc44` and `rust-std-static-x86_64-pc-windows-gnu-1.98.1-1.fc44`
  as installable. **They are not installed**, and `cargo --version` in that
  container is still MISSING.

## What was NOT verified, and is the real risk list

* No Rust was compiled, for either target. The two risks in `docs/IROH.md`
  ("MinGW single-pass linking", "Two mingw-w64 copies") are untouched by this
  patch — it only arranges for them to be hit.
* `RUSTC_WRAPPER=sccache` in the container profile is not known to work with
  this cargo; it is also the first thing to drop if rustc caching misbehaves.
* `CARGO_NET_OFFLINE=true` in the profile makes any *other* cargo use in that
  container offline too. Intentional, but it is a global.
* The static-analysis gap stands: `tests/static-budget.txt` comes from Fedora
  gcc/clang/cppcheck via `tools/ci/in-fedora.sh` and a Rust crate is invisible
  to it. This patch adds no `clippy` step. Decide and record it in
  `docs/CI.md`; right now the honest statement is "the crate has no
  static-analysis coverage".
* Nothing here proves iroh works under Wine. The only measured transport fact
  remains the UDP echo test in `docs/IROH.md`.
