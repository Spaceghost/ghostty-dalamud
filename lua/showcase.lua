-- /term showcase: demo terminals around your character and a camera that moves
-- through a few shots, for screenshots and showing people the plugin. Your own
-- terminals are hidden (not closed) while it runs, so nothing private is on
-- screen; /term showcase off closes the demo terminals and brings yours back.
--
-- Nothing here needs files on disk. A terminal either runs `send` in a shell
-- from your default profile (with fallbacks, since not every host has the same
-- programs), or shows `show`: text generated below and fed straight into a
-- terminal with no shell or transport behind it.

local M = {}

local ESC = '\27'
local reset = ESC .. '[0m'
local function rgb(r, g, b) return string.format('%s[38;2;%d;%d;%dm', ESC, r, g, b) end
local function bg(r, g, b) return string.format('%s[48;2;%d;%d;%dm', ESC, r, g, b) end

-- A hue wheel sample, t in 0..1.
local function hue(t)
  local r = 0.5 + 0.5 * math.cos(6.2832 * (t + 0.00))
  local g = 0.5 + 0.5 * math.cos(6.2832 * (t + 0.33))
  local b = 0.5 + 0.5 * math.cos(6.2832 * (t + 0.67))
  return math.floor(r * 255), math.floor(g * 255), math.floor(b * 255)
end

-- Text for a terminal with no line discipline: LF becomes CR LF, the screen is
-- cleared first and the cursor hidden.
local function screen(parts)
  return (ESC .. '[2J' .. ESC .. '[H' .. ESC .. '[?25l' .. table.concat(parts)):gsub('\r?\n', '\r\n')
end

local GLYPHS = {
  G = { ' ████ ', '██    ', '██ ███', '██  ██', ' ████ ' },
  H = { '██  ██', '██  ██', '██████', '██  ██', '██  ██' },
  O = { ' ████ ', '██  ██', '██  ██', '██  ██', ' ████ ' },
  S = { ' █████', '██    ', ' ████ ', '    ██', '█████ ' },
  T = { '██████', '  ██  ', '  ██  ', '  ██  ', '  ██  ' },
  Y = { '██  ██', '██  ██', ' ████ ', '  ██  ', '  ██  ' },
}

-- The project name in big rainbow letters, a few feature lines and a box.
function M.banner()
  local out = { '\n' }
  local function put(...) for _, s in ipairs({ ... }) do out[#out + 1] = s end end
  local word = 'GHOSTTY'
  for row = 1, 5 do
    local line = {}
    for i = 1, #word do line[#line + 1] = GLYPHS[word:sub(i, i)][row] .. ' ' end
    local n = 0
    for _, c in utf8.codes(table.concat(line)) do
      n = n + 1
      put(rgb(hue(n / 60 + row * 0.02)), utf8.char(c))
    end
    put(reset, '\n')
  end
  put('\n  ', rgb(230, 222, 200), 'a real terminal emulator, living in Eorzea', reset, '\n\n')
  local lines = {
    { 'libghostty-vt', 'terminal state, kitty keyboard, truecolor' },
    { 'nelua core', 'drawn straight into the game world' },
    { 'lua policy', 'every decision is yours to change' },
    { 'agent', 'shells survive game restarts' },
  }
  for _, l in ipairs(lines) do
    put('  ', rgb(110, 205, 160), '✓', '  ', rgb(140, 180, 250), string.format('%-14s', l[1]), rgb(170, 175, 185), l[2], reset, '\n')
  end
  local frame = rgb(120, 125, 135)
  put('\n  ', frame, '╭────────────────────────────────────────────────╮', reset, '\n')
  put('  ', frame, '│', rgb(235, 190, 110), '  /term showcase', rgb(170, 175, 185), '   pets · pins · world screens  ', frame, '│', reset, '\n')
  put('  ', frame, '╰────────────────────────────────────────────────╯', reset, '\n')
  return screen(out)
end

-- Truecolor gradients, the 256-colour cube and grey ramp, and text styles.
function M.palette()
  local out = {}
  local function put(...) for _, s in ipairs({ ... }) do out[#out + 1] = s end end
  put('\n  ', rgb(230, 222, 200), 'truecolor', reset, '\n\n')
  for row = 0, 7 do
    put('  ')
    for col = 0, 63 do
      local r, g, b = hue(col / 64)
      local k = 1 - row / 9
      put(bg(math.floor(r * k), math.floor(g * k), math.floor(b * k)), ' ')
    end
    put(reset, '\n')
  end
  put('\n  ', rgb(230, 222, 200), '256 colours', reset, '\n\n  ')
  for i = 16, 231 do
    put(ESC, '[48;5;', tostring(i), 'm  ')
    if (i - 15) % 36 == 0 then put(reset, '\n  ') end
  end
  put(reset, '\n  ')
  for i = 232, 255 do put(ESC, '[48;5;', tostring(i), 'm  ') end
  local dim = rgb(150, 160, 175)
  put(reset, '\n\n  ', dim, 'bold ', ESC, '[1mbold', reset, dim, '  italic ', ESC, '[3mitalic', reset,
    dim, '  underline ', ESC, '[4:3mcurly', reset, '\n')
  return screen(out)
end

local CODE = [[
-- every decision is plain Lua (lua/init.lua)
profiles = {
  { name = 'shell', command = { '/bin/bash', '-l' } },
  { name = 'tmux', command = { 'tmux', 'new', '-A' } },
  { name = 'ssh', command = { 'ssh', '-t', 'host' } },
},
dropdown = { height = 0.45, glass = true, glow = 0.6 },
on_click = function(button, mods)
  if button == 'right' then return 'popup' end
  if mods.shift then return 'window' end
  return 'toggle'
end,
]]

local KEYWORDS = {}
for w in ('and break do else elseif end false for function if in local nil not or repeat return then true until while'):gmatch('%a+') do
  KEYWORDS[w] = true
end

-- One line of Lua with editor-style colours: comments, strings, keywords, numbers.
local function highlight(line)
  local out, i = {}, 1
  local plain, comment, str, kw, num, punct =
    rgb(205, 210, 220), rgb(110, 118, 130), rgb(150, 205, 130), rgb(200, 150, 235), rgb(235, 170, 110), rgb(140, 150, 165)
  while i <= #line do
    local c = line:sub(i, i)
    if line:sub(i, i + 1) == '--' then
      out[#out + 1] = comment .. line:sub(i)
      break
    elseif c == "'" then
      local j = line:find("'", i + 1, true) or #line
      out[#out + 1] = str .. line:sub(i, j)
      i = j + 1
    elseif c:match('[%a_]') then
      local w = line:match('^[%w_]+', i)
      out[#out + 1] = (KEYWORDS[w] and kw or plain) .. w
      i = i + #w
    elseif c:match('%d') then
      local n = line:match('^[%d%.]+', i)
      out[#out + 1] = num .. n
      i = i + #n
    else
      out[#out + 1] = (c:match('[{}()=,.]') and punct or plain) .. c
      i = i + 1
    end
  end
  return table.concat(out) .. reset
end

-- A read-only editor view of a configuration snippet, with a status line.
function M.code()
  local out = { '\n' }
  local n = 0
  for line in CODE:gmatch('([^\n]*)\n') do
    n = n + 1
    out[#out + 1] = string.format('%s%3d  %s\n', rgb(90, 96, 108), n, highlight(line))
  end
  out[#out + 1] = string.format('\n %s%s NORMAL %s%s  init.lua  %s  lua  %d:1 %s\n',
    bg(110, 205, 160), rgb(20, 24, 30), reset, bg(45, 50, 60) .. rgb(205, 210, 220), rgb(140, 150, 165), n, reset)
  return screen(out)
end

-- Each demo terminal: where it goes (the words of /term pin, plus
-- `at ANGLE DISTANCE HEIGHT` = radians from where your character faces, yalms),
-- and either `send` (typed into a shell of your default profile) or `show`
-- (text, or a function returning it, shown without a shell). Keep the output
-- free of anything private.
M.terminals = {
  { view = 'pet', send = 'clear; fastfetch -s OS:Kernel:Shell:Terminal:CPU:Memory 2>/dev/null || uname -sr' },
  { view = 'pet', send = 'btop -p 2 2>/dev/null || htop 2>/dev/null || top' },
  { view = 'at -0.8 4.6 2.1', show = M.code },
  { view = 'at 0.8 4.6 2.1', show = M.banner },
  { view = 'at 0 6.5 3.0', show = M.palette },
}

-- Camera shots, in order. yaw: radians around your character from the
-- direction it faces (0 = in front, looking at its face; pi = behind it).
-- pitch: the game's vertical camera angle. distance: yalms. hold: seconds.
M.shots = {
  { yaw = 2.7,  pitch = -0.25, distance = 9,  hold = 5 },
  { yaw = 0.45, pitch = -0.10, distance = 7,  hold = 5 },
  { yaw = -1.7, pitch = -0.40, distance = 12, hold = 5 },
  { yaw = 3.14, pitch = 0.05,  distance = 5,  hold = 5 },
  { yaw = 1.2,  pitch = -0.65, distance = 18, hold = 5 },
}
M.start_delay = 4 -- seconds for the shells and programs to draw before the first shot

-- The core reads entries through these; a `show` function is called here.
function M.terminal(i)
  local t = M.terminals[i]
  if t and type(t.show) == 'function' then
    return { view = t.view, send = t.send, show = t.show() }
  end
  return t
end
function M.shot(i) return M.shots[i] end

return M
