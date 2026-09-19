# CI

Builds, tests and packaging run from one script, `tools/ci/run.sh`, whether in
GitHub Actions, on a self-hosted runner or in a local shell. The workflows only
set up .NET, restore caches and call it.

## What runs where

| Trigger | Workflow | Runs | Output |
| --- | --- | --- | --- |
| push to any branch, pull request from a fork, manual | `.github/workflows/ci.yml` | `tools/ci/run.sh test build` | artifact `ghostty-dalamud-<sha>` = `build/dist/` (kept 14 days) |
| tag `v*` | `.github/workflows/release.yml` | `tools/ci/run.sh all` | GitHub Release for the tag with `build/release/*` (plugin zip, pluginmaster JSON) |
| push to `main`, manual; never pull requests or forks | `.github/workflows/ingame.yml` | ci.yml's artifact of the commit, then `tools/ci/run.sh ingame` on the gaming PC after the owner approves | artifact `ingame-report-<sha>-<attempt>` (kept 30 days); see [In-game tests](#in-game-tests) |

Changes that touch only Markdown or `docs/` do not start CI. A pull request from
a branch of this repository is not built twice: its push already ran. A newer
push to the same branch or pull request cancels the older run; release runs are
never cancelled.

`ci.yml` and `release.yml` run with the default `GITHUB_TOKEN` only. `ci.yml` has
`contents: read`; `release.yml` has `contents: write` on its one job, which is
what creating the release needs. `ingame.yml` has `contents: read` and
`actions: read` and one secret, `XIVMCP_CI_TOKEN`, stored in the `ffxiv-live`
environment. Actions are pinned by commit SHA. No workflow uses
`pull_request_target`.

## `tools/ci/run.sh`

```sh
tools/ci/run.sh test            # host dependencies, then tests/run.sh
tools/ci/run.sh build           # pinned toolchains + tools/build.sh -> build/dist/
tools/ci/run.sh all             # test, build, package
tools/ci/run.sh ingame          # the build into the running game, /term selftest (gaming PC only)
```

| Stage | Does |
| --- | --- |
| `deps` | Zig (from `PATH` if it is the pinned version, else fetched), checks for the .NET 10 SDK, the pinned Dalamud reference assemblies, `tools/fetch-vendor.sh`, and the Umbra reference assemblies from `vendor/umbra-dist` |
| `test` | `tools/build.sh` with `SKIP_WIN=1 SKIP_SHIM=1` (Nelua, host libghostty-vt, host Lua, agent), then `tests/run.sh` |
| `build` | `deps`, then `tools/build.sh` |
| `package` | `tools/package.sh` if the checkout has it (otherwise it says so and does nothing), then copies the `.zip` and `pluginmaster*.json`/`repo.json` files it wrote under `build/` into `build/release/` |
| `all` | `test`, `build`, `package` |
| `ingame` | `tools/ci/ingame.sh`, see [In-game tests](#in-game-tests); never part of `all` |

Environment (nothing else configures it):

| Variable | Default | Meaning |
| --- | --- | --- |
| `ZIG` | `zig` on `PATH` when it is `ZIG_VERSION`, else fetched | Zig binary |
| `DOTNET` | `dotnet` on `PATH`, else `~/.dotnet/dotnet` | .NET 10 SDK; not needed with `SKIP_SHIM=1` |
| `DALAMUD_LIB_PATH` | the pinned dalamud-distrib zip, fetched into the cache | Dalamud reference assemblies |
| `UMBRA_LIB_PATH` | `vendor/umbra-dist/dist` | Umbra reference assemblies; when there is no `Umbra.dll` the build continues with `SKIP_UMBRA=1` and says so |
| `SKIP_SHIM`, `SKIP_UMBRA`, `SKIP_WIN`, `SKIP_DEPS` | | as for `tools/build.sh`; `SKIP_DEPS=1` also makes `test` reuse the host builds already in `build/` |
| `CI_CACHE_DIR` | `${XDG_CACHE_HOME:-~/.cache}/ghostty-dalamud-ci` | where fetched toolchains live |
| `ZIG_GLOBAL_CACHE_DIR` | `${XDG_CACHE_HOME:-~/.cache}/zig-global` | Zig's package and build cache |

### Pins

Everything fetched is pinned in `toolchain.env` and checked before use:

* Zig: `ZIG_VERSION` and `ZIG_SHA256_<ARCH>_LINUX`, from
  `https://ziglang.org/download/index.json`.
* Dalamud: `latest.zip` of goatcorp/dalamud-distrib at `DALAMUD_DISTRIB_COMMIT`,
  checked against `DALAMUD_DISTRIB_SHA256`; its `version` file at that commit
  must start with `DALAMUD_API_LEVEL`. To move to a newer Dalamud: take the
  current commit (`git ls-remote https://github.com/goatcorp/dalamud-distrib main`),
  download `https://raw.githubusercontent.com/goatcorp/dalamud-distrib/<commit>/latest.zip`,
  put its `sha256sum` and the commit in `toolchain.env`.
* Lua (`LUA_SHA256`) and the git checkouts (by commit) as before, through
  `tools/fetch-vendor.sh`.

A checksum mismatch stops the run; nothing is piped into a shell.

`tools/fetch-vendor.sh` run by hand still downloads the unpinned
`DALAMUD_DISTRIB_URL` into `~/.cache/dalamud-dev`; `run.sh` sets
`DALAMUD_LIB_PATH` so CI never uses that path.

### Caching

`ci.yml` caches, keyed on the runner OS and architecture and the hash of
`toolchain.env`:

* `~/.cache/ghostty-dalamud-ci` (Zig, Dalamud assemblies) and `vendor/`;
* `~/.cache/zig-global`, `build/zig-cache-linux`, `build/zig-cache-win`
  (libghostty-vt builds).

Changing any pin in `toolchain.env` starts fresh caches. `release.yml` only
restores them. The ephemeral runner container additionally keeps `~/.cache` in
a podman volume (below).

## Choosing the runner

Both workflows run on
`${{ fromJSON(vars.CI_RUNS_ON || '"ubuntu-latest"') }}`. Set the repository
variable `CI_RUNS_ON` (Settings, Secrets and variables, Actions, Variables) to a
JSON value; no YAML change is needed:

| `CI_RUNS_ON` | Runs on |
| --- | --- |
| unset | GitHub-hosted `ubuntu-latest` |
| `["self-hosted","linux","ghostty-dalamud"]` | a self-hosted runner carrying all three labels |
| `"ubuntu-24.04"` | a specific GitHub-hosted image |

```sh
gh variable set CI_RUNS_ON --body '["self-hosted","linux","ghostty-dalamud"]'
gh variable delete CI_RUNS_ON     # back to GitHub-hosted
```

The repository is private: GitHub-hosted runs count against the account's
monthly Actions minutes and cache storage quota. A full build compiles
libghostty-vt twice with Zig and is the expensive part; the Zig caches make
repeat runs much cheaper. Self-hosted runs cost no minutes.

On GitHub-hosted runners the workflow installs the .NET 10 SDK with
`actions/setup-dotnet`; the runner image below already has it, so that step is
skipped there.

## Self-hosted runner (podman)

`tools/ci/runner/` holds a Fedora-based image and a start script for
**ephemeral** runners: each container registers, runs exactly one job,
deregisters and exits. It runs rootless as the user `runner`. The image
contains the build prerequisites (gcc, make, git, bash, curl, unzip, xz, zstd,
python3, the .NET 10 SDK, gh) and the GitHub Actions runner, whose tarball is
checked against a sha256 in the Containerfile. No token is stored in the image
or the repository.

On any host with podman (a VM, a bare host, or an Incus container with
`security.nesting=true` and podman installed inside it):

```sh
# 1. build the image (once, and after changing the Containerfile)
podman build -t localhost/ghostty-dalamud-runner -f tools/ci/runner/Containerfile tools/ci/runner

# 2. one runner, one job; the token comes from an account with admin access to the repository
export RUNNER_URL=https://github.com/OWNER/REPO
RUNNER_TOKEN="$(gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token)" \
  tools/ci/runner/start-runner.sh

# or keep serving jobs, fetching a fresh token for every container
RUNNER_TOKEN_COMMAND='gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token' \
  tools/ci/runner/start-runner.sh --loop
```

`start-runner.sh --help` lists its settings: `RUNNER_LABELS` (default
`ghostty-dalamud`; the runner also gets `self-hosted`, `Linux` and `X64` or
`ARM64`), `RUNNER_NAME`, `RUNNER_IMAGE`, `RUNNER_CACHE_VOLUME` (a named volume
mounted at `~/.cache` so toolchains and Zig caches survive between jobs; empty
disables it) and `PODMAN_RUN_ARGS` (for example `--memory 8g --cpus 4`). The
token reaches the container on stdin, so it is neither a command-line argument
nor visible in `podman inspect`, and the entrypoint drops it after
registration.

To keep a loop running after logout, wrap the `--loop` command in a user
systemd service (`loginctl enable-linger` for the user) or a Quadlet; that is
host configuration and not part of this repository.

A self-hosted runner executes whatever a workflow in this repository asks for.
That is acceptable for a private repository whose collaborators are trusted;
`ci.yml` never runs fork pull requests with secrets, but fork pull requests do
run on the runner, so do not point a public fork's CI at it.

## In-game tests

**Not yet run against the game.** Everything below is the design and the
code that implements it; see [What is and is not verified](#what-is-and-is-not-verified).

A commit can be tested inside the owner's running game: its core is swapped
in through the loader, `/term selftest all` runs there, and the JSON report
comes back as a workflow artifact. Nothing in it moves the character, acts in
combat or sends chat.

```
 GitHub                                  gaming PC, owner's user
+------------------------------+        +------------------------------------------------+
| push to main, or dispatch    |        | ephemeral runner, label ffxiv-live             |
|                              |        |                                                |
| ci.yml: test + build --------+-------->  build/dist: ghostty_core.dll, lua/,           |
|         (artifact)           |        |             build-info.json                    |
|                              |        |                                                |
| ingame.yml                   |  job   |  tools/ci/run.sh ingame                        |
|  environment ffxiv-live:     +-------->   1 initialize, get_player       --+           |
|  owner approves each run     |        |   2 get_dalamud_info,              | XivMcp    |
|                              |        |     list_plugins                   | 127.0.0.1 |
|                              |        |   5 execute_command                | :41800    |
|                              |        |     "/term selftest all"         --+           |
|                              |        |   3 lua/, ghostty_core.dll --> dev plugin dir  |
|                              |        |   4 wait: core-loaded.json = build id          |
| artifact ingame-report  <----+--------+   6 selftest/latest.json --> build/ingame/     |
+------------------------------+        +------------------------------------------------+

 In the game: Dalamud -> GhosttyDalamud.dll -> ghostty_loader.dll -> ghostty_core.live-<n>.dll
 (swapped in when ghostty_core.dll changes) -> /term selftest -> <config>/selftest/*.json
 XivMcp client ghostty-ci: its own token, Read tier, auto-approve for "/term selftest" only.
```

### `/term selftest`

`/term selftest [list | all | suite...]` (suites separated by spaces or
commas; nothing means `all`) runs one suite per frame inside the game and
writes `selftest/latest.json` in the plugin's config directory, plus a copy
named `selftest/report-<UTC time>-<build id>.json`, and one line to the
Dalamud log: `selftest <suites>: PASS|FAIL, n passed, n failed, n skipped in
n ms (build …); first failure …`. `/term selftest list` logs the suites.

| Suite | Checks | Skips when |
| --- | --- | --- |
| `core` | the core is active, every cimgui export is bound, `lua/init.lua` loaded, the build stamp is present, it runs under the loader | (embedded host) |
| `terminal` | a local terminal with no shell, never shown, fed fixed VT bytes; text, a truecolour foreground, a background run, bold and underline read back through libghostty's render state; closed again | |
| `render` | a fixed terminal drawn through recorded draw calls hashes to `SELFTEST_RENDER_HASH`, the value the host build gives (so the Windows libghostty renders like the host one); the same terminal drawn twice into an offscreen `ImDrawList` gives the same vertex, index and command counts | no ImGui, or cimgui lacks the draw list constructor |
| `world` | the live camera: position recovered from the view-projection matrix, depth grows forward, and 16 fixed points of a panel 6 yalms ahead project and hit-test back within 0.5 panel pixels | no character logged in |
| `settings` | `settings.lua` saved and read back in `selftest/scratch/` (never the player's file): current values, typed values, slider clamping; everything put back | |
| `themes` | every theme resolves; switching away and back gives the same colours (on a copy of the config) | this build has no `lua/themes.lua` |
| `bell` | every `/term bell` style and `demo` parse and the style is put back; every `/term showcase` entry and shot is well formed; nothing rings or opens | |
| `agent` | a terminal on ghostty-agent running `sh -c 'echo ghostty-selftest'` (`cmd.exe /c` on native Windows) shows the marker, exits 0 and is closed | the agent is off or not answering |
| `loader` | the core touches the write time of its own `ghostty_core.dll`, the loader swaps in a fresh copy of the same file, the new core carries on (`selftest/state.tsv`), checks that every agent terminal is back in the same view and `settings.lua` is unchanged, and does it once more ("swap back") | not under the loader, or a local (ConPTY, showcase) terminal is open, which a swap would close |

Timeouts are wall-clock bounds with a message naming what did not happen
(agent output 10 s, agent exit 5 s, a swap 15 s, the layout after a swap
20 s); no assertion depends on the clock. The world points come from a fixed
seed. The report carries the build id and commit stamped into the core by
`tools/build.sh` (`BUILD_COMMIT`, `BUILD_ID`, also in
`build/dist/build-info.json`), the plugin version from `GhosttyDalamud.json`,
the game version from `ffxivgame.ver`, the platform and UTC times. Every core
also writes `selftest/core-loaded.json` (build id, commit, time) on its first
frame, which is how CI knows the new build is the one running.

The pure parts are `core/selftest_logic.nelua` (`tests/test_selftest.nelua`),
the runner `core/app/selftest.nelua` (`tests/test_selftest_run.nelua`, in an
embedded core where the game-only suites skip) and `lua/selftest.lua`.

### `tools/ci/ingame.sh`

`tools/ci/run.sh ingame` runs it. In order:

1. `initialize` on XivMcp's endpoint as client `ghostty-ci`, then
   `get_player`. No answer, or no character logged in: prints
   `skipped: game not available (…)` and exits **3**. Nothing about the
   character is kept.
2. `get_dalamud_info` and the Ghostty and XivMcp entries of `list_plugins`
   go into the report header.
3. `lua/` (keeping an installed `lua/init.lua`, which may hold the agent
   token) and then `ghostty_core.dll` are copied into the dev plugin folder,
   each beside its target and renamed over it. `GhosttyDalamud.dll`, its
   `.json`, `.pdb` and `ghostty_loader.dll` are never written, so Dalamud
   never reloads managed code; the loader swaps the core within about two
   seconds.
4. Waits (60 s) for `selftest/core-loaded.json` newer than the install and
   naming this build's id.
5. `execute_command` with `/term selftest all` (`INGAME_SUITES`), then waits
   (240 s) for `selftest/latest.json` of a new, complete run of this build.
6. Writes `build/ingame/ingame-report.json` (`header` with the expected build,
   commit, XivMcp, Dalamud and plugin versions; `selftest` with the report),
   prints it, adds a table to the job summary, and exits 1 on any failed case.

Exit status: 0 passed (skipped cases included), 1 failed, 2 setup error, 3
game not available.

| Variable | Default | Meaning |
| --- | --- | --- |
| `XIVMCP_CI_TOKEN` | (required) | bearer token of XivMcp's `ghostty-ci` client; read from the environment only, handed to curl on stdin, never printed or written |
| `XIVMCP_URL` | `http://127.0.0.1:41800/mcp` | XivMcp's endpoint |
| `GHOSTTY_DEV_PLUGIN_DIR` | (required) | the dev plugin folder the game loads (with `GhosttyDalamud.dll` and `ghostty_loader.dll`) |
| `GHOSTTY_CONFIG_DIR` | `~/.xlcore/pluginConfigs/GhosttyDalamud` | the plugin's config directory, where `selftest/` is written |
| `INGAME_SUITES` | `all` | what `/term selftest` gets (suite names only) |
| `INGAME_DIST`, `INGAME_OUT` | `build/dist`, `build/ingame` | input and output |
| `INGAME_LOAD_TIMEOUT`, `INGAME_RUN_TIMEOUT` | 60, 240 | seconds |

It needs `curl` and `jq`. The same script works by hand on the gaming PC
after `tools/build.sh`, with the variables above.

### `.github/workflows/ingame.yml`

* Triggers: `workflow_dispatch` (inputs `suites`, and `build_here` to build on
  the gaming PC when there is no artifact) and push to `main`. Never
  `pull_request` or `pull_request_target`; the job does not run in forks.
* `runs-on: [self-hosted, ffxiv-live]`, `environment: ffxiv-live`,
  `permissions: contents: read, actions: read`, concurrency group
  `ingame-ffxiv-live` (one in-game run at a time, a newer one waits),
  `timeout-minutes: 15`.
* Takes `build/dist` from ci.yml's artifact of the same commit, waiting up to
  9 minutes for a ci.yml run still going. It only builds on the gaming PC when
  dispatched with `build_here`, since a build there competes with the game for
  memory.
* Runs `tools/ci/run.sh ingame` and uploads `build/ingame/ingame-report.json`.
  GitHub has no neutral job result, so a skip (exit 3) passes with the notice
  `skipped: game not available` and says so in the step summary.

### One-time setup (owner)

1. **Environment with approval.** Settings → Environments → New environment
   `ffxiv-live`; *Required reviewers*: yourself (leave *Prevent self-review*
   off); *Deployment branches and tags*: selected branches, `main`. Every run
   then waits for your click, like `sudo`. With `gh`:

   ```sh
   R=OWNER/REPO
   ID="$(gh api users/OWNER --jq .id)"
   gh api -X PUT "repos/$R/environments/ffxiv-live" --input - <<EOF
   {"reviewers":[{"type":"User","id":$ID}],
    "deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
   EOF
   gh api -X POST "repos/$R/environments/ffxiv-live/deployment-branch-policies" -f name=main
   ```

2. **XivMcp client.** In XivMcp, create the client `ghostty-ci` with its own
   token, the Read tier, and the auto-approve allowlist entry for exactly
   `/term selftest` (and nothing else; XivMcp is adding per-client tokens and
   this allowlist). Store the token as an environment secret, straight from
   your password manager:

   ```sh
   op read 'op://VAULT/XivMcp ghostty-ci/credential' | gh secret set XIVMCP_CI_TOKEN --env ffxiv-live --repo "$R"
   ```

3. **Paths.** Environment variables (only what differs from the defaults):

   ```sh
   gh variable set GHOSTTY_DEV_PLUGIN_DIR --env ffxiv-live --repo "$R" --body "$HOME/path/to/dev-plugin/GhosttyDalamud"
   gh variable set GHOSTTY_CONFIG_DIR --env ffxiv-live --repo "$R" --body "$HOME/.xlcore/pluginConfigs/GhosttyDalamud"
   ```

4. **Forks.** Settings → Actions → General → *Approval for running fork pull
   request workflows from contributors*: *Require approval for all external
   contributors*.

5. **The plugin** must be installed once as a dev plugin (`tools/install-dev.sh`)
   and enabled; CI only ever replaces its core and `lua/`.

### The runner on the gaming PC

The job has to reach XivMcp on the game's loopback port and write the dev
plugin folder and the config directory, so the runner lives on the gaming PC
under your user. Register it **ephemeral** (one job, then it deregisters)
with the label `ffxiv-live` and no other custom label, so ordinary CI never
lands on it, and start it only when you are about to approve a run.

**Podman (recommended).** The runner image from `tools/ci/runner/` (it has
curl, jq and gh), host network for the loopback port, and only the two
directories mounted, at the same paths, as your user:

```sh
podman build -t localhost/ghostty-dalamud-runner -f tools/ci/runner/Containerfile tools/ci/runner
P="$HOME/path/to/dev-plugin/GhosttyDalamud"
C="$HOME/.xlcore/pluginConfigs/GhosttyDalamud"
RUNNER_URL=https://github.com/OWNER/REPO RUNNER_LABELS=ffxiv-live RUNNER_NAME=ffxiv-live-1 \
PODMAN_RUN_ARGS="--network host --userns keep-id -v $P:$P -v $C:$C" \
RUNNER_TOKEN="$(gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token)" \
  tools/ci/runner/start-runner.sh
```

**Directly.** The GitHub runner unpacked in a directory of your user,
`./config.sh --url https://github.com/OWNER/REPO --token … --ephemeral
--labels ffxiv-live --name ffxiv-live-1`, then `./run.sh`. Simpler, but the
job then runs with everything your user can reach (home directory, keys,
password manager sessions), not just the two folders and the network.

### Security

* **Public repository.** Anyone can open a pull request, and a pull request
  can change workflow files. `ingame.yml` never runs for pull requests, and
  the fork approval setting (step 4) keeps a fork's edited workflow from
  running unasked; the runner being offline except while you approve a run
  means a job aimed at `ffxiv-live` has nothing to run on.
* **Approval.** The `ffxiv-live` environment holds the job until you
  approve it, and only then does the job get `XIVMCP_CI_TOKEN`. Approve only
  commits you would run in your game: the job swaps that commit's
  `ghostty_core.dll` into the game process, where it runs with the game's
  rights.
* **Token.** `ghostty-ci`'s token opens the Read tier and exactly one
  command, `/term selftest`; it cannot move the character, chat or run other
  commands. It lives in the environment secret and your password manager,
  never in the repository or a file on the runner.
* **The runner sees the game.** Loopback access reaches every service on the
  PC, and the job can write the plugin and config folders. The container
  limits the rest of the file system; an ephemeral runner leaves nothing
  registered after its one job.

## Cutting a release

1. Make sure `main` is green and that `tools/package.sh` exists on it (the
   release fails with "no build/release/*.zip" otherwise).
2. Bump the version wherever `tools/package.sh` reads it, commit.
3. Tag and push:

   ```sh
   git tag -a v0.5.0 -m "v0.5.0"
   git push origin v0.5.0
   ```

4. `release.yml` tests, builds and packages, then creates the GitHub Release
   `v0.5.0` with generated notes and the files in `build/release/`. A tag with
   a `-` (`v0.5.0-rc1`) becomes a pre-release. Re-running the workflow for an
   existing release replaces its files.

### The two channels, and the plugin repository

`tools/package.sh` writes `latest.zip` (always that name) and the plugin's entry
for a Dalamud plugin repository, `pluginmaster.json`. The site at
<https://spacegho.st/mods/ffxiv/plugins.json> assembles its listing from those
two release assets, so a release reaches players without deploying anything and
without a token in this repository:

| tag | release | what the listing shows |
| --- | --- | --- |
| `v0.5.0` | the release for that tag, and `releases/latest/download/…` follows it | the stable version everyone gets |
| `v0.5.1-test.1` | a prerelease for that tag, **and** the floating `testing` release is moved onto it (`releases/download/testing/…`) | the testing version, only for players who tick testing on Ghostty's entry |

A test build sets `TESTING=1` for `tools/package.sh` (the workflow does this for
any tag with a `-`), which writes `pluginmaster-testing.json` instead. Nothing
about the stable channel changes when a test build is cut.

## What is and is not verified

`tools/ci/run.sh deps`, `test` and `build` have been run locally. The workflows
pass `actionlint` and the scripts pass ShellCheck, but the workflows, the
caches, the release upload and runner registration are only exercised on
GitHub; the first runs there are their test.

The in-game parts have not run against the game at all: `/term selftest`
has run only in an embedded core on the host (`tests/test_selftest_run.nelua`,
where the ImGui, camera, agent and loader suites skip), `tools/ci/ingame.sh`
only against a stand-in for XivMcp and the game, and `ingame.yml` only through
`actionlint`. The Windows core with the self-test compiles to an object file;
it has not been linked or loaded.
