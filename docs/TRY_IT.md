# Use a private Ghostty candidate

Official-list approval is not needed for development-plugin testing. This branch
is preparation, not a published or game-verified release. Do not make the source
public while the history-privacy work is incomplete.

## Linux/Wine: one build-and-stage command

From this branch on a Linux build host with git, make, gcc (or `CC`), ar, curl,
Python 3.11+, the exact Zig version in `toolchain.env`, and the .NET 10 SDK:

```sh
tools/play.sh
```

The command checks prerequisites first, runs Python and NativeCache lifecycle
tests, builds the native components and managed shim, runs the existing host and
agent tests, validates the package, and installs it into a **new** user-owned
candidate directory. It does not alter your launcher, existing installs, saved
configuration, or tokens. Build tests may start isolated test processes, but the
installer does not launch your game or start your personal agent. An existing
destination is refused, not overwritten. An explicit new directory can be passed as argument 1.

It prints the actual DLL path and its Wine `Z:` equivalent. Check that your prefix
maps `/` to `Z:` and that your Flatpak/sandbox permits access to that directory.
In game, add that DLL under `/xlsettings` > Experimental > Dev Plugin Locations.
Disable an older Ghostty dev entry, then enable this candidate in `/xlplugins` >
Dev Tools. Keep a backup of your Ghostty configuration before first activation,
because the plugin itself can migrate an older Umbra configuration.

Start the printed `ghostty-agent --listen 127.0.0.1:7777` command in a separate
terminal. It creates its own token. The plugin must read that same token file;
under Wine, verify the effective `HOME`/`USERPROFILE` and Wine path mapping. For a
custom prefix, copy the shipped `lua/init.lua` into the plugin configuration's
`lua/` directory and set `agent.token_file` to the token's accessible Windows path,
for example `Z:/home/USER/.config/ghostty-agent/token`. Replace USER locally; never
commit that override. Prefer a file over an inline token. Use `/term reload` after
configuration changes. A missing agent, unreadable token or wrong token is a setup
failure, not a reason to disable authentication or bind to the public Internet.

The agent protocol is plaintext; keep it on loopback or inside an encrypted tunnel.
The POSIX shell default is `/bin/sh`; tmux remains optional. Shell commands and Lua
configuration run with your privileges. This is not a sandbox.

## Native Windows

Build the candidate on Linux or download the private Actions candidate artifact
once its build job succeeds. Unpack the outer Actions download first. The actual
plugin package is `GhosttyDalamud.zip`, not the outer artifact ZIP.

With Python 3.11+ and this checkout on Windows:

```powershell
python tools/candidate.py install --package build/release/GhosttyDalamud.zip --destination "$env:LOCALAPPDATA\GhosttyDalamud\candidate"
```

The destination must be new. Add the printed DLL path in Dalamud's dev plugin
locations and enable it. Fresh native Windows configurations select `cmd.exe`
through ConPTY, without a POSIX agent. Old user overrides are not replaced and may
still select the agent. ConPTY and in-game behavior need personal verification.

## What is installed

Only the managed DLL/manifest, native core and ten shipped Lua modules. No agent,
Umbra widget, personal configuration, PDBs, host/game assemblies or development
hot-reload loader. Loader-free packages now use direct native loading; native code
updates require unloading/reloading the plugin or restarting the game. Do not
extract a package over a development folder with an old loader still present.

The existing `tools/build.sh` / `tools/install-dev.sh` workflow remains available
for development hot reload and the optional Umbra widget, separate from this ZIP.

## Record actual results

```sh
python3 tools/candidate.py record --package build/release/GhosttyDalamud.zip --output build/release/testing.json
```

The record starts **unverified**, binds the package hash and source commit, and
notes a dirty checkout. It never overwrites previous evidence. Fill in actual
review and game-test results, including game/Dalamud versions. A first build may
generate an untracked NuGet lock file: commit the real lock, rebuild, and test that
new exact commit before using the record for official submission.
