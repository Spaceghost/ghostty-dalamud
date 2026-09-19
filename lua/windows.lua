-- Remote windows: desktop windows streamed by ghostty-agent (protocol version
-- 3) and shown as world panels, pets and pins like terminals
-- (docs/REMOTE_WINDOWS.md). The core reads the fields below and calls size()
-- and pin(); pull, run, list and close are `/window ...` commands (also
-- `/term window ...`), and other plugins do the same over IPC (docs/IPC.md).
--
--   /window list             the windows the agent can capture (in the log)
--   /window pull [match]     open one as a pet; no match: the agent's
--                            own choice (a desktop picker where it has one)
--   /window pull #wid        by id from the list
--   /window run CMD...       have the agent start CMD and stream its window
--   /window close            close the focused window panel
--   /term pin ...            moves the focused window panel like a terminal
--
-- Change the fields (e.g. windows.fps = 20) rather than replacing the table:
-- the core calls its functions.

local world = require('world')

local M = {}

-- The agent to ask: nil means the ghostty-agent connection in CONFIG.agent,
-- the only one supported so far.
M.agent = nil
-- Largest frame the agent sends; bigger windows are scaled down there (by
-- whole factors), so this bounds bandwidth and the plugin's memory per window.
M.max_w, M.max_h = 1920, 1200
-- Frames per second at most; the agent sends nothing while a window is still.
M.fps = 30
-- World size: panel pixels per yalm, and a new window panel's width in panel
-- pixels (its height follows the window's aspect).
M.pixels_per_yalm = 700
M.width = 1600
M.opacity = 0.97
-- Where a new window panel appears, as `/term pin` takes it: 'here' (in front
-- of you, facing you), 'pet' (floats beside you and follows), 'me', ...
M.open_at = 'here'
-- New windows in the agent's own compositor (Linux: a tab torn off into a
-- window, a dialog, an app started from another one) become panels by
-- themselves: 'all', 'related' (only a dialog of a window with a panel, or a
-- window of an app that has one) or 'none' (the Windows picker only). A
-- dialog is pinned beside its window's panel, another window of an app
-- beside that app's newest panel, anything else where open_at says.
M.auto_open = 'all'
-- Windows and apps never shown in game: not opened by themselves, refused by
-- /window pull and IPC window.open, left out of the Windows picker and of
-- agent.apps (XivDesktop's launcher), and a panel whose window comes to match
-- (a title change) is closed. Each entry is an app id ('firefox'), a desktop
-- id ('org.gnome.Nautilus') or a part of a title, case-insensitive; '*'
-- matches anything ('org.gnome.*', '*password*'). Edit it in the settings
-- window too. Empty by default.
M.never = {}
-- Pulled once your character is loaded, each as `/term window pull` arguments,
-- e.g. { 'Firefox', 'run foot' }. One a saved window panel already brings
-- back (the same match text) is skipped.
M.auto = {}
-- Keys that never reach a window panel's window or a focused terminal while
-- they have the keyboard: chords another plugin reads (XivDesktop's sway-style
-- Super+... by default). Modifiers ctrl, shift, alt, super and a key name or
-- '*' (any key), e.g. { 'super+*' }, { 'alt+shift+*' }, { 'ctrl+alt+*' },
-- { 'super+*', 'ctrl+alt+t' }; {} reserves nothing. Plugins add their own at
-- run time over IPC (keys.reserve, docs/IPC.md).
M.reserved_chords = { 'super+*' }

-- Panel size limits in panel pixels (lua/world.lua clamps resizes to the same).
local MIN_W, MAX_W, MIN_H, MAX_H = 600, 5200, 320, 3600

-- The first frame of window panel `id` arrived at w x h: give the panel the
-- window's aspect below a title strip of `chrome` pixels.
function M.size(id, w, h, chrome)
  local a = world.anchors[id]
  if not a or w <= 0 or h <= 0 then return end
  local pw = math.max(MIN_W, math.min(MAX_W, M.width))
  local ph = pw * h / w + chrome
  if ph > MAX_H then pw, ph = math.max(MIN_W, (MAX_H - chrome) * w / h), MAX_H end
  a.width, a.height = pw, math.max(MIN_H, ph)
  a.pixels_per_yalm = M.pixels_per_yalm
  a.opacity = M.opacity
end

-- Pin panel `id` beside panel `other` as it is shown: facing the same way,
-- to its right with a small gap, `forward` yalms in front of it (a dialog
-- over its window). Its size stays; nil or why not.
function M.beside(id, other, forward)
  local o = world.anchors[other]
  local p = o and o._out
  if not p then return 'the other panel has not been shown yet' end
  local a = world.anchors[id]
  if not a then return 'not a world panel' end
  local half_o = (p.width or M.width) / (p.pixels_per_yalm or M.pixels_per_yalm) / 2
  local half_n = (a.width or math.max(MIN_W, math.min(MAX_W, M.width))) / (a.pixels_per_yalm or M.pixels_per_yalm) / 2
  local s = half_o + half_n + 0.15
  local f = forward or 0
  local yaw = p.yaw or 0
  -- the viewer's right is (cos yaw, 0, -sin yaw); the front (sin yaw, 0, cos yaw)
  local x = p.x + math.cos(yaw) * s + math.sin(yaw) * f
  local z = p.z - math.sin(yaw) * s + math.cos(yaw) * f
  local err = world.command(id, 'pet') -- toggle pins a pet where it is told
  if err then return err end
  local w, h, ppy, op = a.width, a.height, a.pixels_per_yalm, a.opacity
  err = world.toggle(id, x, p.y, z, yaw, p.pitch or 0)
  local n = world.anchors[id]
  if n then n.width, n.height, n.pixels_per_yalm, n.opacity = w, h, ppy, op end
  return err
end

-- `/term pin ...` on a window panel: a new anchor, the same size.
function M.pin(id, args)
  local old = world.anchors[id]
  local err = world.command(id, args)
  local a = world.anchors[id]
  if not err and old and a and a ~= old then
    a.width, a.height, a.pixels_per_yalm, a.opacity = old.width, old.height, old.pixels_per_yalm, old.opacity
  end
  return err
end

-- Persistence ---------------------------------------------------------------------
-- Window panels are saved with the layout (the core calls save_state beside
-- lua/world.lua's), each with the key that opens its window again, the match
-- text it was first opened with, its title and its world anchor; on start and
-- after /term reload the core asks for each again (saved, restore).

-- Anchor fields that are the panel's state of the moment, not its place.
local TRANSIENT = { t = true, placed_at = true, px = true, pz = true, phase = true, since = true }

local function state_path()
  return (GHOSTTY_PLUGIN_DIR or '.') .. '/window-state.lua'
end

local function anchor_fields(a)
  local fields = {}
  for k, v in pairs(a) do
    local tv = type(v)
    if not TRANSIENT[k] and not k:match('_v$') and (tv == 'number' or tv == 'string' or tv == 'boolean')
       -- a pet's spring state is recomputed around the character
       and not (a.kind == 'pet' and (k == 'x' or k == 'y' or k == 'z' or k == 'faced'))
       and not (tv == 'number' and not (v == v and v ~= math.huge and v ~= -math.huge)) then
      fields[#fields + 1] = string.format('%s = %s', k, tv == 'string' and string.format('%q', v) or tostring(v))
    end
  end
  table.sort(fields)
  return table.concat(fields, ', ')
end

-- list: { {id=, key=, match=, title=}, ... } in panel order.
function M.save_state(list)
  local out = { 'return {\n' }
  for _, e in ipairs(list) do
    local a = world.anchors[e.id]
    out[#out + 1] = string.format('  { key = %q, match = %q, title = %q, anchor = { %s } },\n',
      e.key or '', e.match or '', e.title or '', a and anchor_fields(a) or '')
  end
  out[#out + 1] = '}\n'
  local text = table.concat(out)
  if text == M._last_saved then return end -- unchanged: no write
  -- beside it and swapped, so a crash mid-write never leaves a truncated file
  local tmp = state_path() .. '.tmp'
  local f = io.open(tmp, 'w')
  if not f then return end
  local wok = f:write(text)
  local cok = f:close()
  if not wok or not cok then os.remove(tmp) return end
  os.remove(state_path()) -- rename does not replace on Windows
  if os.rename(tmp, state_path()) then M._last_saved = text end
end

-- The saved entries (read once per Lua state): { {key=, match=, title=, anchor=}, ... }.
function M.saved()
  if M._saved == nil then
    local chunk = loadfile(state_path()) or loadfile(state_path() .. '.tmp') -- a swap cut short
    local ok, tbl = false, nil
    if chunk then ok, tbl = pcall(chunk) end
    M._saved = {}
    if ok and type(tbl) == 'table' then
      for _, e in ipairs(tbl) do
        if type(e) == 'table' and (type(e.key) == 'string' or type(e.match) == 'string') then M._saved[#M._saved + 1] = e end
      end
    end
  end
  return M._saved
end

-- Panel `id` takes saved entry `n`'s anchor; true when it had one.
function M.restore(id, n)
  local e = M.saved()[n]
  if not e or type(e.anchor) ~= 'table' or not e.anchor.kind then return false end
  local a = {}
  for k, v in pairs(e.anchor) do a[k] = v end
  if a.kind == 'pet' then a.phase = math.random() * 2 * math.pi end
  world.anchors[id] = a
  world._pet_ids = nil -- pets may come, go, hide or show
  return true
end

return M
