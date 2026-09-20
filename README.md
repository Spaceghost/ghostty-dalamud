# Ghostty for Dalamud

A terminal inside Final Fantasy XIV, built with libghostty-vt, a Nelua core,
Lua configuration, and C# adapters for Dalamud and the optional Umbra widget.

**Experimental developer preview.** This is an independent project, not an
official Ghostty project. Acceptance into the official Dalamud plugin list has
not been established. Host-side tests do not establish Windows, Wine, macOS,
controller, or in-game compatibility. See [release readiness](docs/RELEASE_READINESS.md).

[Vote on features](https://spacegho.st/mods/ffxiv/term/vote/). The in-game About
screen links to the same page. Its idea catalogue ships with the plugin; the
plugin does not fetch the catalogue in the background.

## Design

The terminal uses [libghostty-vt](https://github.com/ghostty-org/ghostty) for VT
state and renders into Dalamud's ImGui draw lists. The repository contains a
Quake-style drop-down, floating windows, world panels, selection and keyboard
handling, controller input, and configurable appearance. Some game-facing
features remain experimental and unverified on their target environment.

| Component | Purpose |
| --- | --- |
| `GhosttyDalamud.dll` | Dalamud plugin adapter and game facilities |
| `ghostty_loader.dll` | Native core loading and development hot reload |
| `ghostty_core.dll` | Terminal, rendering, transports and embedded Lua |
| `lua/` | Configuration, settings UI, layout and behavior |
| `Umbra.Ghostty.dll` | Optional toolbar widget using versioned plugin IPC |
| `ghostty-agent` | Separate POSIX process hosting terminal sessions |

See [architecture](docs/ARCHITECTURE.md) for the frame flow, native interface,
world rendering, migration, and host tests. Public interfaces and detailed
configuration defaults are documented alongside their source files.

## Build

The **complete plugin build requires Linux** with Git, Bash, a C compiler,
Make, Python 3.10 or newer, curl, ar, sha256sum, the Zig version in `toolchain.env`,
and the .NET SDK channel specified there. macOS agent support is experimental,
not a supported full-plugin build host. Native Windows builds are not supplied
by the shell scripts; Windows players can use a separately validated build.

```sh
tools/fetch-vendor.sh
tools/build.sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
vendor/nelua-lang/nelua-lua tests/test_defaults.lua
tests/run.sh
```

Dependencies are fetched at the revisions in `toolchain.env`. Nelua's Makefile
is invoked during dependency builds: the checked-in executable launcher alone
is not evidence that its interpreter has been built.

Dalamud reference assemblies are downloaded from an immutable revision of the
official distribution and verified before extraction into `vendor/dalamud`.
Every cached file is checked before reuse. An unverified or modified cache is
rejected; move it aside intentionally before fetching again. These build-time
references do not update the player's installed Dalamud runtime.

| Override | Purpose |
| --- | --- |
| `ZIG`, `DOTNET`, `CC`, `JOBS` | Tool paths and build concurrency |
| `DALAMUD_LIB_PATH` | Explicit local reference-assembly override, outside bundle verification |
| `UMBRA_LIB_PATH` | Umbra reference assemblies; otherwise pinned `vendor/umbra-dist/dist` |
| `SKIP_UMBRA=1` | Build without the optional widget |
| `SKIP_SHIM=1` | Rebuild native/Lua components using existing managed outputs |
| `SKIP_WIN=1` | Build host components without Windows native binaries |
| `SKIP_DEPS=1` | Reuse existing dependency builds; not for a clean checkout |

The loadable plugin is `build/dist/GhosttyDalamud/`. Keep its managed DLL,
manifest, native DLLs and `lua/` directory together. The optional widget and
host agent are separate outputs in `build/dist/`. Game, Dalamud and Umbra
reference assemblies must not be copied into the plugin package.

## Install from the plugin repository

Ghostty is listed in a third-party Dalamud repository, next to the author's other
FFXIV mods. In game: `/xlsettings` → **Experimental** → **Custom Plugin
Repositories** → paste `https://spacegho.st/mods/ffxiv/plugins.json` → **+** →
**Save and Close**; then `/xlplugins` → **All Plugins** → **Ghostty** → **Install**.

While Ghostty only has test builds it is shown only to players who asked for them:
`/xlsettings` → **Experimental** → **Get plugin testing builds**. Dalamud will say
nobody but the author reviewed a third-party repository, which is true. Releases are
built on GitHub Actions from a tag (`.github/workflows/release.yml`): `v0.2.0` is a
stable release, `v0.2.0-test.1` moves the floating `testing` release, and
`tools/package.sh` writes the `latest.zip` and `pluginmaster.json` either one carries.

Building it yourself, below, needs none of this and stays the supported path for
anyone who wants to read the code first.

## Install for development

For Wine/XIVLauncher.Core, start the agent on the same POSIX host:

```sh
build/dist/ghostty-agent --listen 127.0.0.1:7777
tools/install-dev.sh
```

The agent creates its token file on first start. Add the DLL location printed
by the installer in `/xlsettings` under Experimental, Dev Plugin Locations;
then enable it under `/xlplugins`, Dev Tools. The installer prints a **Wine
`Z:` path**. It is not a general Windows installer.

On native Windows, copy the complete plugin folder into a suitable location
and add its `GhosttyDalamud.dll` path through the same developer settings.
Native Windows should use the local ConPTY transport. Wine should use the
separately running agent. Neither path is certified by Linux host tests.

For the optional Umbra widget, stage it with `tools/install-dev.sh --widget`,
add `Umbra.Ghostty.dll` in Umbra's plugin settings, and add its toolbar widget.
The standalone plugin is designed not to require Umbra.

## Configuration and transports

User overrides belong in `<Dalamud config>/pluginConfigs/GhosttyDalamud/`,
not in the source checkout. Typical roots are `%APPDATA%\XIVLauncher` on
Windows and `~/.xlcore` under XIVLauncher.Core. The plugin receives actual
installation and configuration directories from Dalamud.

Use `/term config` for settings saved to `settings.lua`. Copy `lua/init.lua`
or `lua/keymap.lua` into the configuration directory's `lua/` for more extensive
overrides. User modules take precedence over shipped modules. `/term reload`
reloads configuration. Existing overrides are preserved, so an older override
can retain an older default profile.

The shipped profiles include a POSIX shell through the agent, optional tmux,
Windows PowerShell, and cmd. Do not assume optional executables are installed.
Agent profiles require a running agent and matching token. A Windows-only
installation does not need an agent for a local ConPTY terminal.

- **Agent:** TCP connection to the configured IPv4 address and port. `localhost`
  maps to loopback; arbitrary DNS names and IPv6 are not currently implemented.
  Sessions can outlive client disconnects while the agent remains running.
- **ConPTY:** Local Windows pseudo-console. Availability depends on the runtime.
  Large-input, process-failure and shutdown behavior still need target tests.
- **SSH:** An executable launched inside a terminal, not a separate transport.
  For a remote agent, use a protected tunnel such as `ssh -L`.

The Superlogical transport entry is a placeholder, not a working integration.

A local-agent configuration uses an empty inline token and a per-user token
file; it does not contain the developer's credentials. Set a remote address
and token file explicitly when the agent runs elsewhere.

## Commands and input

`/term` also has the aliases `/tomestone` and `/tome`.

| Command | Purpose |
| --- | --- |
| `/term`, `/term toggle` | Show or hide the drop-down |
| `/term new [n]`, `/term window [n]` | New tab or floating window using profile n |
| `/term pin [here\|me\|target\|orbit]`, `/term unpin` | Place or remove a world panel |
| `/term pet` | Create a following world panel |
| `/term occluded on\|off` | Control whether a hidden world terminal keeps running |
| `/term min [id]`, `/term restore [id]`, `/term focus id` | Manage terminal visibility |
| `/term send [#id] text`, `/term type [#id] text` | Send terminal input with or without Enter |
| `/term bell [style]` | Preview a visual bell |
| `/term showcase`, `/term showcase off` | Start or stop screenshot demonstrations |
| `/term config`, `/term reload` | Edit or reload configuration |
| `/term reload-core` | Request a native core reload through the loader |

Default keys: Ctrl+backquote toggles the drop-down; Ctrl+Shift+backquote toggles
world panels. Ctrl+Shift+C/V copies and pastes, Ctrl+Shift+T/W opens and closes
tabs, Ctrl+Tab changes tabs, and Ctrl+=/-/0 changes zoom. Mouse selection may
copy automatically according to `copy_on_select`. See `lua/keymap.lua`.

The info-bar entry opens the drop-down on click, the popup on right-click,
a window on Shift+click, and world screens on Ctrl+click. The optional widget
uses the same plugin services rather than another terminal core.

Controller gestures default to the game's `select` button: tap to toggle,
hold to advance, double-tap to go back. On a DualSense, this is the touchpad
click, not Create. The optional `create` setting uses Windows HID reports;
its Wine/controller behavior remains unverified. The normal default does not
open a HID device. Disable controller handling with an empty setting.

## Experimental rendering

World placement, animation, lighting and occlusion are implemented but still
require validation in game. Shadow boards are **off by default** and use a
game function resolved by signature. A game patch may invalidate that function;
do not treat the feature as safe merely because host tests pass. Keep it off
until its specific game/Dalamud combination has been tested.

Screenshot demonstrations are not proof of runtime compatibility. No screenshots
or in-game test results are supplied as part of this maintenance pass.

## Privacy and security

The agent stream is **not encrypted**. A token is authentication, not encryption.
Keep the listener on loopback or use a protected tunnel. Do not expose it to the
public internet or reuse a test token. Terminal sessions can execute commands
with the agent or game process's privileges. Lua overrides are trusted code,
not a sandbox for strangers' scripts.

Terminal output, clipboard content, logs, settings and migration copies can
contain private data. Review them before sharing diagnostics or screenshots.
Do not commit runtime configuration or tokens. Check release binaries and PDBs
for build paths and metadata before publishing them.

Migration from the previous Umbra-hosted layout is implemented in `lua/migrate.lua`.
Back up the old configuration before testing migration. It moves user state and
changed overrides into the plugin's own configuration directory; inspect the
migration status before deleting a backup.

## Contributing and attribution

Maintained by [Spaceghost](https://github.com/Spaceghost). Maintainer-only local
identity setup is available as `tools/configure-identity.sh`; contributors should
retain their own chosen attribution. Editing current files does not erase their
old versions or commit metadata. History cleanup is a separate operation.

Built on Ghostty/libghostty-vt, Nelua, Lua, Dalamud, gc-cimgui, FFXIVClientStructs
and Umbra. Preserve their licenses and contributor attribution when distributing
builds. Do not infer a project license or official approval from dependency
licenses or a successful build.
