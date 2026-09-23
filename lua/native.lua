-- Terminals in game windows (docs/NATIVE_UI.md). Not yet observed in game.
--
--   /term native            the active terminal (or a new one) as a game window
--   /term native new [N]    a new terminal from profile N as a game window
--   /term native off        the focused game window back to an ImGui window
--   /term native status     whether game windows are available, and why not
--
-- The tab bar and the window header have a "Show as a game window" button.
-- A game window is a real addon of the game's UI (KamiToolKit): it moves by
-- its title bar, scales with the UI and its title bar menu, hides with the
-- UI, and closes with its x or Esc (the terminal is then minimized, its shell
-- still running). Where the game window cannot be made, an ImGui window opens
-- instead and the reason is said in chat.
--
-- Change the fields rather than replacing the table: the core calls its functions.

local M = {}

-- false: /term native and the button open ImGui windows instead
M.enabled = true
-- A new window's size in UI units (the game scales it), before any was resized.
M.width = 720
M.height = 420
-- The terminal's font size at UI scale 1, in pixels; 0 = the dropdown's.
M.font_size = 0
-- The glass behind the terminal: nil = the dropdown's opacity and glass, the
-- same translucent background the ImGui windows have; a number from 0 to 1
-- sets its opacity for game windows only.
M.opacity = nil
-- The display's transfer for game windows: 1 draws colours as they are (what
-- the ImGui windows do); 2.2 encodes them first, for a game UI that decodes
-- sRGB. /term selftest native measures it and says which one matches.
M.gamma = 1

-- Persistence ---------------------------------------------------------------------
-- native-state.lua in the config directory: the last size used, and each
-- window's size and position by the agent's session id, so a terminal that
-- comes back after a restart comes back where it was.

local function state_path()
  return (GHOSTTY_PLUGIN_DIR or '.') .. '/native-state.lua'
end

local function finite(v)
  return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

local function load_state()
  if M._state then return M._state end
  local st = { windows = {} }
  local chunk = loadfile(state_path(), 't', {}) or loadfile(state_path() .. '.tmp', 't', {})
  local ok, tbl = false, nil
  if chunk then ok, tbl = pcall(chunk) end
  if ok and type(tbl) == 'table' then
    if type(tbl.last) == 'table' and finite(tbl.last.w) and finite(tbl.last.h) then
      st.last = { w = tbl.last.w, h = tbl.last.h }
    end
    if type(tbl.windows) == 'table' then
      for k, e in pairs(tbl.windows) do
        if math.type(k) == 'integer' and type(e) == 'table' and finite(e.w) and finite(e.h) then
          st.windows[k] = { w = e.w, h = e.h, x = finite(e.x) and e.x or -1, y = finite(e.y) and e.y or -1 }
        end
      end
    end
  end
  M._state = st
  return st
end

local function clamp_size(w, h)
  w = finite(w) and w or M.width
  h = finite(h) and h or M.height
  return math.max(240, math.min(w, 8192)), math.max(140, math.min(h, 8192))
end

-- The size (UI units) and position (screen pixels, -1 = let the game place it)
-- for the window of agent session `agent_id` (0 = a terminal with no agent
-- session): what it had, else the last size used, else M.width x M.height.
function M.geometry(agent_id)
  local st = load_state()
  local e = agent_id and agent_id ~= 0 and st.windows[agent_id] or nil
  if e then
    local w, h = clamp_size(e.w, e.h)
    return w, h, e.x, e.y
  end
  local last = st.last or {}
  local w, h = clamp_size(last.w, last.h)
  return w, h, -1, -1
end

-- The window of `agent_id` is now w x h at (x, y); becomes the last size used.
function M.remember(agent_id, w, h, x, y)
  if not (finite(w) and finite(h)) then return end
  local st = load_state()
  st.last = { w = w, h = h }
  if agent_id and agent_id ~= 0 then
    st.windows[agent_id] = { w = w, h = h, x = finite(x) and x or -1, y = finite(y) and y or -1 }
  end
  M._dirty = true
end

-- The terminal of `agent_id` is gone for good.
function M.forget(agent_id)
  local st = load_state()
  if agent_id and st.windows[agent_id] then
    st.windows[agent_id] = nil
    M._dirty = true
  end
end

-- Write native-state.lua when something changed; true when it was written.
function M.save()
  if not M._dirty then return false end
  local st = load_state()
  local ids = {}
  for k in pairs(st.windows) do ids[#ids + 1] = k end
  table.sort(ids)
  local out = { '-- written by ghostty (lua/native.lua): game window sizes and places\nreturn {\n' }
  if st.last then out[#out + 1] = string.format('  last = { w = %d, h = %d },\n', math.floor(st.last.w + 0.5), math.floor(st.last.h + 0.5)) end
  out[#out + 1] = '  windows = {\n'
  for _, k in ipairs(ids) do
    local e = st.windows[k]
    out[#out + 1] = string.format('    [%d] = { w = %d, h = %d, x = %d, y = %d },\n', k,
      math.floor(e.w + 0.5), math.floor(e.h + 0.5), math.floor(e.x + 0.5), math.floor(e.y + 0.5))
  end
  out[#out + 1] = '  },\n}\n'
  local tmp = state_path() .. '.tmp'
  local f = io.open(tmp, 'w')
  if not f then return false end
  local wok = f:write(table.concat(out))
  local cok = f:close()
  if not wok or not cok then os.remove(tmp) return false end
  os.remove(state_path()) -- rename does not replace on Windows
  if not os.rename(tmp, state_path()) then return false end
  M._dirty = false
  return true
end

-- Forget what was read (tests; a reload makes a new Lua state anyway).
function M._reset()
  M._state = nil
  M._dirty = false
end

return M
