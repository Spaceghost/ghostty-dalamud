# Neovim workspace terminals

The workspace bridge projects existing Neovim panes into independently routed
world terminals. It connects to a running Neovim socket and never starts or owns
the shell jobs. Typing goes directly to that pane's terminal channel, including
when its tab is hidden. Closing a world view detaches it and leaves the job alive.
An editor buffer is shown as a read-only text view and is labelled accordingly.

Each tab forms a colour group. When a pane carries `spaceghost_attach`, supplying
a source with that host name expands its tabs into the parent's group. All
descendants inherit the group's colour and occupy nearby positions. Separate
groups spread around the character. Layout keys use source, tab and buffer IDs,
so renaming a tab does not create a replacement shell. Manual pins and hiding
remain authoritative. Every world panel receives a nameplate; workspace plates
show the source, tab title and nesting depth in their group's colour.

## Setup

Run the exporter on the machine whose Ghostty agent will open the views. Python 3
and an existing local Neovim UNIX socket are required. No third-party Python
packages are used. Forward remote UNIX sockets with your existing SSH setup
before exporting; the bridge does not discover credentials or initiate SSH.

```sh
python3 tools/nvim_workspace.py snapshot \
  --source workstation=/run/user/1000/nvim-spaceghost.sock \
  --source buildbox=/run/user/1000/nvim-attach/buildbox.sock \
  --agent workstation \
  --output /path/to/plugin-config/GhosttyDalamud/nvim-workspace.json
```

The `--agent` value must match a configured Ghostty agent name. All socket paths
and the helper executable must be accessible on that agent's machine. If you
install the helper at a stable location, pass `--viewer /path/to/helper.py`.
Without it, profiles refer to the exporting script's absolute path.

The shipped `lua/init.lua` loads `nvim-workspace.json` from the plugin configuration
directory. A personal `lua/init.lua` override must include the same load before
returning its configuration:

```lua
local ok, err = require('workspace').load(config,
  (GHOSTTY_PLUGIN_DIR or '.') .. '/nvim-workspace.json')
if ok == nil then ghostty.log('workspace: ' .. tostring(err)) end
```

Reload the plugin after exporting to add/remove pane profiles or update titles.
Content and input in an opened view are live. Missing sources are recorded in the
snapshot's `errors`, so one unreachable host does not hide reachable panes.
Views reconnect through Ghostty's ordinary agent sessions. Closing a view is
respected for the rest of that plugin session instead of immediately reopening it.

## Current boundaries and validation

This version mirrors Neovim's rendered buffer text, not the original PTY byte
stream. Original terminal colours, inline graphics and terminal mouse reporting
are not reconstructed. Wide Unicode text is clipped by display columns and
control characters in buffer text cannot inject terminal escape sequences.
Editor views never route typing into the shared Neovim UI. Input into shell views
uses the existing job channel, without changing the selected tab or resizing the
original shell. View resizing clips the mirrored text to the view's dimensions.

Offline tests exercise real Neovim terminals, hidden-tab input, view detachment,
closed buffers, unreachable sources, Unicode and control-sequence handling. Pure
Lua tests exercise nested ancestry, deterministic placement, shared colours,
cycle/duplicate rejection, 256 panes, lifecycle reconciliation and manual pins.
The native core is built for Windows/Wine. World readability, nameplate depth
composition and interaction still require an in-game check before being treated
as visually verified. The game is not started by these tools or tests.
