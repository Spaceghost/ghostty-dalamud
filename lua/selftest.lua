-- The Lua half of `/term selftest` (core/app/selftest.nelua runs the rest):
-- checks of the shipped Lua modules inside the live plugin. None of them
-- moves the character, rings a bell, opens a window or touches the player's
-- files: settings are saved to and read back from a scratch directory, and
-- whatever a check changes is put back before it returns.
--
-- M.run(suite, scratch) returns one line per case, "name\tstatus\tmessage"
-- (status pass, fail or skip); `scratch` is a writable directory the suite
-- may use and leaves empty.

local M = {}

local function clean(s)
  return (tostring(s):gsub('[%c]', ' '))
end

local function copy(t)
  if type(t) ~= 'table' then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = copy(v) end
  return out
end

-- Differences between two plain tables, as a short text (nil when equal).
local function diff(a, b, path)
  path = path or ''
  if type(a) ~= type(b) then return path .. ': ' .. type(a) .. ' vs ' .. type(b) end
  if type(a) ~= 'table' then
    if a ~= b then return path .. ': ' .. tostring(a) .. ' vs ' .. tostring(b) end
    return nil
  end
  local keys = {}
  for k in pairs(a) do keys[k] = true end
  for k in pairs(b) do keys[k] = true end
  local sorted = {}
  for k in pairs(keys) do sorted[#sorted + 1] = k end
  table.sort(sorted, function(x, y) return tostring(x) < tostring(y) end)
  for _, k in ipairs(sorted) do
    local d = diff(a[k], b[k], path .. '.' .. tostring(k))
    if d then return d end
  end
  return nil
end

local function exists(path)
  local f = io.open(path, 'rb')
  if f then f:close() end
  return f ~= nil
end

-- Runs `fn(case)` where case(name, ok, message) records one case; an error
-- inside fn becomes a failed case named after the suite.
local function suite(name, fn)
  local out = {}
  local function case(cname, status, msg)
    if status == true then status = 'pass' elseif status == false then status = 'fail' end
    out[#out + 1] = clean(cname) .. '\t' .. status .. '\t' .. clean(msg or '')
  end
  local ok, err = pcall(fn, case)
  if not ok then case(name, 'fail', 'error: ' .. tostring(err)) end
  return table.concat(out, '\n')
end

-- settings ------------------------------------------------------------------------
-- settings.lua saved and read back, in `scratch` instead of the config home.
function M.settings(scratch)
  return suite('settings', function(case)
    local S = require('settings')
    local saved_values, saved_config, saved_dir = S.values, S.config, GHOSTTY_PLUGIN_DIR
    local file = scratch .. '/settings.lua'
    local ok, err = pcall(function()
      GHOSTTY_PLUGIN_DIR = scratch
      -- the player's values, as they are, round trip (but not the gallery's
      -- link: it belongs in no scratch file and in no report)
      local mine = copy(saved_values)
      mine['gallery.token'] = nil
      S.values = copy(mine)
      S.save()
      S.values = {}
      S.apply({})
      local d = diff(mine, S.values)
      case('current values', d == nil, d or string.format('%d values saved and read back', (function()
        local n = 0 for _ in pairs(mine) do n = n + 1 end return n end)()))
      -- every kind of value, quotes included
      local fixed = {
        ['dropdown.opacity'] = 0.75, ['dropdown.min_width'] = 640, ['dropdown.glass'] = false,
        ['dropdown.align'] = 'center "quoted" \\ back',
      }
      S.values = copy(fixed)
      S.save()
      S.values = {}
      local cfg = {}
      S.apply(cfg)
      d = diff(fixed, S.values)
      local applied = cfg.dropdown and cfg.dropdown.opacity == 0.75 and cfg.dropdown.min_width == 640
        and cfg.dropdown.glass == false and cfg.dropdown.align == fixed['dropdown.align']
      case('typed values', d == nil and applied, d or (applied and 'number, integer, boolean and quoted string' or 'values not applied to the config'))
      -- out-of-range sliders are clamped, NaN dropped
      local f = assert(io.open(file, 'w'))
      f:write('return { ["dropdown.opacity"] = 7, ["dropdown.min_width"] = 12.7, ["dropdown.height"] = 0/0 }\n')
      f:close()
      S.values = {}
      cfg = {}
      S.apply(cfg)
      local clamped = S.values['dropdown.opacity'] == 1.0 and S.values['dropdown.min_width'] == 400
        and S.values['dropdown.height'] == nil
      case('slider clamping', clamped, clamped and 'opacity 7 -> 1, min_width 12.7 -> 400, NaN dropped'
        or string.format('got opacity %s, min_width %s, height %s', tostring(S.values['dropdown.opacity']),
          tostring(S.values['dropdown.min_width']), tostring(S.values['dropdown.height'])))
    end)
    S.values, S.config, GHOSTTY_PLUGIN_DIR = saved_values, saved_config, saved_dir
    os.remove(file)
    if not ok then error(err, 0) end
    case('restored', S.values == saved_values and GHOSTTY_PLUGIN_DIR == saved_dir and not exists(file),
      'values, config and directory put back, scratch file removed')
  end)
end

-- themes --------------------------------------------------------------------------
-- Only with a lua/themes.lua (names, resolve, apply): every theme resolves,
-- and switching away and back gives the same colours. The live config is
-- never changed: apply works on a copy.
function M.themes()
  return suite('themes', function(case)
    local ok, T = pcall(require, 'themes')
    if not ok or type(T) ~= 'table' or type(T.names) ~= 'function' or type(T.resolve) ~= 'function' then
      case('module', 'skip', 'this build has no lua/themes.lua')
      return
    end
    local names = T.names()
    case('names', #names > 0, string.format('%d themes', #names))
    local bad = {}
    for _, n in ipairs(names) do
      local r = T.resolve(n)
      if type(r) ~= 'table' or type(r.terminal) ~= 'table' or type(r.chrome) ~= 'table' then bad[#bad + 1] = n end
    end
    case('resolve', #bad == 0, #bad == 0 and 'every theme has terminal and chrome colours' or ('unusable: ' .. table.concat(bad, ', ')))
    local current = CONFIG and CONFIG.theme
    local before = copy(T.resolve(current))
    local other = names[1] ~= (before and before.name) and names[1] or names[2]
    if other and type(T.apply) == 'function' then
      local cfg = { theme = other, bell = { accent = { r = 0.1, g = 0.2, b = 0.3 } } }
      T.apply(cfg, {})
      cfg.theme = current
      T.apply(cfg, {})
      local after = copy(T.resolve(current))
      local d = diff(before, after)
      case('switch and restore', d == nil, d or ('to ' .. other .. ' and back to ' .. tostring(before and before.name)))
    else
      case('switch and restore', 'skip', 'only one theme')
    end
    case('live config untouched', not CONFIG or CONFIG.theme == current, 'CONFIG.theme is still ' .. tostring(current))
  end)
end

-- bell and showcase ------------------------------------------------------------------
-- /term bell and /term showcase arguments parse; nothing rings or opens.
local SHOWCASE_VIEWS = { pet = true, here = true, me = true, target = true, orbit = true }

function M.bell()
  return suite('bell', function(case)
    local B = require('bell')
    local saved = B.preset
    local ok, err = pcall(function()
      local bad = {}
      for _, p in ipairs(B.presets) do
        if B.command(p.name) ~= nil or B.preset ~= p.name then bad[#bad + 1] = p.name end
      end
      if B.command('custom') ~= nil then bad[#bad + 1] = 'custom' end
      case('bell styles', #bad == 0, #bad == 0 and string.format('%d presets and custom accepted', #B.presets)
        or ('rejected: ' .. table.concat(bad, ', ')))
      local e = B.command('no-such-style')
      case('unknown style', type(e) == 'string' and e:find('ripple', 1, true) ~= nil, tostring(e))
      case('demo arguments', B.command('demo') == nil and B.command('') == nil, '"demo" and "" are no errors')
      local label = B.demo(1)
      case('demo steps', type(label) == 'string' and B.demo(#B.presets + 1) == nil, tostring(label))
    end)
    B.preset = saved
    if not ok then error(err, 0) end
    case('bell restored', B.preset == saved, 'style is ' .. tostring(saved))

    local SC = require('showcase')
    local bad = {}
    local i = 1
    while true do
      local t = SC.terminal(i)
      if not t then break end
      local word = type(t.view) == 'string' and t.view:match('^%s*(%S+)') or nil
      local fine = word ~= nil and (SHOWCASE_VIEWS[word] or word == 'at')
      if word == 'at' then
        local a, d, h = t.view:match('^%s*at%s+(%S+)%s+(%S+)%s+(%S+)%s*$')
        fine = tonumber(a) ~= nil and tonumber(d) ~= nil and tonumber(h) ~= nil
      end
      if fine and t.show ~= nil then fine = type(t.show) == 'string' and not t.show:find('\0', 1, true) end
      if fine and t.send ~= nil then fine = type(t.send) == 'string' and not t.send:find('[\r\n]') end
      if not fine then bad[#bad + 1] = tostring(i) end
      i = i + 1
    end
    case('showcase terminals', i > 1 and #bad == 0,
      #bad == 0 and string.format('%d entries', i - 1) or ('bad entries: ' .. table.concat(bad, ', ')))
    local shots_ok, n = true, 0
    for _, s in ipairs(SC.shots or {}) do
      n = n + 1
      if type(s.yaw) ~= 'number' or type(s.pitch) ~= 'number' or type(s.distance) ~= 'number' or type(s.hold) ~= 'number' then
        shots_ok = false
      end
    end
    case('showcase shots', shots_ok and n > 0, string.format('%d shots', n))
  end)
end

-- world: what the game's collision answers from your chest (the pets look at
-- walls through it; lua/world.lua), and what each pet's last look found.
function M.world()
  return suite('world', function(case)
    local rc = ghostty.raycast
    if type(rc) ~= 'function' then
      case('raycast', 'fail', 'ghostty.raycast is missing: pets cannot see walls')
      return
    end
    local p = ghostty.player and ghostty.player() or nil
    if not p then case('raycast', 'skip', 'no character loaded') return end
    local ox, oy, oz = p.x, p.y + 1.1, p.z
    local down = rc(ox, oy, oz, 0, -1, 0, 5)
    case('raycast down', down ~= nil, down and string.format('the ground %.2f yalms below the chest', down)
      or 'nothing within 5 yalms below the chest: the game collision answered no ray, so pets see no walls')
    local fx, fz = math.sin(p.rotation), math.cos(p.rotation)
    local ahead = rc(ox, oy, oz, fx, 0, fz, 30)
    case('raycast ahead', 'pass', ahead and string.format('%.2f yalms ahead', ahead) or 'nothing within 30 yalms ahead')
    local near, near_dir, hits = nil, 0, 0
    for i = 0, 15 do
      local ang = p.rotation + i * math.pi / 8
      local d = rc(ox, oy, oz, math.sin(ang), 0, math.cos(ang), 30)
      if d then
        hits = hits + 1
        if not near or d < near then near, near_dir = d, i * 22.5 end
      end
    end
    case('nearest wall', 'pass', near and string.format('%.2f yalms, %.1f degrees round from where you face; %d of 16 directions hit within 30 yalms', near, near_dir, hits)
      or 'no wall within 30 yalms in 16 directions')
    -- at knee height, all round, with each filter: a post or a lamp base next to
    -- you shows here, and whether the old filter (bg) would have seen it
    for _, f in ipairs({ 'all', 'layers', 'bg' }) do
      local n, best, dir = 0, nil, 0
      for i = 0, 15 do
        local ang = p.rotation + i * math.pi / 8
        local d, _, _, _, used = rc(p.x, p.y + 0.5, p.z, math.sin(ang), 0, math.cos(ang), 6, f)
        if d then
          n = n + 1
          if not best or d < best then best, dir = d, i * 22.5 end
        end
        if i == 0 and used and used ~= f then f = f .. ' (this shim answers ' .. used .. ')' end
      end
      case('ring at knee height, ' .. f, 'pass', best and string.format('%d of 16 directions hit within 6 yalms, nearest %.2f at %.1f degrees', n, best, dir)
        or 'nothing within 6 yalms all round')
    end
    local W = CONFIG and CONFIG.world
    if W and W.anchors then
      for id, a in pairs(W.anchors) do
        if a.kind == 'pet' and not a.hidden then
          local w = a.m_wall
          case('pet ' .. tostring(id), 'pass', string.format('up %.2f; %s', a.m_dy or 0,
            w and string.format('hung on a wall (its place %.2f clear of it)', w.clear) or 'free'))
        end
      end
    end
  end)
end

-- netlab ------------------------------------------------------------------------
-- The panel's model from a known report, and, while `/term netlab demo` runs,
-- what iroh and moq are doing right now (from the panel's last NLSTAT), so a
-- run in game records it in selftest/latest.json.
function M.netlab()
  return suite('netlab', function(case)
    local N = CONFIG and CONFIG.netlab
    if type(N) ~= 'table' or type(N.model) ~= 'function' then
      case('panel', 'skip', 'lua/netlab.lua is not loaded')
      return
    end
    local m = N.model({ built = true, started = true, relay = 'default',
      nodes = { { role = 'viewer', name = 'viewer 1', h = 3, stats = { id = 'b',
        conns = { { n = 1, dir = 'out', open = true, paths = {
          { kind = 'relay', addr = 'r', selected = false, rtt_us = 30000 },
          { kind = 'direct', addr = 'd', selected = true, rtt_us = 500 } } } },
        events = {}, subs = { { state = 'live', skipped = 2, cut = 1, lat_us = 400 } } } } },
      pubs = {}, subs = { { id = 4, node = 3, viewed = true } }, demo = { fast = 4, slow = 0 } })
    local s = m and m.subs[1]
    case('panel', s ~= nil and s.label == 'fast' and s.conn.kind == 'direct' and s.conn.relay_rtt_ms == 30 and s.skipped == 2,
      'the model of a known report')
    case('drawing calls', type(ghostty) == 'table' and type(ghostty.ui) == 'table' and type(ghostty.ui.canvas) == 'function'
      and type(ghostty.netlab_send) == 'function', 'ghostty.ui.canvas and ghostty.netlab_send')
    local state, version = 'off', 0
    if ghostty and ghostty.netlab_agent then state, version = ghostty.netlab_agent() end
    if state ~= 'ready' then
      case('agent', 'skip', 'no agent connected (' .. tostring(state) .. ')')
      return
    end
    case('agent', version >= 4, 'protocol version ' .. tostring(version))
    local live = N.state and N.state.model
    if not live or not live.started then
      case('live', 'skip', 'run /term netlab demo first, then this suite')
      return
    end
    if not live.built then case('live', false, 'the agent has no netlab') return end
    local parts = {}
    for _, sub in ipairs(live.subs) do
      local c = sub.conn
      parts[#parts + 1] = string.format('%s: %s, %s path rtt %.2f ms, latency %.2f ms, %d objects, %d groups skipped, %d cut',
        sub.label, sub.state, c and c.kind or 'no', c and c.rtt_ms or 0, sub.lat_ms, sub.objects, sub.skipped, sub.cut)
    end
    local any = #live.subs > 0 and live.subs[1].objects > 0
    case('live', any, table.concat(parts, '; '))
  end)
end

function M.run(name, scratch)
  if name == 'settings' then return M.settings(scratch) end
  if name == 'themes' then return M.themes() end
  if name == 'bell' then return M.bell() end
  if name == 'world' then return M.world() end
  if name == 'netlab' then return M.netlab() end
  return 'suite\tfail\tno Lua suite named ' .. clean(name)
end

return M
