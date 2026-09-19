# Building on the remote Incus container

Compiling on the machine that runs the game does not work: it has 15 GB of RAM,
FFXIV holds most of it, and a full build there gets OOM-killed. Every build and
every host test therefore runs in an Incus container on a build host. What stays
on the gaming PC is installing the plugin (`tools/install-dev.sh`), the game, and
`/term selftest` in it.

```sh
tools/build-remote.sh          # build in the container, bring build/dist/ back
tools/build-remote.sh test     # tools/ci/run.sh test there (tests/run.sh)
tools/test-remote.sh           # the same, and fail unless it printed ALL OK
tools/build-remote.sh all      # test, then build
tools/build-remote.sh pull     # fetch build/dist/ again
tools/build-remote.sh shell    # a shell in the container, in the checkout
```

`tools/build-remote.sh --help` is the reference for its commands and its
environment (`INCUS_REMOTE`, `DALAMUD_LIB_PATH`, `NO_DALAMUD_PUSH`, and the
`SKIP_*`/`MAC` switches, which mean what they mean locally). It sends the
worktree as it stands — tracked files plus untracked ones `.gitignore` does not
cover — so any branch, clean or dirty, builds as it is, and it creates the
container when it is missing (`tools/build-container.sh`).

`tools/test-remote.sh` is the thin wrapper worth putting in a loop or a hook: it
runs the test command and exits non-zero unless `tests/run.sh` reached `ALL OK`,
so "the tests ran" cannot be confused with "the tests passed".

Locally this needs an `incus` client, `rsync` and nothing else — no Zig, no .NET
SDK, no Dalamud assemblies, no memory taken from the game.

## The container

`tools/build-container.sh` creates and maintains it; the pins live in
`toolchain.env` (`BUILD_*`): image `images:fedora/44` by fingerprint, 8 CPUs,
32 GiB, a cache volume at `/cache`, the checkout at a fixed path so that
compiler-cache keys (which contain absolute paths) match between runs and hosts.

| | |
|---|---|
| Toolchain | Zig pinned to `ZIG_VERSION`, the .NET 10 SDK, gcc, make, git, rsync, python3, zip/unzip, sccache |
| Wayland | `wlroots` 0.20.2, `libwayland-server`, `libxkbcommon`, `pixman` at the versions `toolchain.env` pins for the `wayland-sdk` headers, because the agent binary is built here and runs on the gaming PC. With them `tools/wayland-flags.sh` compiles the compositor backend in and `tests/run.sh` runs `test_capture_wayland`; without `libwlroots-0.20.so` the agent still builds and the flags script says so (`SKIP_WAYLAND=1` forces that) |
| Cache volume | An Incus storage volume mounted at `/cache`, so it survives recreating the container: the pinned `vendor/` checkouts, the Zig global and per-target caches, the Nelua compile cache, NuGet packages, the sccache store, the `tools/ci/run.sh` download cache (pinned Zig and Dalamud), and `build.lock` |

The checkout's `build/{zig-cache-*,nelua-cache,ghostty-vt-*,lua-*}` and `vendor/`
are symlinks onto that volume, so a fresh checkout is never a cold build.

### The build lock

Several sessions drive this container at once, and they share those caches, so a
build takes `flock` on `/cache/build.lock` and the others wait.

Take it with **`flock -o`**. Without `-o` the lock's file descriptor is inherited
by every daemon the build leaves running — sccache's server and Roslyn's
`VBCSCompiler` — and the lock stays held after the build is long over, for as
long as those daemons live, which deadlocks every later run. That is not
theoretical: on 2026-09-19 `/cache/build.lock` was held by nothing but an idle
`VBCSCompiler`, with two builds queued behind it and no build running.

Publishing an image from the container stops it, which kills whatever is
building (the run dies with exit 143). Publish from a snapshot instead —
`incus snapshot create`, then `incus publish <container>/<snapshot>` — or do it
when nothing is queued.

### `XDG_RUNTIME_DIR`

`tests/run.sh` runs the agent's Wayland compositor against wlroots, which
insists on a private runtime directory. An `incus exec` has none, so the runner
must set one (`XDG_RUNTIME_DIR=/run/ghostty-build`, created `chmod 700`) or
`test_wayland_compositor` fails with `FAIL: backend: XDG_RUNTIME_DIR is not set`
on every remote run while passing on a workstation.

## Dalamud assemblies

Two ways in, neither of which puts game files in git or in a published image:

* `tools/build-remote.sh` pushes the launcher's dev assemblies
  (`~/.xlcore/dalamud/Hooks/dev` by default, `DALAMUD_LIB_PATH` to override)
  into the container per build, re-pushing only when they change.
* `NO_DALAMUD_PUSH=1`, or no assemblies at that path, falls back to the
  dalamud-distrib zip that `toolchain.env` pins by commit, sha256 and API level;
  `tools/ci/run.sh` downloads it into the container's cache. This is what CI
  uses and what a container on a machine without a launcher gets.

The Umbra reference assemblies come from the pinned `umbra-dist` checkout in
`vendor/`; without `Umbra.dll` the widget is skipped, as locally.

## Verified

2026-09-19, container `fedora:ghostty-build` (Fedora 44, 8 CPUs, 32 GiB), tree
at the tip of `remote-windows`:

* `tools/ci/run.sh test` in the container: the host half of `tools/build.sh` and
  every host test, ending in `ALL OK`, `test_capture_wayland` included.
* `tools/ci/run.sh build`: Nelua, libghostty-vt for host and Windows, Lua for
  both, `ghostty_core.dll`, `ghostty_loader.dll`, `ghostty-agent`,
  `ghostty-agent.exe`, `GhosttyDalamud.dll`, the Umbra widget — then `build/dist`
  copied back to the worktree.

Timings, logs and the comparison against a local build are in the dated working
directory `fedora-build-2026-09-19/` on the workstation, together with a
standalone `setup-container.sh`/`provision.sh` pair that provisions the same
container from scratch without this repository.

Not verified: loading a remotely built plugin in the game (that is
`tools/install-dev.sh`'s and the in-game selftest's job), the `package` and
`ingame` stages, and `MAC=1` cross-compilation.

## The other projects

`xiv-mcp` and `almanac-dalamud` want the same three pieces: a provisioned
container with a cache volume, a sync of the current worktree, and a runner that
holds the build lock. What changes is the toolchain the container needs (a .NET
SDK, and Go or Python where those projects use them) and the entry point the
runner calls. Either give each project a container of its own, or add its
toolchain here and give it its own checkout directory on the cache volume; the
lock already makes concurrent builds take turns.
