# Where a build runs

The rule: **heavy work runs on the build host. It runs on the gaming PC only
when the game is not running there and the machine has memory to spare. If the
game starts while heavy work is running locally, the work moves to the build
host at once and the game is not held up.**

Nobody has to remember this. `tools/build.sh` and `tests/run.sh` ask
`tools/where-build.sh` before they do anything, and a small user service
(`tools/ffxiv-guard.sh`) evicts local work when the game appears.

```sh
tools/build.sh                     # placed automatically
tests/run.sh                       # placed automatically
tools/where-build.sh --why         # where would it run right now, and why
tools/run-placed.sh jobs           # where did recent builds run
tools/ffxiv-guard.sh install       # once per machine: the eviction service
```

## The decision (`tools/where-build.sh`)

In order:

1. `FORCE_BUILD_HOST=local` or `=remote` (or an Incus remote's name): that.
2. The game, its launcher or the FFXIV login session is running
   (`BUILD_GAME_PATTERN`: `ffxiv_dx11.exe`, `ffxivlauncher.exe`,
   `XIVLauncher[.Core]`, `ffxiv-session`) → **remote**. If the build host does
   not answer, the build is **refused** (exit 3). There is no branch that
   compiles next to the game.
3. `MemAvailable` under `BUILD_MIN_AVAIL_MB` (6144), or swap more than
   `BUILD_MAX_SWAP_PCT` (80 %) used → **remote**. If the build host does not
   answer and the game is off, it runs here with a warning.
4. Otherwise → **local**.

The build host is the Incus remote `BUILD_REMOTE` (default: `$INCUS_REMOTE`,
else `BUILD_REMOTE_NAME` from `build.env` or `toolchain.env`). `--json` prints
every input.

`BUILD_PLACEMENT=0` switches placement off: the build container, CI
(`tools/ci/run.sh` sets it) and anything already placed use it, so nothing
routes twice. `tools/build-remote.sh` and `tools/test-remote.sh` still go
straight to the build host, as before.

## Jobs (`tools/run-placed.sh`)

A placed command is a job: a directory under
`~/.local/state/ghostty-build/jobs/<name>-<time>-<id>/` holding `meta`
(key=value: host, state, exit, reason, evicted…), `log`, `status`, and while it
runs locally `pgid`. `jobs`, `show <id>`, `log <id|latest> [-f]` read them;
`cat` works as well. The caller of `run-placed.sh` gets the job's output, its
exit status and its artifacts whichever machine ran it.

Local work runs in a session of its own (`setsid`), so it can be stopped as one
process group without touching the wrapper, the calling shell or anything else.

`--local-only` marks work that belongs on this machine (installing into the
game, the agent, git): it is never routed and never evicted.
`FORCE_BUILD_HOST=local` is treated the same way — a human said "here".

## When the game starts mid-build (`tools/ffxiv-guard.sh`)

The guard is a systemd user service polling once a second
(`GUARD_INTERVAL`). When the game appears it, for every running local job:

1. writes the job's `evict` marker,
2. sends SIGTERM to the job's process group (SIGKILL after
   `GUARD_KILL_GRACE`, 5 s, from a background subshell),
3. and is done. The job's wrapper sees the marker and re-runs the job on the
   build host under the same job id; if the wrapper is gone, the guard starts
   `run-placed.sh resume <id>` itself.

The game never waits on a transfer: the only thing between its launch and a
quiet machine is one poll interval and a signal. The work restarts on the build
host from the beginning — warm caches there make that cheap — it is not
live-migrated (see below).

The guard signals only process groups recorded by `run-placed.sh`, never one
containing a process that matches the game pattern, never `--local-only` jobs,
never its own group. It logs to `~/.local/state/ghostty-build/guard.log`.

## Other projects

`tools/ffxiv-guard.sh install` also links `~/.local/bin/build-where` and
`~/.local/bin/build-place` to these scripts, so every project on the machine
uses the same decision and the same jobs:

```sh
build-place --name test -- npm test
build-place --name build --local 'dotnet build' --pull 'bin'
```

Without a `--remote` dispatcher, the generic path is used: the worktree (what
git considers part of it) is sent to a container on the build host, the command
runs there under a per-project lock (`flock -o -w`, so build daemons cannot
inherit the lock), and the `--pull` paths come back. Per-project settings live
in the project's `.build-placement` or, to keep them out of the repository, in
`~/.config/build-placement/projects/<directory name>.env`:

```sh
PLACE_CONTAINER=ghostty-build        # container on the build host
PLACE_REMOTE_DIR=/build/<project>
PLACE_PULL='bin TestResults'
PLACE_REMOTE_DISPATCH=''             # or the project's own remote-build script
```

The container must have the project's toolchain; the generic path does not
install one (`PLACE_REMOTE_SETUP` runs a command in the container before each
job if you need it).

## Why not `incus move`

Moving a running local container to the build host would be the elegant
version. On the gaming PC it is not available: there is an `incus` *client*
there and no Incus daemon (`incus info` → "daemon doesn't appear to be
started"; no `incusd`, no `incus.service`), and the host is an image-based
system where adding one means layering the package and rebooting. Even with a
daemon, live migration of a container needs CRIU, which Incus documents as
limited and which is normally absent, so the realistic container path is
stop → move → start → re-run the interrupted command — the same restart this
mechanism does, plus the transfer of a multi-GB root filesystem while the game
is starting. What a local daemon would add is a local build environment
identical to the remote one (same image, same provisioning), not a better
eviction. Not tested here, because there is no local daemon to test with.

## Verified

2026-09-19, gaming PC → build host container, game closed throughout; the
"game" in these tests was a stand-in process named `ffxiv_dx11.exe`:

* the decision: `local` with the game off and memory free; `remote` with the
  stand-in running; `remote` under the memory threshold; refusal (exit 3) with
  the stand-in running and an unreachable remote; `FORCE_BUILD_HOST` both ways.
* a job placed remote through the generic path: worktree sent, command run in
  the container, artifact pulled back, exit status 0.
* eviction: a 30 s local job, stand-in started 5 s in. Stand-in start →
  SIGTERM to the job's group: **0.26 s** at `GUARD_INTERVAL=0.2` (so at most
  about one interval plus 0.1 s; ≈1.1 s at the default). The wrapper
  re-dispatched the same job id to the build host, the artifact came back
  stamped with the container's hostname, the caller saw exit 0, and `jobs`
  shows the job as `remote … (evicted)`.

Not verified: eviction against the real game (it was not running, and nobody
started it for a test); eviction of a real compile rather than a sleep loop
(zig/dotnet/VBCSCompiler trees are expected to die with their process group;
SIGKILL after 5 s is the backstop); the guard's wrapper-is-gone `resume` path;
the `tools/build.sh` local branch end to end on this machine outside the timing
run below; any `incus move`.

### Local against remote, same tree

Same day, game closed, both at once on their own machines: `tools/ci/run.sh
build` of this tree from an empty `build/` and an empty Zig global cache,
`vendor/` (with Nelua built) already present on both.

| Where | Wall clock |
| --- | --- |
| gaming PC (16 threads, 15 GB, ~7.8 GB available at the start), no sccache | **3 min 25 s**, peak RSS of the largest process 0.9 GB |
| build host container (8 CPUs, 32 GiB), shared sccache | **3 min 57 s** |

One run each, so treat the difference as "about the same, the gaming PC a
little faster when it is idle". The build host's advantage is not speed: it is
that the build does not compete with the game for 15 GB. Warm-cache builds on
the build host are in [REMOTE_BUILD.md](REMOTE_BUILD.md).

`tools/ffxiv-guard.sh install` / `uninstall` were run once: the unit came up
`active`, and was removed again, because it should point at the permanent
checkout, not at the worktree this was developed in.
