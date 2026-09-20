# Building on another machine

The gaming PC has 15 GB of RAM and spends it on the game and a local LLM. A
full `tools/build.sh` there gets killed for low memory, so **the default way to
build this project is in an Incus container on a separate build host**,
with the artifacts copied back to the gaming PC for installing and testing in
the game.

```sh
tools/build-container.sh create   # once per Incus host: the container and its toolchain
tools/build-remote.sh test        # tests/run.sh in the container
tools/build-remote.sh             # a full build; build/dist/ comes back here
tools/install-dev.sh              # on THIS machine, into the game
```

The loop is: **build in the container → copy `build/dist/` back here →
install and test in the game → push to GitHub → the next build starts from
that**. The container keeps its toolchain and its caches between builds, so
only the first build pays for them.

## The machines

| Role | Does | Does not |
| --- | --- | --- |
| the gaming PC | installs into the game, runs the agent, `/term selftest` in the running game, `tools/install-dev.sh`, git | compile |
| the build host | every heavy build and the whole test suite, in the `ghostty-build` container. Reference setup: 8 cores, 62 GB | touch the game |

The build host is an Incus remote on the gaming PC (`incus remote list`), so
the scripts talk to its daemon over TLS; nothing here needs an ssh session or a
shell on the host. Remotes are named per machine, so the name lives outside the
repository: put it in an untracked `build.env` beside `toolchain.env`.

```sh
incus remote add mybuilder https://<build-host>:8443        # preferred
echo BUILD_REMOTE_NAME=mybuilder > build.env               # what the scripts look for
INCUS='ssh <build-host> incus' tools/build-container.sh create   # fallback, if incus over ssh is all there is
```

With neither, the scripts fall back to the local Incus daemon
(`INCUS_REMOTE=local`), which is how a laptop builds for itself.

## `tools/build-container.sh`

| Command | Does |
| --- | --- |
| `create` | launches `ghostty-build` from the image pinned in `toolchain.env`, attaches the shared cache volume, then `update` |
| `update` | installs/refreshes the toolchain; idempotent, so running it twice changes nothing |
| `status` | versions of everything in the container and the size of the shared cache |
| `shell [cmd]` | a shell in the container, in the checkout |
| `publish [alias]` | an image of the container, for `incus copy` / `incus move` |
| `delete [--cache]` | deletes the container; `--cache` also deletes the shared cache volume |
| `cache-export FILE`, `cache-import FILE` | carry the shared cache between Incus hosts |
| `cache-stats`, `cache-reset` | sccache statistics; empty the cache |

Everything it installs is pinned in `toolchain.env`:

* `BUILD_IMAGE` — the base image by **fingerprint**, so a fresh `create` on any
  Incus host is the same container. images.linuxcontainers.org expires old
  serials; when the pull fails the script falls back to `BUILD_IMAGE_ALIAS`
  (`images:fedora/44`) and prints the command that gives the new fingerprint to
  put back in `toolchain.env`.
* `BUILD_PKGS_PINNED` — exact NEVRs of the packages whose ABI the built binaries
  inherit: `wlroots`, `libwayland-server`, `libxkbcommon`, `pixman` (the agent
  links them and **runs on this machine**, so they must match Fedora 44 here and
  the versions `vendor/wayland-sdk`'s headers are taken from), plus `zig` and
  `dotnet-sdk-10.0`. If Fedora has retired an exact build the script installs the
  bare name and warns instead of dead-ending.
* `BUILD_PKGS` — build tools that do not reach a shipped binary's ABI, so they
  track the image's repositories: gcc, make, git, rsync, python3, cpio, jq,
  sccache, and what the test suite's real compositor needs (`xorg-x11-server-Xwayland`,
  `yad`/`gtk3` for a live Wayland and X11 client, `librsvg2-tools` for the
  desktop-entry icon cache).

Zig comes from Fedora when it is exactly `ZIG_VERSION`, which on Fedora 44 it is
(`zig-0.16.0-1.fc44`, at `/usr/bin/zig`); otherwise the pinned, sha256-checked
release tarball is unpacked at `/opt/zig-<version>` and symlinked to
`/usr/local/bin/zig`. Both are fixed paths, which matters for the cache (below).

### Moving the container between hosts

`publish` makes an image of the container, which is the portable form of the
toolchain:

```sh
tools/build-container.sh publish                                 # -> image 'ghostty-build' on the remote
incus image copy "$BUILD_REMOTE_NAME:ghostty-build" local: --alias ghostty-build
incus launch ghostty-build ghostty-build                         # a ready container elsewhere
```

The container itself moves too, though its cache volume does **not** follow it
(a disk device is not part of an instance copy) — use `cache-export` /
`cache-import` for that:

```sh
incus copy "$BUILD_REMOTE_NAME:ghostty-build" otherhost:ghostty-build
incus move "$BUILD_REMOTE_NAME:ghostty-build" otherhost:ghostty-build
```

Nothing in the image is secret: the Dalamud reference assemblies are pushed per
build and live outside it (below), so an image can be copied freely between your
own hosts.

## `tools/build-remote.sh`

| Command | Does |
| --- | --- |
| `build` (default) | pushes the checkout, runs `tools/ci/run.sh build` in the container, pulls `build/dist/` back here |
| `test` | `tools/ci/run.sh test` in the container — the host half of `tools/build.sh` and then the whole of `tests/run.sh`, streamed |
| `all` | `test`, then `build` |
| `push`, `pull` | only send the checkout, only fetch `build/dist/` |
| `shell [cmd]`, `stats` | a shell in the container; shared-cache statistics |

`SKIP_WIN`, `SKIP_SHIM`, `SKIP_UMBRA`, `SKIP_DEPS`, `SKIP_WAYLAND` and `MAC` are
passed through to `tools/build.sh` unchanged.

What goes over the wire is what git considers part of the worktree
(`git ls-files --cached --others --exclude-standard`), so `.gitignore` is
respected and `build/` and `vendor/` stay out of the transfer: inside the
container they are symlinks into the shared cache volume. Two runs at once are
safe — the container serializes them on `/cache/build.lock` — and running the
same build twice gives the same result.

`build-remote.sh` creates the container if it is not there yet, so
`tools/build-remote.sh test` on a machine that has never built works on its own.

### Dalamud and Umbra reference assemblies

The C# shim compiles against Dalamud's assemblies. `build-remote.sh` pushes
`~/.xlcore/dalamud/Hooks/dev/*.dll` (48 files, `DALAMUD_LIB_PATH` overrides the
directory) into `/build/dalamud-dev` in the container **per build**, re-pushing
only when they change.

**These are game binaries.** They are not in git, not in the published image and
not in the cache volume; they exist only in the container's own filesystem while
it lives. `NO_DALAMUD_PUSH=1` skips the push, and the container then uses the
pinned, checksum-verified dalamud-distrib download that `tools/ci/run.sh`
already does — which is what CI uses and what a machine without the game should
use. Umbra's assemblies come from `vendor/umbra-dist` (pinned, public), so they
need no push; `SKIP_UMBRA=1` builds without the widget.

## The shared compiler cache

Every build container, on any Incus host, works out of one cache so that a
fresh container starts warm.

**On a host: an Incus custom storage volume.** `ghostty-cache` is created once
per remote, `security.shifted=true` so several unprivileged containers can share
it, and attached to every build container at `/cache`. It holds:

| Path | What |
| --- | --- |
| `/cache/vendor` | the pinned `vendor/` checkouts and downloads (ghostty, nelua, gc-cimgui, umbra-dist, Lua, stb, the wayland-sdk RPM extracts) |
| `/cache/zig-global` | `ZIG_GLOBAL_CACHE_DIR` |
| `/cache/zig-cache-linux`, `/cache/zig-cache-win` | the two libghostty-vt builds |
| `/cache/nelua-cache`, `/cache/win-cache`, `/cache/win-cache-agent` | Nelua's generated C and objects |
| `/cache/ghostty-vt-*`, `/cache/lua-linux`, `/cache/lua-win` | built dependency outputs (what `SKIP_DEPS=1` reuses) |
| `/cache/nuget` | `NUGET_PACKAGES` for the C# shim |
| `/cache/ci` | `CI_CACHE_DIR`: fetched Zig, the pinned dalamud-distrib |
| `/cache/sccache` | sccache's storage |

**Across hosts: `cache-export` / `cache-import`.** A `tar --zstd` of the volume,
streamed out of one container and into another:

```sh
tools/build-container.sh cache-export /tmp/ghostty-cache.tar.zst
INCUS_REMOTE=otherhost tools/build-container.sh create
INCUS_REMOTE=otherhost tools/build-container.sh cache-import /tmp/ghostty-cache.tar.zst
```

### Why this and not an object store

sccache's S3/R2/webdav backends are the usual answer to "distributed cache", and
they are supported here as a switch, not the default:

* The cacheable work is small and the cache is big. Almost everything this
  project compiles goes through Nelua, which **compiles and links in one
  invocation**; sccache only caches `-c` compiles, so the Nelua steps are
  uncacheable by it no matter which backend is behind it. What sccache does cache
  is the Lua objects (64 per build). The expensive, reusable artifacts are the
  two libghostty-vt builds and the Nelua and Zig caches — plain directories, best
  shared as a directory.
* A network round trip per compile to R2 or a MinIO/Garage container would cost
  more than it saves at this size, and adds a service and a credential to
  maintain. The free-tier argument for R2 is real, but it applies to bytes
  stored, not to the shape of this build.
* An Incus volume is already replicated where it matters: the build host is one
  machine, and the second machine is off limits for builds by policy.

To switch to an object store anyway, put the settings in
`~/.config/ghostty-dalamud/build-cache.env` (outside git; `BUILD_CACHE_ENV`
overrides the path) and re-run `tools/build-container.sh update`, which writes
them into the container's environment:

```sh
# ~/.config/ghostty-dalamud/build-cache.env  — never committed
SCCACHE_BUCKET=ghostty-build-cache
SCCACHE_ENDPOINT=https://<account>.r2.cloudflarestorage.com
SCCACHE_REGION=auto
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
```

Credentials belong in that file (or in 1Password, read with `op` into it), never
in the repository and never in a published image. This path has not been
exercised here; the volume-backed cache is what is in use and what the numbers
below come from.

### Keeping the keys stable across hosts

sccache keys the preprocessed source, which carries absolute paths, so the paths
must not depend on the host, the user or the worktree name. Hence:

* the checkout is always at `/build/ghostty-dalamud` in the container
  (`BUILD_CONTAINER_DIR`), whatever it is called on the machine that pushed it;
* the compiler is always at `/usr/bin/zig` or `/opt/zig-<version>/zig`, and
  `sccache` drives `tools/zig-cc*.sh`, whose path is inside the fixed checkout;
* every container comes from the same pinned image, so the compilers are the same
  builds;
* `SOURCE_DATE_EPOCH` is set from the commit being built, so the same commit
  hashes the same wherever it is built.

`sccache` cannot drive `zig` directly — it probes a compiler with `-E`, which
`zig` only understands after `cc` — so `tools/zig-cc.sh`, `zig-cc-win.sh` and
`zig-cc-mac*.sh` re-exec themselves under sccache when `GHOSTTY_SCCACHE=1`
(which `build-remote.sh` sets). Locally, with the variable unset, they are the
plain `zig cc` wrappers they always were.

### Adding another Incus location

1. `incus remote add <name> https://<host>:8443`
2. `INCUS_REMOTE=<name> tools/build-container.sh create`
3. optional, to start warm:
   `tools/build-container.sh cache-export /tmp/c.tar.zst && INCUS_REMOTE=<name> tools/build-container.sh cache-import /tmp/c.tar.zst`
4. `INCUS_REMOTE=<name> tools/build-remote.sh test`

A second container on a host that already has one needs no remote at all — it
shares the same volume:

```sh
BUILD_CONTAINER_NAME=ghostty-build-2 tools/build-container.sh create
BUILD_CONTAINER_NAME=ghostty-build-2 tools/build-remote.sh
```

## What stays on this machine

Remote building stops at the artifacts. These are local and cannot be moved:

* **Installing into the game** — `tools/install-dev.sh` writes the dev plugin
  folder XIVLauncher loads.
* **Restarting or running `ghostty-agent`** — the agent drives this machine's
  terminals and compositor.
* **`/term selftest` in the running game** and everything in
  `tools/ci/ingame.sh` — they need the game process, XivMcp on loopback and the
  plugin config directory. See [CI.md](CI.md), "In-game tests".
* **`git push`** — the repository lives here.

The agent binary is built in the container and **run here**, so its glibc and
library sonames have to match this machine. Both are Fedora 44 and the container
pins the same wlroots, wayland, xkbcommon and pixman builds; after a build,
`ldd build/dist/ghostty-agent` here is the check that it does.

## Observed

On 2026-09-19, against a build host with 8 cores and 62 GB, container `ghostty-build`
from the pinned Fedora 44 image:

| Step | Time |
| --- | --- |
| `tools/build-container.sh create` (toolchain from scratch) | 2 min 47 s |
| `tools/build-remote.sh test` — the whole of `tests/run.sh`, `ALL OK` | 3 min 11 s |
| `tools/build-remote.sh` — full build with the Wayland backend and the Windows targets, warm caches | 2 min 53 s |
| the same in a **second, fresh** container sharing only the cache volume | 4 min 11 s, sccache **64 hits / 64 requests, 100 %** |

Verified on this machine afterwards: `ghostty_core.dll`, `ghostty_loader.dll`
and `ghostty-agent.exe` are `PE32+ … x86-64`, `ghostty-agent` is a 64-bit ELF,
`ldd` resolves every one of its libraries here (including
`libwlroots-0.20.so`, `libwayland-server.so.0`, `libxkbcommon.so.0`,
`libpixman-1.so.0`), and `ghostty-agent --help` runs.

Not exercised here, and so not claimed: the sccache object-store backend, and
`incus copy`/`incus move` of the container to a second host — `publish` was run
and the image exists on the build host, but there was no second build host to
copy it to. The in-game parts are unchanged and still local.
