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
-- Pulled once your character is loaded, each as `/term window pull` arguments,
-- e.g. { 'Firefox', 'run foot' }.
M.auto = {}

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

return M
