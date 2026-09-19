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
  queue_full = true
  refused({ method = 'window.focus', params = { id = 4 } }, 'too many changes waiting')
  queue_full = false
  print('ipc call side OK')
end

-- lua/ipc.lua, the frame side ----------------------------------------------------------------
do
  local panels, next_id, calls = {}, 10, {}
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
    agent = { connected = true, version = 3, windows_ok = true, agent = '127.0.0.1:7777' } })
  assert(json.decode(ipc.snapshot()).rev == s1.rev, 'nothing changed: the same rev')

  ipc.run(queued[1]) -- window.open run yad, for XivDesktop
  assert(calls[1].run == 'yad --title x' and calls[1].caller == 'XivDesktop')
  local s2 = json.decode(ipc.snapshot())
  assert(s2.rev == s1.rev + 1, 'a new panel moves rev')
  eq(s2.windows[1], { id = 11, sid = 0, title = '', app = 'yad --title x', w = 0, h = 0, state = 'pending', kind = 'pet', focused = false })
  eq(s2.requests[1], { request = json.decode(queued[1]).request, method = 'window.open', ok = true, result = { id = 11 } })

  panels[1].state, panels[1].sid, panels[1].title = 'live', 3, 'Yad'
  local s3 = json.decode(ipc.snapshot())
  assert(s3.rev == s2.rev + 1 and s3.windows[1].state == 'live' and s3.windows[1].title == 'Yad', 'a state change moves rev')
  world.anchors[11] = { kind = 'world' }
  assert(json.decode(ipc.snapshot()).windows[1].kind == 'pin', 'a pinned panel')
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
  print('ipc frame side OK')
end
