# Installing, packaging, and submitting Ghostty

Status: **preparation, not an official-list approval or a published release**.
The source repository is private. Do not change its visibility until the
maintainer has completed the source/history privacy review. Renaming the
manifest author does not scrub README/About text or old commits.

## Build a candidate for your own plugins

Use a clean Linux build checkout with git, make, gcc, curl, Python 3.11+,
Zig at the version in `toolchain.env`, and the .NET 10 SDK:

```sh
tools/build-release.sh
python3 -m unittest discover -s tests -p 'test_release.py' -v
tests/run.sh
```

`build-release.sh` bootstraps the actual Nelua interpreter (the executable
launcher alone is not sufficient), builds without the optional Umbra widget,
and invokes DalamudPackager 15.0.0 through the managed project. The script
requires the pinned Zig version; it does not accept the native/dependency
skip flags intended for local iteration.

Outputs:

- `build/release/GhosttyDalamud.zip`: candidate for manual installation/testing.
- `build/release/GhosttyDalamud.json`: actual built manifest.
- `build/release/package-report.json`: payload SHA-256 hashes and manifest.

Extract the ZIP into a new development-plugin directory, then add the full
path to `GhosttyDalamud.dll` under `/xlsettings` > Experimental > Dev Plugin
Locations. Enable it in `/xlplugins` > Dev Tools. Do not overwrite a working
installation before keeping a backup of its configuration. A GitHub Actions
artifact ZIP is an outer download container: extract that first to get the
plugin ZIP. Never point an installer feed at an Actions artifact URL.

Linux/Wine still needs the separately started `ghostty-agent`, a configured
token, and an agent profile. Keep its plaintext transport on loopback and
use an SSH tunnel for remote connections. Native Windows needs a ConPTY
profile; `cmd.exe` is built in, but `pwsh.exe` requires PowerShell 7 to be
installed. The shipped default remains the agent profile; this PR does not
claim automatic Windows setup. macOS agent compilation remains unverified.

Shell commands and user Lua configuration execute with the user's privileges;
this is not a sandbox. Neither the agent nor the optional Umbra widget is
part of the main plugin ZIP. Do not silently start a shell server or copy a
personal token into a distributable build.

## Production versus development native loading

The release allowlist deliberately omits `ghostty_loader.dll`. The existing
`Native.Load` fallback then loads `ghostty_core.dll` directly. This avoids the
development loader's need to create hot-load copies beside the installed DLL.
It also means native changes require unloading/reloading the plugin, not
`/term reload-core`. Test unload/reload and a read-only install directory in
game; package structure alone does not prove runtime safety.

The original `tools/build.sh` development directory still contains the loader
and remains available for development hot reload. Do not install a candidate
ZIP over that directory and leave a stale loader behind: use a fresh directory.

The official packager uses an explicit payload list. `tools/release.py check`
additionally checks the exact layout, source/built version and API agreement,
x64 PE DLL headers, size limits, duplicate/traversal paths and symlinks. It
rejects host assemblies, debug PDBs, extra Lua modules, the development loader,
agent binaries, and configuration files outside the shipped `lua/` tree.
It is a packaging check, **not** a credential scan, native dependency audit,
proof of successful compilation, gameplay-policy review, or in-game test.

## Add it to a custom plugin repository / mods download page

Only after privacy, licensing and installation checks, host the ZIP at an
unauthenticated HTTPS URL tied to an immutable version. For example, after
actually publishing a reviewed release tagged `v0.2.0.0`:

```sh
python3 tools/release.py repo \
  --package build/release/GhosttyDalamud.zip \
  --download-url 'https://github.com/Spaceghost/ghostty-dalamud/releases/download/v0.2.0.0/GhosttyDalamud.zip' \
  --timestamp "$(git show -s --format=%ct HEAD)" \
  --output build/release/repo.json
```

That URL is an **example, not an existing download**. The command defaults to
a testing-exclusive entry and validates the local ZIP before writing JSON.
`--channel stable` is explicit; do not use it before testing. The generator
checks URL shape but does not verify server availability or uploaded bytes.
Check an unauthenticated GET of both files, and compare the downloaded ZIP's
SHA-256 with `package-report.json` before announcing it.

Publish `repo.json` on your mods site's HTTPS hosting or a separate public
repository only after publication is approved. Dalamud's custom repository
loader does not support authenticated/private URLs. Add the public JSON URL
under `/xlsettings` > Experimental > Custom Plugin Repositories. Testing-only
entries require enabling testing plugins in Dalamud. Your mods page can link
to that repository URL and the same versioned download; no website repository
or existing mods catalogue has been changed by this preparation.

CI only retains artifacts for this repository. It does not create a GitHub
Release, deploy a website, expose a token, change visibility, or contact the
upstream approval team.

## Official-list submission: remaining gates

New plugins go to `goatcorp/DalamudPluginsD17/testing/live`, **not stable**.
D17 is the repository/workflow name, not a request to change the plugin API
number to 17. The official SamplePlugin and SDK currently target API 15.
Re-check the supported API and the built manifest immediately before submitting.

1. **Public source and licensing.** Complete the current-tree and reachable
   history privacy audit, including public-facing credits and compiled metadata.
   Choose a license deliberately: the existing README says none has been chosen.
   Include required notices/licenses for shipped Ghostty, Lua and other linked
   components. This change does not select or grant a license for the maintainer.
   The exact submitted source commit and required forks must be publicly
   cloneable without authentication.
2. **Reproducible upstream native build.** A normal `dotnet build` does not
   magically compile the Nelua/Zig core. This project fails clearly when the
   native DLL has not been built. Agree a supported source-build path with the
   maintainers/Plogon, prove it from a clean checkout, and do not disguise
   downloaded binaries as source builds. Replace the development-only mutable
   `latest.zip` Dalamud reference download with the build service's supplied
   references or a recorded/checksummed input. The GitHub candidate workflow
   is not proof of Plogon compatibility. Restore/build the managed project and
   commit its **generated** `packages.lock.json`; do not fabricate lock hashes.
3. **Runtime, portability and technical review.** Personally test the exact ZIP
   and source commit on Windows and Linux/Wine: clean install; correct transport;
   missing/invalid token; no agent; shell input/output; settings; unload/reload;
   relaunch; migration; optional Umbra absent/present; and read-only install
   directory. Capture build results, API/game versions, errors, and performance.
   Resolve the macOS agent header/build issue before advertising support.
   Ordinary settings/utility windows currently drawn through native ImGui need
   assessment against Dalamud's Windowing API requirement.
4. **Gameplay/security review and assets.** Have the approval team assess the
   camera/showcase controls, character animation/speed/rotation hooks, world
   panels, experimental shadow objects and input hooks. An off-by-default flag
   alone is not evidence of compliance. Review code-loaded Lua and user-supplied
   shell access honestly; do not describe it as a passive overlay. Supply a
   hand-made square PNG icon, 64–512 pixels on each side, and real screenshots
   without private terminal contents. No generated placeholder icon is shipped.
5. **Human ownership and AI disclosure.** Read the current AI policy, personally
   review and test the code, and state the actual development history. This
   preparation was implemented by an AI agent under a high-level request and
   was not personally game-tested by the agent. Do not claim human validation
   has occurred until it has. Entirely AI-generated plugins without meaningful
   human involvement are not accepted; do not submit automatically or relabel
   the involvement to evade review. Use `submission/PR_BODY.md` as a draft only.

## Generate the D17 manifest after choosing the tested commit

```sh
python3 tools/release.py submission \
  --commit FULL_40_CHARACTER_TESTED_COMMIT_SHA \
  --output build/submission/testing/live/GhosttyDalamud/manifest.toml
```

The command requires a real full commit SHA available in the local checkout;
it intentionally does not substitute a branch name or current HEAD. It writes
only a **draft** manifest and does not certify the gates above. Copy your icon
into `build/submission/testing/live/GhosttyDalamud/images/icon.png`, then make a
new branch in your D17 fork and open a PR with only that plugin directory.
Upstream decides acceptance and promotion to stable. Do not submit this
preparation branch while the outstanding gates remain.

## Primary references (checked 2026-09-17)

- https://dalamud.dev/plugin-publishing/submission/
- https://github.com/goatcorp/DalamudPluginsD17/blob/main/README.md
- https://dalamud.dev/plugin-publishing/restrictions/
- https://dalamud.dev/plugin-development/technical-considerations/
- https://dalamud.dev/plugin-publishing/ai-policy/
- https://dalamud.dev/plugin-publishing/custom-repositories/
- https://github.com/goatcorp/SamplePlugin/blob/master/SamplePlugin/SamplePlugin.csproj
