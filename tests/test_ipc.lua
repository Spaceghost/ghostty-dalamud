-- lua/json.lua and lua/ipc.lua on their own (run by tests/test_ipc.nelua in a
-- bare Lua state): the JSON round trip and its refusals, then lua/ipc.lua's
-- call side against a stub snapshot and queue (every method, the checks,
-- the queue filling up), and its frame side against stub ghostty.window_*
-- (running queued changes, their results, `rev`).
local ROOT = ...
package.path = ROOT .. '/lua/?.lua;' .. package.path
local json = require('json')

local function eq(a, b, path)
  path = path or 'value'
  if type(a) ~= type(b) then error(path .. ': ' .. type(a) .. ' vs ' .. type(b), 2) end
  if type(a) ~= 'table' then
    if a ~= b or math.type(a) ~= math.type(b) then error(path .. ': ' .. tostring(a) .. ' vs ' .. tostring(b), 2) end
    return
  end
  for k, v in pairs(a) do eq(v, b[k], path .. '.' .. tostring(k)) end
  for k in pairs(b) do if a[k] == nil then error(path .. '.' .. tostring(k) .. ' missing', 2) end end
end

-- JSON ----------------------------------------------------------------------------------
do
  -- values and round trips
  local v = json.decode('{"a": [1, 2.5, -3, 1e2, true, false, null, "x"], "b": {}, "c": [], "d": "\\u00e9\\ud83d\\ude00\\n\\t\\"\\\\\\/"}')
  assert(v.a[1] == 1 and math.type(v.a[1]) == 'integer' and v.a[2] == 2.5 and v.a[3] == -3)
  assert(v.a[4] == 100.0 and math.type(v.a[4]) == 'float', 'an exponent makes a float')
  assert(v.a[5] == true and v.a[6] == false and v.a[7] == json.null and v.a[8] == 'x' and #v.a == 8)
  assert(next(v.b) == nil and getmetatable(v.c) == json.array_mt)
  assert(v.d == '\u{e9}\u{1F600}\n\t"\\/', 'escapes and a surrogate pair: ' .. v.d)
  local text = json.encode(v)
  assert(text == '{"a":[1,2.5,-3,100.0,true,false,null,"x"],"b":{},"c":[],"d":"\u{e9}\u{1F600}\\n\\t\\"\\\\/"}', text)
  eq(json.decode(text), v)
  -- integers at the edges; larger ones become floats
  assert(json.decode('9223372036854775807') == math.maxinteger and json.decode('-9223372036854775808') == math.mininteger)
  assert(math.type(json.decode('9223372036854775808')) == 'float')
  assert(json.decode(' \t\r\n"x" \n') == 'x', 'whitespace around')
  assert(json.decode('-0') == 0 and json.decode('0.5e-1') == 0.05)
  -- encoding
  assert(json.encode({}) == '{}' and json.encode(json.array()) == '[]' and json.encode({ 1, 2 }) == '[1,2]')
  assert(json.encode({ b = 1, a = 2 }) == '{"a":2,"b":1}', 'keys sorted')
  assert(json.encode('\1\127') == '"\\u0001\\u007f"', 'control characters escaped')
  assert(json.encode('a\255b') == '"a\u{FFFD}b"', 'invalid UTF-8 replaced')
  assert(json.encode(0.1) == '0.10000000000000001' and json.encode(3.0) == '3.0' and json.encode(3) == '3' and json.encode(nil) == 'null')
  eq(json.decode(json.encode(0.1)), 0.1)
  local deep = '1'
  for _ = 1, json.max_depth do deep = '[' .. deep .. ']' end
  assert(json.decode(deep), 'max_depth levels are fine')
  -- refusals
  local bad = {
    '', ' ', '{', '[', '[1,]', '{"a":1,}', '{"a" 1}', '{a:1}', "'a'", '01', '-01', '1.', '.5', '-', '1e', '1e+',
    '+1', '0x10', 'nul', 'tru', 'True', 'NaN', 'Infinity', '[1] x', '1 2', '"abc', '"\1"', '"a\nb"', '"\\x"', '"\\u12"',
    '"\\u12G4"', '"\\ud800"', '"\\udc00"', '"\\ud800\\u0041"', '"\\ud800x"', '"\255"', '"\192\128"', '/* c */ 1',
    '[' .. deep .. ']', '{"a":1}{', '\239\187\191{}',
  }
  for _, s in ipairs(bad) do
    local r, err = json.decode(s)
    assert(r == nil and type(err) == 'string', 'refused: ' .. s)
  end
  assert(select(2, json.decode('[1,]')):find('at byte 4', 1, true), 'the reason says where')
  assert(json.decode(42) == nil, 'not a string')
  for _, v in ipairs({ 0 / 0, math.huge, -math.huge, print, { [1] = 1, x = 2 }, { [true] = 1 }, { [2] = 1 } }) do
    assert(json.encode(v) == nil, 'refused to encode ' .. tostring(v))
  end
  local cyc = {}
  cyc.me = cyc
  assert(json.encode(cyc) == nil, 'a cycle')
  -- the same table twice is no cycle
  local shared = { 1 }
  assert(json.encode({ a = shared, b = shared }) == '{"a":[1],"b":[1]}')
  print('json OK')
end

-- lua/ipc.lua, the call side ---------------------------------------------------------------
local snap, queued, queue_full, last_id = nil, {}, false, 500
ghostty = {
  ipc_request_id = function() last_id = last_id + 1 return last_id end,
  ipc_snapshot = function() return snap end,
  ipc_enqueue = function(s)
    if queue_full then return false end
    queued[#queued + 1] = s
    return true
  end,
}
local ipc = require('ipc')
local function call(t)
  local text = type(t) == 'string' and t or assert(json.encode(t))
  local r = json.decode(ipc.call(text))
  assert(r and type(r.ok) == 'boolean', 'a response')
  return r
end
local function refused(t, needle)
  local r = call(t)
  assert(r.ok == false and type(r.error) == 'string', 'refused: ' .. (type(t) == 'string' and t or json.encode(t)))
  if needle then assert(r.error:find(needle, 1, true), r.error .. ' lacks ' .. needle) end
  assert(r.result == nil)
end
do
  refused('{"method": "window.list"', 'malformed JSON')
  refused('[1]', 'must be a JSON object')
  refused('{"params": {}}', 'no method')
  refused({ method = 'window.explode' }, 'unknown method: window.explode')
  refused({ method = 'window.list', params = { 1 } }, 'params must be a JSON object')
  refused({ method = 'window.list', caller = 7 }, 'caller must be a string')
  refused({ method = 'window.list' }, 'starting')
  snap = json.encode({ rev = 3, windows = json.array(), requests = json.array(), agent = { connected = false }, status = 'ghostty 2' })
  eq(call({ method = 'window.list' }), { ok = true, result = { rev = 3, windows = json.array(), requests = json.array() } })
  eq(call({ method = 'agent.status' }).result, { connected = false })
  eq(call('{"method":"status","params":null}').result, 'ghostty 2')
  assert(#queued == 0, 'reads queue nothing')

  -- changes: checked, queued, ids increasing
  local r1 = call({ method = 'window.open', params = { run = 'yad --title x' }, caller = 'XivDesktop' })
  assert(r1.ok and r1.result.queued == true and math.type(r1.result.request) == 'integer', 'queued')
  local q = json.decode(queued[1])
  eq(q, { request = r1.result.request, method = 'window.open', params = { run = 'yad --title x' }, caller = 'XivDesktop' })
  local r2 = call({ method = 'window.close', params = { id = 4, caller = 'Other' } })
  assert(r2.result.request == r1.result.request + 1, 'ids increase')
  assert(json.decode(queued[2]).caller == 'Other', 'caller inside params too')
  call({ method = 'window.focus', params = { id = 4 } })
  call({ method = 'window.place', params = { id = 4, pin = 'here' } })
  call({ method = 'window.open', params = { wid = 7, pin = 'orbit 3' } })
  call({ method = 'window.open', params = { match = '' } })
  call({ method = 'window.open' })
  assert(#queued == 7)
  refused({ method = 'window.open', params = { run = 'a', match = 'b' } }, 'at most one')
  refused({ method = 'window.open', params = { wid = 1, match = 'b' } }, 'at most one')
  refused({ method = 'window.open', params = { wid = 1.5 } }, 'wid')
  refused({ method = 'window.open', params = { wid = 0 } }, 'wid')
  refused({ method = 'window.open', params = { wid = 4294967296 } }, 'wid')
  refused({ method = 'window.open', params = { run = '' } }, 'run must not be empty')
  refused({ method = 'window.open', params = { run = 'a\nb' } }, 'control characters')
  refused({ method = 'window.open', params = { run = 5 } }, 'run must be a string')
  refused({ method = 'window.open', params = { match = string.rep('x', 1025) } }, 'too long')
  refused({ method = 'window.close' }, 'id must be')
  refused({ method = 'window.close', params = { id = '4' } }, 'id must be')
  refused({ method = 'window.focus', params = { id = 0 } }, 'id must be')
  refused({ method = 'window.place', params = { id = 4 } }, 'pin is required')
  refused({ method = 'window.place', params = { id = 4, pin = '' } }, 'pin must not be empty')
  assert(#queued == 7, 'nothing refused was queued')
  -- the panel methods for XivDesktop
  call({ method = 'window.hide', params = { id = 4, hidden = true } })
  eq(json.decode(queued[8]).params, { id = 4, hidden = true })
  call({ method = 'window.toggle_pet', params = { id = 4 } })
  call({ method = 'agent.windows.refresh' })
  call({ method = 'terminal.new' })
  call({ method = 'terminal.new', params = { profile = 2, pin = 'here' } })
  eq(json.decode(queued[12]).params, { profile = 2, pin = 'here' })
  call({ method = 'terminal.new', params = { profile = 'pwsh' } })
  call({ method = 'focus.cycle' })
  eq(json.decode(queued[14]).params, { dir = 'next' })
  call({ method = 'focus.cycle', params = { dir = -1 } })
  eq(json.decode(queued[15]).params, { dir = 'prev' })
  assert(#queued == 15)
  refused({ method = 'window.hide', params = { id = 4 } }, 'hidden must be true or false')
  refused({ method = 'window.hide', params = { id = 4, hidden = 'yes' } }, 'hidden must be true or false')
  refused({ method = 'window.hide', params = { hidden = true } }, 'id must be')
  refused({ method = 'window.toggle_pet', params = { id = -1 } }, 'id must be')
  refused({ method = 'agent.windows.refresh', params = { agent = 'other' } }, 'default')
  refused({ method = 'terminal.new', params = { profile = 0 } }, 'profile must be')
  refused({ method = 'terminal.new', params = { profile = '' } }, 'profile must not be empty')
  refused({ method = 'terminal.new', params = { profile = true } }, 'profile must be a string')
  refused({ method = 'terminal.new', params = { pin = 3 } }, 'pin must be a string')
  refused({ method = 'focus.cycle', params = { dir = 'up' } }, 'dir must be')
  assert(#queued == 15, 'nothing refused was queued')
  -- reads from the snapshot
  snap = json.encode({ rev = 3, windows = json.array(), requests = json.array(), agent = { connected = false }, status = 'ghostty 2',
    agent_windows = { { wid = 7, w = 800, h = 600, app = 'firefox', title = 'Mozilla Firefox', key = 'k7', extra = { 'key:k7' } } },
    agent_apps = { { id = 'foot', name = 'Foot', icon = 'foot', categories = 'System;TerminalEmulator;' } },
    focus = { id = 12, kind = 'window' } })
  eq(call({ method = 'agent.windows' }).result, { { wid = 7, w = 800, h = 600, app = 'firefox', title = 'Mozilla Firefox', key = 'k7', extra = { 'key:k7' } } })
  eq(call({ method = 'agent.apps' }).result[1].id, 'foot')
  eq(call({ method = 'focus.get' }).result, { id = 12, kind = 'window' })
  assert(#queued == 15, 'reads queue nothing')
  -- panel.*: every panel
  snap = json.encode({ rev = 4, panels = { { id = 3, kind = 'terminal', title = 'bash', view = 'tab', focused = false } } })
  eq(call({ method = 'panel.list' }).result, { rev = 4, panels = { { id = 3, kind = 'terminal', title = 'bash', view = 'tab', focused = false } } })
  call({ method = 'panel.focus', params = { id = 3 } })
  eq(json.decode(queued[16]).params, { id = 3, fly = true })
  call({ method = 'panel.focus', params = { id = 3, fly = false } })
  eq(json.decode(queued[17]).params, { id = 3, fly = false })
  call({ method = 'panel.close', params = { id = 3 } })
  call({ method = 'panel.minimize', params = { id = 3 } })
  call({ method = 'panel.toggle_pet', params = { id = 3 } })
  call({ method = 'panel.place', params = { id = 3, pin = 'hud 0.5 0.2' } })
  eq(json.decode(queued[21]).params, { id = 3, pin = 'hud 0.5 0.2' })
  call({ method = 'panel.order', params = { id = 3, to = 'first' } })
  call({ method = 'panel.order', params = { id = 3, to = 2 } })
  eq(json.decode(queued[23]).params, { id = 3, to = '2' })
  assert(#queued == 23)
  refused({ method = 'panel.focus', params = { id = 3, fly = 'no' } }, 'fly must be')
  refused({ method = 'panel.focus' }, 'panel.list')
  refused({ method = 'panel.close', params = { id = 0 } }, 'id must be')
  refused({ method = 'panel.place', params = { id = 3 } }, 'pin is required')
  refused({ method = 'panel.order', params = { id = 3, to = 'up' } }, 'to must be')
  refused({ method = 'panel.order', params = { id = 3, to = 0 } }, 'to must be')
  refused({ method = 'panel.order', params = { id = 3 } }, 'to must be')
  assert(#queued == 23, 'nothing refused was queued')
  queue_full = true
  refused({ method = 'window.focus', params = { id = 4 } }, 'too many changes waiting')
  queue_full = false
  print('ipc call side OK')
end

-- lua/ipc.lua, the frame side ----------------------------------------------------------------
do
  local panels, next_id, calls, focus_calls = {}, 10, {}, {}
  local world_list = {}
  ghostty.world_panels = function() return world_list end
  ghostty.panel_focus = function(id)
    focus_calls[#focus_calls + 1] = id
    for _, p in ipairs(world_list) do p.focused = p.id == id end
    return true
  end
  ghostty.agent_windows = function()
    return { windows = { { wid = 7, w = 800, h = 600, app = 'firefox', title = 'Mozilla Firefox', key = '', extra = {} } },
      apps = {}, answers = 1 }
  end
  package.loaded.world = { anchors = {} }
  local world = package.loaded.world
  ghostty.log = function() end
  ghostty.status = function() return 'ghostty' end
  ghostty.agent_status = function() return { connected = true, version = 3, windows_ok = true, agent = '127.0.0.1:7777' } end
  ghostty.window_list = function()
    local out = {}
    for _, p in ipairs(panels) do out[#out + 1] = p end
    return out
  end
  ghostty.window_open = function(t)
    calls[#calls + 1] = t
    if t.match == 'nothing' then return nil, 'no such window' end
    next_id = next_id + 1
    panels[#panels + 1] = { id = next_id, sid = 0, title = '', app = t.run or t.match or '', w = 0, h = 0, state = 'pending', view = 'world', focused = false }
    world.anchors[next_id] = { kind = 'pet' }
    return next_id
  end
  ghostty.window_close = function(id)
    for i, p in ipairs(panels) do
      if p.id == id then table.remove(panels, i) return true end
    end
    return nil, 'no such window panel'
  end

  local s1 = json.decode(ipc.snapshot())
  eq(s1, { rev = s1.rev, windows = json.array(), requests = json.array(), status = 'ghostty',
    agent = { connected = true, version = 3, windows_ok = true, agent = '127.0.0.1:7777' },
    agent_windows = { { wid = 7, w = 800, h = 600, app = 'firefox', title = 'Mozilla Firefox', key = '', extra = json.array() } },
    agent_apps = json.array(), focus = { id = 0 }, panels = json.array() })
  assert(json.decode(ipc.snapshot()).rev == s1.rev, 'nothing changed: the same rev')

  ipc.run(queued[1]) -- window.open run yad, for XivDesktop
  assert(calls[1].run == 'yad --title x' and calls[1].caller == 'XivDesktop')
  local s2 = json.decode(ipc.snapshot())
  assert(s2.rev == s1.rev + 1, 'a new panel moves rev')
  eq(s2.windows[1], { id = 11, sid = 0, title = '', app = 'yad --title x', w = 0, h = 0, state = 'pending', kind = 'pet', focused = false,
    hidden = false, anchor = 'pet', agent = 'default', key = '' })
  eq(s2.requests[1], { request = json.decode(queued[1]).request, method = 'window.open', ok = true, result = { id = 11 } })

  panels[1].state, panels[1].sid, panels[1].title = 'live', 3, 'Yad'
  local s3 = json.decode(ipc.snapshot())
  assert(s3.rev == s2.rev + 1 and s3.windows[1].state == 'live' and s3.windows[1].title == 'Yad', 'a state change moves rev')
  world.anchors[11] = { kind = 'world' }
  assert(json.decode(ipc.snapshot()).windows[1].kind == 'pin', 'a pinned panel')
  world.anchors[11] = { kind = 'follow', player = true, hidden = true }
  local sh = json.decode(ipc.snapshot())
  assert(sh.windows[1].kind == 'pin' and sh.windows[1].anchor == 'me' and sh.windows[1].hidden == true, 'the anchor as it is, hidden')
  world.anchors[11] = { kind = 'orbit' }
  assert(json.decode(ipc.snapshot()).windows[1].anchor == 'orbit')
  world.anchors[11] = { kind = 'world' }
  panels[1].view = 'full'
  assert(json.decode(ipc.snapshot()).windows[1].kind == 'full')
  panels[1].view = 'world'

  -- a failing change: its error in `requests`
  ipc.run(json.encode({ request = 99, method = 'window.open', params = { match = 'nothing' } }))
  local s4 = json.decode(ipc.snapshot())
  eq(s4.requests[#s4.requests], { request = 99, method = 'window.open', ok = false, error = 'no such window' })
  assert(calls[2].caller == 'IPC', 'no caller given: logged as IPC')
  ipc.run(json.encode({ request = 100, method = 'window.close', params = { id = 11 } }))
  local s5 = json.decode(ipc.snapshot())
  assert(#s5.windows == 0 and s5.requests[#s5.requests].ok == true and s5.rev > s4.rev, 'closed')
  -- the results kept are bounded
  for i = 1, 40 do ipc.run(json.encode({ request = 200 + i, method = 'window.close', params = { id = 1 } })) end
  local s6 = json.decode(ipc.snapshot())
  assert(#s6.requests == ipc.max_results and s6.requests[#s6.requests].request == 240 and s6.requests[1].request == 225)

  -- focus: focus.get from the world panels; focus.cycle skips hidden ones and wraps
  world_list = { { id = 21, window = true, focused = false }, { id = 22, window = false, focused = false }, { id = 23, window = true, focused = false } }
  world.anchors[21], world.anchors[22], world.anchors[23] = { kind = 'pet' }, { kind = 'world', hidden = true }, { kind = 'pet' }
  local function run(method, params, request)
    ipc.run(json.encode({ request = request, method = method, params = params }))
    local r = json.decode(ipc.snapshot())
    return r.requests[#r.requests], r
  end
  local q, r = run('focus.cycle', { dir = 'next' }, 300)
  assert(q.ok and q.result.id == 21 and r.focus.id == 21 and r.focus.kind == 'window', 'nothing focused: next is the first')
  q = run('focus.cycle', { dir = 'next' }, 301)
  assert(q.result.id == 23, 'the hidden terminal is skipped')
  q = run('focus.cycle', { dir = 'next' }, 302)
  assert(q.result.id == 21, 'wraps')
  q = run('focus.cycle', { dir = 'prev' }, 303)
  assert(q.result.id == 23, 'back wraps too')
  q = run('window.focus', { id = 22 }, 304)
  assert(not q.ok and q.error:find('hidden'), 'a hidden panel is not focused')
  assert(#focus_calls == 4)
  world.anchors[21].hidden, world.anchors[23].hidden = true, true
  q = run('focus.cycle', { dir = 'next' }, 305)
  assert(not q.ok and q.error == 'no world panel shown')
  -- the rest reach their ghostty.* function
  local seen = {}
  ghostty.panel_hide = function(id, hidden) seen.hide = { id, hidden } return true end
  ghostty.panel_toggle_pet = function(id) seen.toggle = id return nil, 'not a world terminal' end
  ghostty.agent_windows_refresh = function() seen.refresh = true return true end
  ghostty.terminal_new = function(t) seen.new = t return 31 end
  assert(run('window.hide', { id = 21, hidden = false }, 310).ok and seen.hide[1] == 21 and seen.hide[2] == false)
  q = run('window.toggle_pet', { id = 21 }, 311)
  assert(not q.ok and q.error == 'not a world terminal' and seen.toggle == 21)
  assert(run('agent.windows.refresh', {}, 312).ok and seen.refresh)
  q = run('terminal.new', { profile = 2 }, 313)
  assert(q.ok and q.result.id == 31 and seen.new.profile == '2' and seen.new.pin == nil, 'a numeric profile goes as text')
  -- panel.*: every panel, the view each is in, and the changes reaching ghostty.panel_*
  panels = {}
  world_list = {}
  world.anchors = { [41] = { kind = 'pet' }, [42] = { kind = 'world' }, [43] = { kind = 'hud' }, [44] = { kind = 'pet', hidden = true },
    [45] = { kind = 'pet' }, [47] = { kind = 'follow', player = true } }
  world.pet_rank = function(id) return ({ [41] = 2, [45] = 1 })[id] end
  local plist = {
    { id = 40, kind = 'terminal', title = 'bash', place = 'tab', focused = true, profile = 'bash', running = true },
    { id = 41, kind = 'terminal', title = 'htop', place = 'world', profile = 'bash', running = false },
    { id = 42, kind = 'window', title = 'window', place = 'world' },
    { id = 43, kind = 'adopted', title = 'Mappy', place = 'world', app = 'Mappy' },
    { id = 44, kind = 'chat', title = 'Chat', place = 'world' },
    { id = 45, kind = 'terminal', title = 'pwsh', place = 'world', full = true, profile = 'pwsh', running = true },
    { id = 46, kind = 'terminal', title = 'zsh', place = 'min', profile = 'zsh', running = true },
    { id = 47, kind = 'terminal', title = 'fish', place = 'float', profile = 'fish', running = true },
  }
  ghostty.panels = function() return plist end
  panels[1] = { id = 42, sid = 5, title = 'Yad Window', app = '', w = 640, h = 400, state = 'live', view = 'world', focused = false }
  ghostty.agent_windows = function()
    return { windows = { { wid = 5, w = 640, h = 400, app = 'yad', title = 'Yad Window', key = '', extra = {} } },
      apps = { { id = 'yad', name = 'Yad', icon = '/icons/yad.png', categories = '' } }, answers = 2 }
  end
  local p1 = json.decode(ipc.snapshot())
  eq(p1.panels, {
    { id = 40, kind = 'terminal', title = 'bash', view = 'tab', focused = true, profile = 'bash', running = true },
    { id = 41, kind = 'terminal', title = 'htop', view = 'pet', focused = false, profile = 'bash', running = false, order = 2 },
    { id = 42, kind = 'window', title = 'Yad Window', view = 'pin', focused = false, app = 'yad', icon = '/icons/yad.png' },
    { id = 43, kind = 'adopted', title = 'Mappy', view = 'hud', focused = false, app = 'Mappy' },
    { id = 44, kind = 'chat', title = 'Chat', view = 'hidden', focused = false },
    { id = 45, kind = 'terminal', title = 'pwsh', view = 'full', focused = false, profile = 'pwsh', running = true },
    { id = 46, kind = 'terminal', title = 'zsh', view = 'min', focused = false, profile = 'zsh', running = true },
    { id = 47, kind = 'terminal', title = 'fish', view = 'dropdown', focused = false, profile = 'fish', running = true },
  })
  plist[7].title = 'zsh: vim'
  assert(json.decode(ipc.snapshot()).rev ~= p1.rev, 'a panel change moves rev')
  seen = {}
  ghostty.panel_show = function(id, fly) seen.show = { id, fly } return true end
  ghostty.panel_hide = function(id, hidden) seen.hide = { id, hidden } return true end
  ghostty.panel_close = function(id) seen.close = id return true end
  ghostty.panel_minimize = function(id) seen.min = id return true end
  ghostty.panel_place = function(id, pin) seen.place = { id, pin } return true end
  ghostty.panel_toggle_pet = function(id) seen.toggle = id return true end
  ghostty.world_command = function(id, args) seen.cmd = { id, args } return nil end
  assert(run('panel.focus', { id = 46, fly = true }, 400).ok and seen.show[1] == 46 and seen.show[2] == true and not seen.hide)
  assert(run('panel.focus', { id = 44, fly = false }, 401).ok and seen.hide[1] == 44 and seen.hide[2] == false and seen.show[2] == false,
    'a hidden panel is shown, then focused')
  q = run('panel.focus', { id = 99, fly = true }, 402)
  assert(not q.ok and q.error == 'no such panel')
  assert(run('panel.close', { id = 43 }, 403).ok and seen.close == 43)
  assert(run('panel.minimize', { id = 40 }, 404).ok and seen.min == 40, 'a terminal is minimized')
  seen.hide = nil
  assert(run('panel.minimize', { id = 42 }, 405).ok and seen.hide[1] == 42 and seen.hide[2] == true, 'a window is hidden')
  assert(run('panel.toggle_pet', { id = 41 }, 406).ok and seen.toggle == 41, 'a world panel toggles')
  assert(run('panel.toggle_pet', { id = 46 }, 407).ok and seen.place[1] == 46 and seen.place[2] == 'pet', 'a minimized one becomes a pet')
  assert(run('panel.place', { id = 40, pin = 'here' }, 408).ok and seen.place[1] == 40 and seen.place[2] == 'here')
  assert(run('panel.order', { id = 41, to = 'first' }, 409).ok and seen.cmd[1] == 41 and seen.cmd[2] == 'order first')
  q = run('panel.order', { id = 42, to = 'last' }, 410)
  assert(not q.ok and q.error:find('only pets'), 'a pin has no place in the order')
  print('ipc frame side OK')
end
