-- Flat windows pulled into the world (docs/ADOPT.md). Not yet observed in game.
--
--   /window adopt NAME     another plugin's ImGui window as a pet (chat2 = ChatTwo)
--   /window adopt chat     the game's own chat log as a pet
--   /window release [NAME] give it back to the flat UI where it came from
--                          (the panel's x and its "back to UI" button do the same)
--   /window adopted        what is pulled (in the log)
--   (/term adopt NAME and /term release [NAME] are the same commands.)
--
-- Or hold the pull modifier (Alt) over a flat window: a glowing "pull into
-- world" grip shows above it; click it.
--
-- An adopted ImGui window keeps being drawn by its own plugin at its own
-- place on the screen; ghostty moves what it drew onto the pet and hides it
-- there, and feeds the pointer back into it while the pet has focus. Keep it
-- fully on the screen where its plugin puts it (ghostty moves it back inside
-- the screen when it is not, and back again on release): ImGui skips drawing
-- whatever lies outside the screen.
--
-- Change the fields rather than replacing the table: the core calls its functions.

local world = require('world')

local M = {}

-- Known windows by the name used in /window adopt. `title` is the ImGui window
-- name; everything after '###' is its id, which stays the same whatever the
-- plugin shows in its title bar. `plugin` is the plugin's InternalName, used
-- to tell "not installed or not loaded" from "window not open". `native`
-- names the game's own chat log instead of an ImGui window.
M.windows = {
  -- ChatTwo 1.40.6.0: the main window is ImGui.Begin("Chat 2###chat2")
  chat2 = { title = '###chat2', plugin = 'ChatTwo', label = 'Chat 2' },
  -- Mappy 3.2.0.0, Windows/MapWindow.cs
  -- crop: the pet shows only what the window draws with its own textures
  -- (the map), so the margins Mappy leaves around a zoomed-out map never show
  mappy = { title = '###MappyMapWindow', plugin = 'Mappy', label = 'Mappy', crop = true },
  -- ghostty's own /ask panel (lua/ask.lua; its Pin button does this)
  ask = { title = '###ghostty_ask', label = 'Ask' },
  -- the game's chat log (the ChatLog addon and its panels)
  chat = { native = true, label = 'Chat' },
}
M.windows.chattwo = M.windows.chat2
M.windows.chatlog = M.windows.chat

-- Adopted automatically whenever their window is open: they simply become
-- world panels (a pet, pinnable like any panel), and go back to the flat UI
-- when their plugin closes the window. Keyed by name (`{ mappy = true }`);
-- a list (`{ 'mappy', 'chat2' }`) works too. Off, the grip and
-- `/window adopt mappy` still pull it by hand. Releasing an automatic one
-- ("back to UI") leaves it flat until its window closes and opens again.
M.auto = { mappy = true }

-- The key held to show the "pull into world" grip over flat windows:
-- 'alt' (the same key as Alt + drag for panels), 'ctrl', 'shift', or 'off'.
M.pull_modifier = 'alt'
-- Panel pixels per window pixel, and the pet's pixels per yalm: 1.5 at 700
-- makes a 600 px wide chat window about 1.3 yalms wide.
M.scale = 1.5
M.pixels_per_yalm = 700
M.opacity = 0.97
-- The window takes the pet's shape: its inner area (inside the title bar and
-- borders) is resized to the pet's content at M.scale, so the plugin lays
-- itself out to fill it, and resizing the pet resizes the window. The pet
-- shows that inner area covering its whole content (no title bar, no empty
-- band). A pet too big for the screen at M.scale gets a smaller window,
-- scaled up. Release gives the window its own size back. false: the pet
-- takes the window's size instead and shows the whole window.
M.fit = true
-- Pulled windows come back after /term reload or a restart (best effort: a
-- window is looked for for 30 seconds after your character loads).
M.restore = true

-- The game's chat on a pet.
M.chat = {
  -- hidden while the chat is pulled, shown again on release
  addons = { 'ChatLog', 'ChatLogPanel_0', 'ChatLogPanel_1', 'ChatLogPanel_2', 'ChatLogPanel_3' },
  -- the pet's size in panel pixels when the flat chat's size is unknown
  width = 1300, height = 760,
  -- channel colours: the game's own log colours (UiConfig) where it has
  -- them, else these (0xRRGGBB). Keys are XivChatType numbers.
  use_game_colours = true,
}

-- XivChatType -> { UiConfig colour option, built-in colour }.
local CH = {
  [10] = { 'ColorSay', 0xf7f7f7 },      [11] = { 'ColorShout', 0xffa666 },
  [12] = { 'ColorTell', 0xffb8de },     [13] = { 'ColorTell', 0xffb8de },
  [14] = { 'ColorParty', 0x66e5ff },    [15] = { 'ColorAlliance', 0xff7f00 },
  [16] = { 'ColorLS1', 0xd4ff7d },      [17] = { 'ColorLS2', 0xd4ff7d },
  [18] = { 'ColorLS3', 0xd4ff7d },      [19] = { 'ColorLS4', 0xd4ff7d },
  [20] = { 'ColorLS5', 0xd4ff7d },      [21] = { 'ColorLS6', 0xd4ff7d },
  [22] = { 'ColorLS7', 0xd4ff7d },      [23] = { 'ColorLS8', 0xd4ff7d },
  [24] = { 'ColorFCompany', 0xabdbe5 }, [27] = { 'ColorBeginner', 0xd4ff7d },
  [28] = { 'ColorEmoteUser', 0xbafff0 }, [29] = { 'ColorEmote', 0xbafff0 },
  [30] = { 'ColorYell', 0xffff00 },     [32] = { 'ColorParty', 0x66e5ff },
  [36] = { 'ColorPvPGroup', 0xabdbe5 }, [37] = { 'ColorCWLS', 0xd4ff7d },
  [56] = { 'ColorEcho', 0xcccccc },     [57] = { 'ColorSysMsg', 0xcccccc },
  [58] = { 'ColorSysErr', 0xff4a4a },   [59] = { 'ColorSysGathering', 0xcccccc },
  [60] = { 'ColorSysErr', 0xff4a4a },   [61] = { 'ColorNpcSay', 0xabd647 },
  [68] = { 'ColorNpcSay', 0xabd647 },   [69] = { 'ColorFCAnnounce', 0xabdbe5 },
  [101] = { 'ColorCWLS2', 0xd4ff7d },   [102] = { 'ColorCWLS3', 0xd4ff7d },
  [103] = { 'ColorCWLS4', 0xd4ff7d },   [104] = { 'ColorCWLS5', 0xd4ff7d },
  [105] = { 'ColorCWLS6', 0xd4ff7d },   [106] = { 'ColorCWLS7', 0xd4ff7d },
  [107] = { 'ColorCWLS8', 0xd4ff7d },
}
M.chat.channels = CH

-- -> UiConfig option name ('' for none) and the built-in 0xRRGGBB colour.
function M.chat_colour(kind)
  local c = M.chat.channels[kind]
  if not c then return '', 0xdddddd end
  return M.chat.use_game_colours and c[1] or '', c[2]
end

-- -> the names adopted automatically, one per line.
function M.auto_names()
  local out, seen = {}, {}
  for k, v in pairs(M.auto or {}) do
    local name = (type(k) == 'number' and type(v) == 'string') and v or (type(k) == 'string' and v == true and k) or nil
    if name and not seen[name] then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return table.concat(out, '\n')
end

-- -> 'imgui', title, plugin, label | 'native', '', '', label | nil, why.
-- A name not listed is taken as a window title as it is (any ImGui window),
-- with no plugin check.
function M.resolve(name)
  if type(name) ~= 'string' or name == '' then return nil, 'usage: /window adopt NAME (chat2, chat, or a window title)' end
  local w = M.windows[name:lower()]
  if w and w.native then return 'native', '', '', w.label or name end
  if w then return 'imgui', w.title, w.plugin or '', w.label or name end
  return 'imgui', name, '', (name:gsub('##.*$', ''))
end

-- -> whether window `name` (as in /window adopt) is cropped to its content.
function M.crops(name)
  local w = type(name) == 'string' and M.windows[name:lower()]
  return w and w.crop == true or false
end

-- The window at w x h went onto pet `id`: the panel is the window at
-- M.scale plus `chrome_w` x `chrome_h` panel pixels of chrome.
function M.size(id, w, h, chrome_w, chrome_h)
  local a = world.anchors[id]
  if not a or w <= 0 or h <= 0 then return end
  a.width = math.max(64, math.min(5200, w * M.scale + chrome_w))
  a.height = math.max(64, math.min(3600, h * M.scale + chrome_h))
  a.pixels_per_yalm = M.pixels_per_yalm
  a.opacity = M.opacity
end

-- Remembering what was pulled -----------------------------------------------------

local function state_path()
  return (GHOSTTY_PLUGIN_DIR or '.') .. '/adopted.lua'
end

-- `names`: the pulled names, one per line.
function M.save(names)
  local out = { 'return {\n' }
  for n in (names or ''):gmatch('[^\n]+') do out[#out + 1] = string.format('  %q,\n', n) end
  out[#out + 1] = '}\n'
  local s = table.concat(out)
  if s == M._last_saved then return end
  local tmp = state_path() .. '.tmp'
  local f = io.open(tmp, 'w')
  if not f then return end
  local wok = f:write(s)
  local cok = f:close()
  if not wok or not cok then os.remove(tmp) return end
  os.remove(state_path()) -- rename does not replace on Windows
  if os.rename(tmp, state_path()) then M._last_saved = s end
end

-- -> the names saved, one per line ('' when none or M.restore is off).
function M.saved()
  if not M.restore then return '' end
  local chunk = loadfile(state_path())
  if not chunk then return '' end
  local ok, t = pcall(chunk)
  if not ok or type(t) ~= 'table' then return '' end
  local names = {}
  for _, n in ipairs(t) do
    if type(n) == 'string' and n ~= '' and not n:find('\n', 1, true) then names[#names + 1] = n end
  end
  return table.concat(names, '\n')
end

return M
