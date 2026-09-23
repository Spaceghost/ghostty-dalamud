-- lua/netlab.lua (run by tests/test_netlab_panel.nelua): the commands and the
-- NLCTL lines they send, replies, the model built from NLSTAT (the endpoint,
-- its relay, subscribers with their paths and path events, a peer from
-- elsewhere), what moves between two NLSTATs (objects to fly, groups skipped,
-- the relay-to-direct switch), the viewed subscription's objects, and the
-- panel drawn through a scripted ghostty.ui.
local ROOT = ...
package.path = ROOT .. '/lua/?.lua;' .. package.path
local json = require('json')

local sent, copied, echoed, images, forgotten = {}, {}, {}, {}, {}
local send_error = nil
local next_req = 0
ghostty = {
  netlab_send = function(cmd)
    if send_error then return nil, send_error end
    next_req = next_req + 1
    sent[#sent + 1] = { req = next_req, cmd = cmd }
    return next_req
  end,
  netlab_image = function(sub, x0, y0, x1, y1)
    images[#images + 1] = { sub = sub, x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
    return x0, y0, x1 - x0, y1 - y0
  end,
  netlab_forget = function(sub) forgotten[#forgotten + 1] = sub end,
  ask_echo = function(text) echoed[#echoed + 1] = text return true end,
}

-- a scripted ghostty.ui: `press` names the buttons clicked this frame
local press, drawn = {}, {}
local W = 900
local N = require('netlab')
local function rec(kind, a) drawn[#drawn + 1] = { kind = kind, a = a } end
local cursor_y = 0
ghostty.ui = {
  width = function() return W end,
  canvas = function(id, w, h)
    local y = cursor_y
    cursor_y = cursor_y + h
    rec('canvas', { id = id, w = w, h = h, y = y })
    return 0, y, false, false, 0, 0
  end,
  text = function(t) rec('text', t) end,
  text_at = function(x, y, t, col, scale)
    assert(type(x) == 'number' and type(y) == 'number' and type(t) == 'string' and math.type(col) == 'integer', 'text_at')
    rec('text_at', t)
  end,
  text_size = function(t, scale) return #t * 7 * (scale or 1), 14 * (scale or 1) end,
  line = function(x1, y1, x2, y2, col) assert(x1 == x1 and y2 == y2 and math.type(col) == 'integer') rec('line') end,
  rect = function(x0, y0, x1, y1, col) assert(x0 <= x1 and y0 <= y1 and math.type(col) == 'integer', 'rect corners') rec('rect') end,
  frame = function() rec('frame') end,
  circle = function(x, y, r) assert(x == x and y == y and r > 0) rec('circle') end,
  ring = function(x, y, r) assert(r > 0) rec('ring') end,
  poly = function(pts, col)
    assert(#pts % 2 == 0 and #pts >= 4, 'poly points')
    for _, v in ipairs(pts) do assert(v == v, 'NaN in a polyline') end
    rec('poly', #pts)
  end,
  color = function(name, a)
    assert(type(name) == 'string' and a >= 0 and a <= 255 and math.type(a) == 'integer', 'colour ' .. tostring(name) .. ' ' .. tostring(a))
    return 0xff000000 | #name
  end,
  small_button = function(label) rec('button', label) return press[label] == true end,
  same_line = function() end,
  spacing = function() end,
  copy = function(t) copied[#copied + 1] = t end,
  key_pressed = function() return false end,
  focused = function() return true end,
}

local function draw()
  drawn, cursor_y = {}, 0
  N.draw()
  local texts = {}
  for _, d in ipairs(drawn) do
    if d.kind == 'text_at' or d.kind == 'text' then texts[#texts + 1] = d.a end
  end
  return table.concat(texts, '\n')
end

local function has(text, part) return text:find(part, 1, true) ~= nil end

N.reset()

-- show / hide
assert(N.command('') == true)
assert(N.state.shown and sent[1].cmd == 'watch 100')
local shown, focus = N.tick(1.0)
assert(shown and focus)
shown, focus = N.tick(1.1)
assert(shown and not focus, 'focus once')
N.command('')
assert(not N.state.shown and sent[2].cmd == 'watch 0')

-- nothing reported yet: the panel still draws
N.command('show')
local t = draw()
assert(has(t, 'not started'), t)

-- the demo, and its reply
sent = {}
N.command('demo run:foot --title x')
assert(sent[1].cmd == 'demo relay=default slow=120 age=500 window=run:foot --title x', sent[1].cmd)
N.on_reply(sent[1].req, true, 'running')
assert(N.state.note == 'demo running' and not N.state.note_bad)
N.command('relay http://10.0.0.5:3340')
assert(N.config.relay == 'http://10.0.0.5:3340')
sent = {}
N.command('demo')
assert(sent[1].cmd == 'demo relay=http://10.0.0.5:3340 slow=120 age=500', sent[1].cmd)
N.config.relay = 'default'

-- a refusal, and no answer at all
N.on_reply(sent[1].req, false, 'a demo is running (stop first)')
assert(N.state.note_bad and has(N.state.note, 'a demo is running'))
sent = {}
N.command('ticket')
N.tick(10)
N.tick(16)
assert(N.state.note_bad and has(N.state.note, 'no answer from the agent'), N.state.note)

-- what the agent reports: A publishes, "fast" (viewed) and "slow" subscribe
-- from nodes of their own, and a peer from elsewhere is connected too
local ID_MAIN = string.rep('a', 64)
local ID_FAST = string.rep('b', 64)
local ID_SLOW = string.rep('c', 64)
local ID_PEER = string.rep('d', 64)
local function stats(o)
  local fast_paths = o.fast_direct and {
    { id = 'PathId(0)', kind = 'relay', addr = 'https://relay.example.net./', selected = false, rtt_us = 31000 },
    { id = 'PathId(1)', kind = 'direct', addr = 'ip:192.0.2.4:4433', selected = true, rtt_us = 420 },
  } or {
    { id = 'PathId(0)', kind = 'relay', addr = 'https://relay.example.net./', selected = true, rtt_us = 31000 },
  }
  local fast_events = {
    { t_ms = 10, conn = 1, what = 'opened', kind = 'relay', addr = 'https://relay.example.net./' },
    { t_ms = 11, conn = 1, what = 'selected', kind = 'relay', addr = 'https://relay.example.net./' },
  }
  if o.fast_direct then
    fast_events[#fast_events + 1] = { t_ms = 1210, conn = 1, what = 'opened', kind = 'direct', addr = 'ip:192.0.2.4:4433' }
    fast_events[#fast_events + 1] = { t_ms = 1260, conn = 1, what = 'selected', kind = 'direct', addr = 'ip:192.0.2.4:4433' }
  end
  return json.encode({
    t_ms = o.t, built = true, started = true, backend = 'wayland', relay = 'default',
    nodes = {
      { role = 'main', name = 'main', h = 1, stats = {
        id = ID_MAIN, id_short = 'aaaaaaaaaa', ticket = 'iroh://' .. ID_MAIN .. '?relay=https%3A%2F%2Frelay.example.net.%2F',
        relay_mode = 'default', relays = { { url = 'https://relay.example.net./', connected = true } },
        addrs = { '192.0.2.4:4433' },
        conns = {
          { n = 1, dir = 'in', peer = ID_FAST, open = true, paths = {}, moq = { frames = o.objects } },
          { n = 2, dir = 'in', peer = ID_SLOW, open = true, paths = {}, moq = { frames = o.slow_objects } },
          { n = 3, dir = 'in', peer = ID_PEER, open = true, paths = {
            { id = 'PathId(0)', kind = 'direct', addr = 'ip:198.51.100.9:1234', selected = true, rtt_us = 12500 } },
            moq = { frames = o.peer_frames } },
        },
        events = { { t_ms = 5, conn = 3, what = 'opened', kind = 'direct', addr = 'ip:198.51.100.9:1234' } },
        pubs = { { h = 2, broadcast = 'netlab', track = 'frames', group = o.group, index = 3, groups = o.group + 1, objects = o.objects, bytes = 1 } },
        subs = {},
      } },
      { role = 'viewer', name = 'viewer 1', h = 3, stats = { id = ID_FAST, id_short = 'bbbbbbbbbb',
        conns = { { n = 1, dir = 'out', peer = ID_MAIN, open = true, paths = fast_paths, moq = { frames = o.objects } } },
        events = fast_events,
        subs = { { h = 4, state = 'live', group = o.group, index = 3, latest = o.group, behind = 0, objects = o.objects,
          groups = o.group, skipped = 0, cut = 0, lat_us = 380, lat_avg_us = 400, max_age_ms = 500, peer = ID_MAIN } } } },
      { role = 'viewer', name = 'viewer 2', h = 5, stats = { id = ID_SLOW, id_short = 'cccccccccc',
        conns = { { n = 1, dir = 'out', peer = ID_MAIN, open = true, paths = {
          { id = 'PathId(0)', kind = 'direct', addr = 'ip:192.0.2.4:4433', selected = true, rtt_us = 900 } } } },
        events = { { t_ms = 12, conn = 1, what = 'selected', kind = 'direct', addr = 'ip:192.0.2.4:4433' } },
        subs = { { h = 6, state = 'live', group = o.slow_group, index = 1, latest = o.group, behind = o.group - o.slow_group,
          objects = o.slow_objects, groups = 2, skipped = o.skipped, cut = 1, lat_us = 780000, lat_avg_us = 700000,
          max_age_ms = 0, peer = ID_MAIN } } } },
    },
    pubs = { { name = 'netlab', source = 'run:foot', h = 2, live = true, w = 960, h_px = 540, fps = 29.5,
      objects = o.objects, groups = o.group + 1, bytes = 1, group = o.group, group_ms = 1000, why = '' } },
    subs = {
      { id = 4, node = 3, name = 'netlab', viewed = true, slow_ms = 0, delivered = o.objects, dropped = 0, ended = false, why = '' },
      { id = 6, node = 5, name = 'netlab', viewed = false, slow_ms = 120, delivered = 0, dropped = 0, ended = false, why = '' },
    },
    demo = { pending = false, fast = 4, slow = 6 },
  })
end

N.state.now = 20
N.on_stats(stats({ t = 900, group = 7, objects = 70, slow_group = 5, slow_objects = 20, skipped = 1, peer_frames = 60 }))
local m = N.state.model
assert(m and m.built and m.started and m.me.id == ID_MAIN and m.me.relay_host == 'relay.example.net' and m.me.relay_ok)
assert(m.pub.name == 'netlab' and m.pub.source == 'run:foot' and m.pub.group == 7 and m.pub.w == 960)
assert(#m.subs == 2 and m.subs[1].label == 'fast' and m.subs[1].viewed and m.subs[2].label == 'slow' and m.subs[2].slow_ms == 120)
assert(m.subs[1].conn.kind == 'relay' and m.subs[1].conn.relay_rtt_ms == 31 and not m.subs[1].conn.direct_rtt_ms)
assert(m.subs[2].skipped == 1 and m.subs[2].cut == 1 and m.subs[2].behind == 2 and m.subs[2].lat_ms == 780)
assert(#m.remote == 1 and m.remote[1].conn.kind == 'direct' and m.remote[1].objects == 60, 'the peer from elsewhere, not our own viewers')
assert(#m.subs[1].events == 2 and m.subs[1].events[1].what == 'opened')
assert(N.state.view_sub == 4)

-- 100 ms later: the fast one went direct, the slow one lost 2 more groups,
-- objects moved on every pipe
N.state.now = 20.1
N.on_stats(stats({ t = 1300, group = 8, objects = 79, slow_group = 8, slow_objects = 24, skipped = 3, peer_frames = 69, fast_direct = true }))
m = N.state.model
local sw = N.state.switches['sub:4']
assert(sw and sw.from == 'relay' and sw.to == 'direct' and sw.t0 == 20.1, 'the switch from relay to direct')
local dots = {}
for _, d in ipairs(N.state.dots) do dots[d.key] = (dots[d.key] or 0) + 1 end
assert(dots['sub:6'] == 4, 'the slow one: 4 objects')
assert(dots['peer:' .. ID_PEER] == 9, 'the peer: 9 objects')
assert(not dots['sub:4'], "the viewed one's objects come from NLFRAMEs")
local ghosts = 0
for _, g in ipairs(N.state.ghosts) do if g.key == 'sub:6' then ghosts = ghosts + 1 end end
assert(ghosts == 2, 'two more groups skipped: ' .. ghosts)
assert(#N.state.pulses == 1 and N.state.pulses[1].group == 8, 'a ring for group 8')
assert(#N.state.rtt['sub:4'] == 2 and N.state.rtt['sub:4'][2] == 0.42)

-- the viewed subscription's objects, one by one
N.on_object(4, 9, 0, 1, 350)
N.on_object(4, 9, 1, 0, 360)
assert(N.state.key_flash == 20.1 and N.state.last_object.index == 1)
local fast_dots, starts = 0, 0
for _, d in ipairs(N.state.dots) do
  if d.key == 'sub:4' then
    fast_dots = fast_dots + 1
    if d.start then starts = starts + 1 end
  end
end
assert(fast_dots == 2 and starts == 1)

-- drawn: both subscribers, the peer, the switch, the skipped groups, the
-- paths with their rtt, the holepunch time, and the fast one's picture
N.state.now = 20.4
t = draw()
for _, want in ipairs{ 'NETLAB', 'relay.example.net', 'broadcast netlab', 'fast', 'slow  reads 120 ms/obj',
    '(remote)', 'relay \u{2192} direct', 'skipped', 'iroh paths', 'holepunched in 1250 ms', 'direct  0.4 ms',
    '192.0.2.4:4433', 'group 9 \u{b7} object 1', 'what the fast subscriber sees' } do
  assert(has(t, want), 'drawn: ' .. want .. '\n' .. t)
end
assert(#images == 1 and images[1].sub == 4 and images[1].x1 > images[1].x0)
local canvases = 0
for _, d in ipairs(drawn) do if d.kind == 'canvas' then canvases = canvases + 1 end end
assert(canvases == 5, 'header, pipeline, legend, paths, video')

-- things in flight leave when they arrive
N.state.now = 30
draw()
assert(#N.state.dots == 0 and #N.state.ghosts == 0 and #N.state.pulses == 0)

-- the slow viewer: slower, and back
sent = {}
N.command('slow 300')
assert(sent[1].cmd == 'slow 6 300' and N.config.slow_ms == 300)
press['Faster##netlab_faster'] = true
draw()
press = {}
assert(sent[2].cmd == 'slow 6 240', sent[2] and sent[2].cmd)
N.config.slow_ms = 120

-- the ticket: copied and echoed
sent = {}
N.command('ticket')
N.on_reply(sent[1].req, true, 'iroh://abc')
assert(copied[#copied] == 'iroh://abc' and echoed[#echoed] == 'netlab ticket: iroh://abc')

-- subscribing to another agent's broadcast
sent = {}
N.command('sub iroh://xyz?relay=https%3A%2F%2Fr')
assert(sent[1].cmd == 'subscribe iroh://xyz?relay=https%3A%2F%2Fr netlab view age=500', sent[1].cmd)
N.command('sub iroh://xyz other')
assert(sent[2].cmd == 'subscribe iroh://xyz other view age=500')
N.command('sub')
assert(N.state.note_bad and has(N.state.note, 'usage'))

-- layout: every subscriber inside the canvas, whatever their number
for n = 0, 6 do
  local mm = { subs = {}, remote = {}, me = { relay_url = 'x' } }
  for i = 1, n do mm.subs[i] = { key = 'k' .. i } end
  local L = N.layout(mm, 10, 20, 800, 250)
  assert(#L.subs == n and L.relay)
  for _, s in ipairs(L.subs) do assert(s.y >= 20 and s.y <= 270 and s.x > L.pub.x) end
end
local bx, by = N.bezier(0, 0, 50, 100, 100, 0, 0.5)
assert(bx == 50 and by == 50)
assert(N.host_of('https://euw1-1.relay.iroh.network./') == 'euw1-1.relay.iroh.network')
assert(N.ms(420) == '0.42 ms' and N.ms(31000) == '31.0 ms' and N.ms(780000) == '780 ms')

-- stop: everything in flight goes, the picture is forgotten
sent = {}
N.command('stop')
assert(sent[1].cmd == 'stop' and forgotten[1] == 4 and #N.state.dots == 0 and N.state.view_sub == nil)

-- an agent without netlab, and no agent at all
N.on_stats(json.encode({ built = false, started = false, backend = 'test', relay = '', nodes = {}, pubs = {}, subs = {}, demo = { pending = false, fast = 0, slow = 0 } }))
assert(N.state.note_bad and has(N.state.note, 'no netlab'))
t = draw()
assert(has(t, 'this agent has no netlab'), t)
send_error = 'the agent is not connected'
N.command('demo')
assert(N.state.note_bad and N.state.note == 'the agent is not connected')
send_error = nil

-- garbage from the agent changes nothing
local before = N.state.model
N.on_stats('{not json')
assert(N.state.model == before)
N.on_reply(999, true, 'late')
print('OK lua/netlab.lua')
