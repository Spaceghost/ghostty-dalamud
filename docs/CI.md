# CI

Builds, tests and packaging run from one script, `tools/ci/run.sh`, whether in
GitHub Actions, on a self-hosted runner or in a local shell. The workflows only
set up .NET, restore caches and call it.

## What runs where

| Trigger | Workflow | Runs | Output |
| --- | --- | --- | --- |
| push to any branch, pull request from a fork, manual | `.github/workflows/ci.yml` | `tools/ci/run.sh test build` | artifact `ghostty-dalamud-<sha>` = `build/dist/` (kept 14 days) |
| tag `v*` | `.github/workflows/release.yml` | `tools/ci/run.sh all` | GitHub Release for the tag with `build/release/*` (plugin zip, pluginmaster JSON) |

Changes that touch only Markdown or `docs/` do not start CI. A pull request from
a branch of this repository is not built twice: its push already ran. A newer
push to the same branch or pull request cancels the older run; release runs are
never cancelled.

Both workflows run with the default `GITHUB_TOKEN` only. `ci.yml` has
`contents: read`; `release.yml` has `contents: write` on its one job, which is
what creating the release needs. Actions are pinned by commit SHA. No workflow
uses `pull_request_target` or any secret.

## `tools/ci/run.sh`

```sh
tools/ci/run.sh test            # host dependencies, then tests/run.sh
tools/ci/run.sh build           # pinned toolchains + tools/build.sh -> build/dist/
tools/ci/run.sh all             # test, build, package
```

| Stage | Does |
| --- | --- |
| `deps` | Zig (from `PATH` if it is the pinned version, else fetched), checks for the .NET 10 SDK, the pinned Dalamud reference assemblies, `tools/fetch-vendor.sh`, and the Umbra reference assemblies from `vendor/umbra-dist` |
| `test` | `tools/build.sh` with `SKIP_WIN=1 SKIP_SHIM=1` (Nelua, host libghostty-vt, host Lua, agent), then `tests/run.sh` |
| `build` | `deps`, then `tools/build.sh` |
| `package` | `tools/package.sh` if the checkout has it (otherwise it says so and does nothing), then copies the `.zip` and `pluginmaster*.json`/`repo.json` files it wrote under `build/` into `build/release/` |
| `all` | `test`, `build`, `package` |

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

## What is and is not verified

`tools/ci/run.sh deps`, `test` and `build` have been run locally. The workflows
pass `actionlint` and the scripts pass ShellCheck, but the workflows, the
caches, the release upload and runner registration are only exercised on
GitHub; the first runs there are their test.
