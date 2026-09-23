-- Netlab: iroh and moq, live (docs/NETLAB.md). The agent does the networking
-- (agent/netlab.nelua): a window published as a moq broadcast over iroh and
-- subscribers to it. This panel asks it for things (ghostty.netlab_send ->
-- NLCTL) and draws what it reports (NLSTAT, every 100 ms, and the viewed
-- subscription's frames):
--
--   * iroh: your endpoint, its home relay, every connection's network paths
--     (relay or direct, which one carries the data, the rtt of each), and the
--     path timeline: a connection starts on the relay, iroh holepunches a
--     direct path and switches to it, live.
--   * moq: the publisher's live edge (group and object), a pipe per
--     subscriber along which objects fly (squares start a group: a key
--     frame; dots are the deltas after it), each subscriber's latency and
--     how far behind it is, and what moq does when one falls behind: whole
--     groups skipped (the crossed-out ones), never queued.
--   * the window itself, as the fast subscriber received it.
--
--   /term netlab                 show or hide the panel
--   /term netlab demo [WINDOW]   publish WINDOW (the agent's match text: a
--                                title, `run:CMD` on Linux, '' for the first)
--                                and subscribe a fast and a slow viewer to it
--   /term netlab sub TICKET      subscribe to another agent's broadcast
--   /term netlab slow MS         how slowly the slow viewer reads (0: full speed)
--   /term netlab relay MODE      default (n0's relays) | off | a relay URL, for the next start
--   /term netlab ticket          copy this agent's ticket to the clipboard
--   /term netlab stop            end it all
--
-- Everything here is Lua; the core only sends, receives, decodes the frames
-- and draws the shapes (core/app/netlab.nelua, core/uidraw.nelua).

local json = require('json')

local M = {}

M.config = {
  relay = 'default',   -- 'default' (n0's public relays), 'off' (direct only), or a relay URL
  window = '',         -- what `demo` publishes: the agent's match text
  slow_ms = 120,       -- the slow viewer reads one object every this many ms
  age_ms = 500,        -- the fast viewer's moq max_age
  watch_ms = 100,      -- NLSTAT this often
  travel = 0.6,        -- seconds an object takes along a pipe at the least
  stretch = 4,         -- ... plus its measured latency times this (so it can be seen)
}

local function cfg() return M.config end

-- State ----------------------------------------------------------------------------------

local S
function M.reset()
  S = {
    shown = false,
    focus = false,
    now = 0,
    stats = nil,        -- the last NLSTAT, decoded
    stats_at = 0,
    model = nil,        -- M.model(stats)
    pending = {},       -- req -> { what =, at = }
    note = '',          -- the status line
    note_bad = false,
    prev = {},          -- per subscriber key: counters at the last NLSTAT
    dots = {},          -- objects in flight: { key, t0, dur, group, start }
    ghosts = {},        -- groups skipped: { key, t0, group }
    pulses = {},        -- the publisher starting a group: { t0, group }
    switches = {},      -- per key: { from, to, t0 } when the selected path changed
    sel = {},           -- per key: the selected path kind last seen
    rtt = {},           -- per key: recent selected-path rtt samples (ms)
    key_flash = -10,    -- when the viewed picture last got a key frame
    last_object = nil,  -- the viewed subscription's last NLFRAME
    view_sub = nil,     -- the subscription whose frames are shown
    demo_asked = false,
  }
  M.state = S
end
M.reset()

local function note(text, bad)
  S.note, S.note_bad = text or '', bad and true or false
end

local function send(cmd, what)
  if not (ghostty and ghostty.netlab_send) then note('this core has no netlab', true) return nil end
  local req, why = ghostty.netlab_send(cmd)
  if not req then note(why or 'not sent', true) return nil end
  S.pending[req] = { what = what or cmd, at = S.now }
  return req
end

-- Helpers ------------------------------------------------------------------------------

local function num(v, d)
  if type(v) == 'number' then return v end
  return d or 0
end

local function str(v, d)
  if type(v) == 'string' then return v end
  return d or ''
end

local function list(v)
  if type(v) == 'table' then return v end
  return {}
end

-- 'https://euw1-1.relay.iroh.network./' -> 'euw1-1.relay.iroh.network'
function M.host_of(url)
  local h = str(url):match('^%a[%w+.-]*://([^/:]+)') or str(url)
  return (h:gsub('%.$', ''))
end

function M.ms(us)
  us = num(us)
  if us < 1000 then return string.format('%.2f ms', us / 1000) end
  if us < 100000 then return string.format('%.1f ms', us / 1000) end
  return string.format('%d ms', math.floor(us / 1000 + 0.5))
end

local function short(id)
  id = str(id)
  if #id <= 10 then return id end
  return id:sub(1, 5) .. '\u{2026}' .. id:sub(-3)
end

-- The paths of one connection, and which kind carries the data.
local function conn_view(c)
  if type(c) ~= 'table' then return nil end
  local v = { n = num(c.n), dir = str(c.dir), peer = str(c.peer), open = c.open == true, paths = {}, events = {} }
  for _, p in ipairs(list(c.paths)) do
    local path = { kind = str(p.kind), addr = str(p.addr), selected = p.selected == true, rtt_ms = num(p.rtt_us) / 1000 }
    v.paths[#v.paths + 1] = path
    if path.selected then v.kind, v.rtt_ms = path.kind, path.rtt_ms end
    if path.kind == 'relay' and (not v.relay_rtt_ms or path.rtt_ms < v.relay_rtt_ms) then v.relay_rtt_ms = path.rtt_ms end
    if path.kind == 'direct' and (not v.direct_rtt_ms or path.rtt_ms < v.direct_rtt_ms) then v.direct_rtt_ms = path.rtt_ms end
  end
  v.frames = num(type(c.moq) == 'table' and c.moq.frames)
  return v
end

-- A node's path events for connection `n`, oldest first.
local function events_of(node_stats, n)
  local out = {}
  for _, e in ipairs(list(node_stats and node_stats.events)) do
    if num(e.conn) == n then
      out[#out + 1] = { t_ms = num(e.t_ms), what = str(e.what), kind = str(e.kind), addr = str(e.addr) }
    end
  end
  table.sort(out, function(a, b) return a.t_ms < b.t_ms end)
  return out
end

-- What the panel draws, from one NLSTAT (pure: tests call it).
function M.model(st)
  if type(st) ~= 'table' then return nil end
  local m = { built = st.built == true, started = st.started == true, backend = str(st.backend),
    relay_mode = str(st.relay, 'default'), subs = {}, remote = {} }
  local nodes = {}
  local main
  local viewer_ids = {}
  for _, n in ipairs(list(st.nodes)) do
    nodes[num(n.h)] = n
    if n.role == 'main' then main = n end
    if n.role == 'viewer' and type(n.stats) == 'table' then viewer_ids[str(n.stats.id)] = true end
  end
  local ms = main and type(main.stats) == 'table' and main.stats or nil
  if ms then
    local relay = list(ms.relays)[1]
    m.me = {
      id = str(ms.id), id_short = str(ms.id_short), ticket = str(ms.ticket),
      relay_url = relay and str(relay.url) or nil,
      relay_ok = relay and relay.connected == true or false,
      addrs = list(ms.addrs),
    }
    if m.me.relay_url then m.me.relay_host = M.host_of(m.me.relay_url) end
  end
  local p = list(st.pubs)[1]
  if p then
    local mp = ms and list(ms.pubs)[1] or {}
    m.pub = { name = str(p.name), source = str(p.source), w = num(p.w), h = num(p.h_px), fps = num(p.fps),
      live = p.live == true, why = str(p.why), group = num(mp.group, num(p.group)), index = num(mp.index),
      objects = num(p.objects), groups = num(p.groups), group_ms = num(p.group_ms, 1000) }
  end
  local demo = type(st.demo) == 'table' and st.demo or {}
  m.demo_pending = demo.pending == true
  for _, s in ipairs(list(st.subs)) do
    local node = nodes[num(s.node)]
    local ns = node and type(node.stats) == 'table' and node.stats or {}
    local q = list(ns.subs)[1] or {}
    local c = conn_view(list(ns.conns)[1])
    local id = num(s.id)
    local label = node and str(node.name) or ('sub ' .. id)
    if id == num(demo.fast) then label = 'fast' elseif id == num(demo.slow) then label = 'slow' end
    m.subs[#m.subs + 1] = {
      key = 'sub:' .. id, id = id, label = label, viewed = s.viewed == true, slow_ms = num(s.slow_ms),
      ended = s.ended == true, why = str(s.why, str(q.why)), state = str(q.state, 'dialing'),
      lat_ms = num(q.lat_us) / 1000, lat_avg_ms = num(q.lat_avg_us) / 1000,
      group = num(q.group), index = num(q.index), latest = num(q.latest), behind = num(q.behind),
      objects = num(q.objects), groups = num(q.groups), skipped = num(q.skipped), cut = num(q.cut),
      max_age_ms = num(q.max_age_ms), peer = str(q.peer), conn = c,
      events = c and events_of(ns, c.n) or {},
    }
  end
  -- peers subscribing to us from elsewhere: the main node's incoming
  -- connections that are not one of our own viewers
  for _, c in ipairs(list(ms and ms.conns)) do
    if c.dir == 'in' and not viewer_ids[str(c.peer)] and c.open == true then
      local v = conn_view(c)
      m.remote[#m.remote + 1] = { key = 'peer:' .. str(c.peer), label = short(c.peer), conn = v,
        objects = v.frames, events = events_of(ms, v.n), remote = true }
    end
  end
  return m
end

-- What moved since the last NLSTAT: objects to fly, groups skipped, paths switched.
local function animate(m)
  local now = S.now
  local every = cfg().watch_ms / 1000
  if m.pub then
    local pv = S.prev.pub
    if pv and m.pub.group > pv then
      for g = math.max(pv + 1, m.pub.group - 3), m.pub.group do S.pulses[#S.pulses + 1] = { t0 = now, group = g } end
    end
    S.prev.pub = m.pub.group
  end
  local function each(sub)
    local pv = S.prev[sub.key] or { objects = sub.objects, skipped = sub.skipped + sub.cut, group = sub.group }
    local fly = sub.objects - pv.objects
    -- the viewed subscription's objects come one by one (M.on_object)
    if sub.viewed and sub.id == S.view_sub then fly = 0 end
    if fly > 0 then
      local n = math.min(fly, 12)
      for i = 1, n do
        local g = pv.group + (sub.group - pv.group) * i / n
        S.dots[#S.dots + 1] = { key = sub.key, t0 = now + every * (i - 1) / n,
          dur = cfg().travel + math.min(3, sub.lat_ms / 1000 * cfg().stretch), group = math.floor(g + 0.5),
          start = i == 1 and sub.group ~= pv.group }
      end
    end
    local lost = sub.skipped + sub.cut - pv.skipped
    if lost > 0 then
      for i = 1, math.min(lost, 4) do
        S.ghosts[#S.ghosts + 1] = { key = sub.key, t0 = now + 0.08 * (i - 1), group = pv.group + i }
      end
    end
    local kind = sub.conn and sub.conn.kind
    if kind and S.sel[sub.key] and S.sel[sub.key] ~= kind then
      S.switches[sub.key] = { from = S.sel[sub.key], to = kind, t0 = now }
    end
    if kind then S.sel[sub.key] = kind end
    if sub.conn and sub.conn.rtt_ms then
      local h = S.rtt[sub.key] or {}
      h[#h + 1] = sub.conn.rtt_ms
      if #h > 60 then table.remove(h, 1) end
      S.rtt[sub.key] = h
    end
    S.prev[sub.key] = { objects = sub.objects, skipped = sub.skipped + sub.cut, group = sub.group }
  end
  for _, s in ipairs(m.subs) do each(s) end
  for _, r in ipairs(m.remote) do
    r.skipped, r.cut, r.group, r.lat_ms = 0, 0, m.pub and m.pub.group or 0, 0
    each(r)
  end
end

-- The agent ----------------------------------------------------------------------------

function M.on_stats(text)
  local st = json.decode(text)
  if type(st) ~= 'table' then return end
  S.stats, S.stats_at = st, S.now
  S.model = M.model(st)
  local m = S.model
  if not m then return end
  S.view_sub = nil
  for _, s in ipairs(m.subs) do
    if s.viewed then S.view_sub = s.id end
  end
  animate(m)
  if not m.built then note('this agent has no netlab (built without moq_iroh; docs/NETLAB.md)', true) end
end

function M.on_reply(req, ok, text)
  local p = S.pending[req]
  S.pending[req] = nil
  local what = p and p.what or 'netlab'
  if not ok then note(what .. ': ' .. text, true) return end
  if what == 'ticket' then
    if ghostty.ui and ghostty.ui.copy then ghostty.ui.copy(text) end
    if ghostty.ask_echo then ghostty.ask_echo('netlab ticket: ' .. text) end
    note('ticket copied to the clipboard')
  elseif what == 'demo' then
    note(text == 'running' and 'demo running' or ('demo: ' .. text))
  elseif text ~= '' then
    note(what .. ': ' .. text)
  else
    note(what .. ': done')
  end
end

-- One object of the viewed subscription arrived (NLFRAME).
function M.on_object(sub, group, index, flags, lat_us)
  S.last_object = { sub = sub, group = group, index = index, flags = flags, lat_us = lat_us, at = S.now }
  if flags & 1 ~= 0 then S.key_flash = S.now end
  local key = 'sub:' .. sub
  S.dots[#S.dots + 1] = { key = key, t0 = S.now, dur = cfg().travel + math.min(3, lat_us / 1e6 * cfg().stretch),
    group = group, start = flags & 1 ~= 0 }
  if #S.dots > 400 then table.remove(S.dots, 1) end
end

-- Commands -----------------------------------------------------------------------------

function M.show(focus)
  S.shown = true
  S.focus = focus ~= false
  send('watch ' .. cfg().watch_ms, 'watch')
end

function M.hide()
  S.shown = false
  send('watch 0', 'watch')
end

function M.demo(window)
  local c = cfg()
  if not S.shown then M.show(true) end
  local cmd = string.format('demo relay=%s slow=%d age=%d', c.relay, c.slow_ms, c.age_ms)
  window = window or c.window
  if window and window ~= '' then cmd = cmd .. ' window=' .. window end
  S.demo_asked = true
  note('starting the demo...')
  return send(cmd, 'demo')
end

function M.stop()
  S.dots, S.ghosts, S.pulses, S.switches, S.sel, S.prev = {}, {}, {}, {}, {}, {}
  if ghostty and ghostty.netlab_forget and S.view_sub then ghostty.netlab_forget(S.view_sub) end
  S.view_sub, S.demo_asked = nil, false
  return send('stop', 'stop')
end

local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end

-- /term netlab ARGS; true when taken (every form is).
function M.command(args)
  args = trim(args or '')
  local verb, rest = args:match('^(%S+)%s*(.*)$')
  verb = verb or ''
  if verb == '' then
    if S.shown then M.hide() else M.show(true) end
  elseif verb == 'show' then M.show(true)
  elseif verb == 'hide' then M.hide()
  elseif verb == 'demo' then M.demo(rest ~= '' and rest or nil)
  elseif verb == 'stop' then M.stop()
  elseif verb == 'ticket' then send('ticket', 'ticket')
  elseif verb == 'sub' or verb == 'subscribe' then
    local ticket, name = rest:match('^(%S+)%s*(%S*)$')
    if not ticket then note('usage: /term netlab sub TICKET [BROADCAST]', true) return true end
    if not S.shown then M.show(true) end
    send(string.format('subscribe %s %s view age=%d', ticket, name ~= '' and name or 'netlab', cfg().age_ms), 'subscribe')
  elseif verb == 'slow' then
    local ms = tonumber(rest)
    local m = S.model
    local slow
    for _, s in ipairs(m and m.subs or {}) do
      if s.label == 'slow' then slow = s end
    end
    if not ms or not slow then note('usage: /term netlab slow MS (with the demo running)', true) return true end
    cfg().slow_ms = math.floor(ms)
    send(string.format('slow %d %d', slow.id, math.floor(ms)), 'slow')
  elseif verb == 'relay' then
    if rest == '' then note('relay: ' .. cfg().relay) return true end
    cfg().relay = rest
    note('relay for the next start: ' .. rest .. ' (/term netlab stop, then demo)')
  else
    note('/term netlab [demo [WINDOW] | sub TICKET | slow MS | relay MODE | ticket | stop]', true)
  end
  return true
end

-- Per frame -----------------------------------------------------------------------------

function M.tick(now)
  S.now = now
  for req, p in pairs(S.pending) do
    if now - p.at > 5 then
      S.pending[req] = nil
      note(p.what .. ': no answer from the agent (is it older than netlab?)', true)
    end
  end
  local focus = S.focus
  S.focus = false
  return S.shown, focus
end

-- Drawing ------------------------------------------------------------------------------

local GROUP_COLORS = { 'accent-2', 'accent', 'ok', 'glow', 'popin', 'full' }

local function C(name, a) return ghostty.ui.color(name, a or 255) end

local function group_color(g, a)
  return C(GROUP_COLORS[(math.floor(g) % #GROUP_COLORS) + 1], a)
end

local function kind_color(kind, a)
  if kind == 'relay' then return C('accent', a) end
  return C('accent-2', a)
end

local function ease(t) return t * t * (3 - 2 * t) end

-- A point on the quadratic curve p0 -> p1 bent towards c.
function M.bezier(p0x, p0y, cx, cy, p1x, p1y, t)
  local u = 1 - t
  return u * u * p0x + 2 * u * t * cx + t * t * p1x, u * u * p0y + 2 * u * t * cy + t * t * p1y
end

local function curve(ui, p0x, p0y, cx, cy, p1x, p1y, col, thick, dashed)
  local pts = {}
  local n = 24
  for i = 0, n do
    local x, y = M.bezier(p0x, p0y, cx, cy, p1x, p1y, i / n)
    pts[#pts + 1] = x
    pts[#pts + 1] = y
  end
  if not dashed then ui.poly(pts, col, thick) return end
  for i = 1, n, 2 do
    ui.line(pts[i * 2 - 1], pts[i * 2], pts[i * 2 + 1], pts[i * 2 + 2], col, thick)
  end
end

-- Where everything goes on the pipeline canvas (pure: tests call it).
function M.layout(m, x, y, w, h)
  local L = { pub = { x = x + 78, y = y + h * 0.56, r = 30 }, subs = {} }
  local all = {}
  for _, s in ipairs(m and m.subs or {}) do all[#all + 1] = s end
  for _, s in ipairs(m and m.remote or {}) do all[#all + 1] = s end
  local n = math.max(#all, 1)
  local top, bottom = y + 34, y + h - 26
  for i, s in ipairs(all) do
    local sy = n == 1 and (top + bottom) / 2 or top + (bottom - top) * (i - 1) / (n - 1)
    L.subs[#L.subs + 1] = { sub = s, x = x + w - 150, y = sy, r = 20 }
  end
  if m and m.me and m.me.relay_url then L.relay = { x = x + w * 0.45, y = y + 30, r = 16 } end
  return L
end

-- The route of subscriber node `sn`: control point, by the path in use.
local function route(Lay, sn, kind)
  local p = Lay.pub
  if kind == 'relay' and Lay.relay then return Lay.relay.x, Lay.relay.y - 30 end
  return (p.x + sn.x) / 2, (p.y + sn.y) / 2 + (sn.y - p.y) * 0.15
end

local function draw_header(ui, m)
  local x, y = ui.canvas('##netlab_head', ui.width(), 40)
  if not x then return end
  ui.text_at(x, y + 2, 'NETLAB', C('accent', 255), 1.45)
  ui.text_at(x + 118, y + 8, 'iroh + moq, live', C('ink-dim', 230))
  local px = x + 250
  if m and m.me then
    -- this endpoint
    ui.rect(px, y + 4, px + 170, y + 30, C('chip', 220), 13)
    ui.circle(px + 14, y + 17, 5, C('ok', 255))
    ui.text_at(px + 26, y + 8, 'you  ' .. short(m.me.id), C('ink', 255))
    px = px + 180
    local relay = m.me.relay_host or (m.relay_mode == 'off' and 'no relay' or 'relay: finding one')
    local tw = ui.text_size(relay)
    ui.rect(px, y + 4, px + tw + 36, y + 30, C('chip', 220), 13)
    ui.circle(px + 14, y + 17, 5, m.me.relay_ok and C('accent', 255) or C('ink-faint', 255))
    ui.text_at(px + 26, y + 8, relay, C('ink', 255))
  elseif m and not m.built then
    ui.text_at(px, y + 8, 'this agent has no netlab', C('close', 255))
  else
    ui.text_at(px, y + 8, 'not started: /term netlab demo', C('ink-dim', 255))
  end
end

local function draw_buttons(ui, m)
  local running = m and m.started
  if not running then
    if ui.small_button('Start demo##netlab_demo') then M.demo() end
  else
    if ui.small_button('Stop##netlab_stop') then M.stop() end
  end
  ui.same_line()
  if ui.small_button('Copy ticket##netlab_ticket') then send('ticket', 'ticket') end
  ui.same_line()
  if ui.small_button('Slower##netlab_slower') then M.command('slow ' .. (cfg().slow_ms + 60)) end
  ui.same_line()
  if ui.small_button('Faster##netlab_faster') then M.command('slow ' .. math.max(0, cfg().slow_ms - 60)) end
  ui.same_line()
  if ui.small_button('Hide##netlab_hide') then M.hide() end
  if S.note ~= '' then
    ui.same_line()
    ui.text(S.note)
  end
end

local function draw_pipeline(ui, m, w, h)
  local x, y = ui.canvas('##netlab_pipe', w, h)
  if not x then return end
  ui.rect(x, y, x + w, y + h, C('panel', 120), 10)
  ui.frame(x, y, x + w, y + h, C('accent-2', 40), 10, 1)
  local Lay = M.layout(m, x, y, w, h)
  local now = S.now
  local pub = Lay.pub

  -- relay
  if Lay.relay then
    local r = Lay.relay
    local hex = {}
    for i = 0, 6 do
      local a = math.pi / 3 * i + math.pi / 6
      hex[#hex + 1] = r.x + math.cos(a) * r.r
      hex[#hex + 1] = r.y + math.sin(a) * r.r
    end
    ui.poly(hex, m.me.relay_ok and C('accent', 230) or C('ink-faint', 200), 2)
    local label = 'relay ' .. (m.me.relay_host or '')
    local tw = ui.text_size(label, 0.85)
    ui.text_at(r.x - tw / 2, r.y + r.r + 2, label, C('ink-dim', 230), 0.85)
  end

  -- pipes, with the path not in use faint
  for _, sn in ipairs(Lay.subs) do
    local s = sn.sub
    local kind = s.conn and s.conn.kind
    local other = kind == 'relay' and 'direct' or 'relay'
    local has_other = s.conn and (other == 'relay' and s.conn.relay_rtt_ms or s.conn.direct_rtt_ms)
    if has_other and (other == 'direct' or Lay.relay) then
      local cx, cy = route(Lay, sn, other)
      curve(ui, pub.x, pub.y, cx, cy, sn.x, sn.y, kind_color(other, 70), 1.5, true)
    end
    if kind then
      local cx, cy = route(Lay, sn, kind)
      local sw = S.switches[s.key]
      local flash = sw and math.max(0, 1 - (now - sw.t0) / 1.5) or 0
      curve(ui, pub.x, pub.y, cx, cy, sn.x, sn.y, kind_color(kind, 90 + math.floor(120 * flash)), 7 + 6 * flash, false)
      curve(ui, pub.x, pub.y, cx, cy, sn.x, sn.y, kind_color(kind, 230), 2.2, false)
      -- the path and its rtt at the middle of the pipe
      local mx, my = M.bezier(pub.x, pub.y, cx, cy, sn.x, sn.y, 0.55)
      local label = kind .. '  ' .. string.format('%.1f ms', s.conn.rtt_ms or 0)
      ui.text_at(mx - 30, my - 20, label, kind_color(kind, 255), 0.85)
      if sw and now - sw.t0 < 3 then
        local a = math.floor(255 * math.max(0, 1 - (now - sw.t0) / 3))
        ui.text_at(mx - 40, my - 38 - (now - sw.t0) * 8, sw.from .. ' \u{2192} ' .. sw.to, C('ok', a), 1.0)
      end
    elseif s.conn == nil then
      -- still dialing: a faint dashed line
      curve(ui, pub.x, pub.y, (pub.x + sn.x) / 2, (pub.y + sn.y) / 2, sn.x, sn.y, C('ink-faint', 90), 1.5, true)
    end
  end

  -- objects in flight
  local keep = {}
  local by_key = {}
  for _, sn in ipairs(Lay.subs) do by_key[sn.sub.key] = sn end
  for _, d in ipairs(S.dots) do
    local t = (now - d.t0) / d.dur
    local sn = by_key[d.key]
    if t < 1 and sn then
      keep[#keep + 1] = d
      if t >= 0 then
        local kind = sn.sub.conn and sn.sub.conn.kind or 'direct'
        local cx, cy = route(Lay, sn, kind)
        local px, py = M.bezier(pub.x, pub.y, cx, cy, sn.x, sn.y, ease(t))
        if d.start then
          ui.rect(px - 6, py - 6, px + 6, py + 6, group_color(d.group, 255), 2)
          ui.frame(px - 8, py - 8, px + 8, py + 8, group_color(d.group, 110), 3, 1.5)
        else
          ui.circle(px, py, 3.6, group_color(d.group, 235))
        end
      end
    end
  end
  S.dots = keep

  -- groups skipped: crossed out, falling away before the subscriber
  local gk = {}
  for _, g in ipairs(S.ghosts) do
    local t = now - g.t0
    local sn = by_key[g.key]
    if t < 1.8 and sn then
      gk[#gk + 1] = g
      if t >= 0 then
        local a = math.floor(255 * (1 - t / 1.8))
        local gx, gy = sn.x - 70 - t * 10, sn.y + 8 + t * 34
        ui.rect(gx - 7, gy - 7, gx + 7, gy + 7, group_color(g.group, a // 3), 2)
        ui.line(gx - 7, gy - 7, gx + 7, gy + 7, C('close', a), 2)
        ui.line(gx - 7, gy + 7, gx + 7, gy - 7, C('close', a), 2)
        ui.text_at(gx + 10, gy - 8, 'g' .. g.group .. ' skipped', C('close', a), 0.8)
      end
    end
  end
  S.ghosts = gk

  -- the publisher: a ring per group that starts
  local pk = {}
  for _, p in ipairs(S.pulses) do
    local t = now - p.t0
    if t < 1 then
      pk[#pk + 1] = p
      ui.ring(pub.x, pub.y, pub.r + t * 26, group_color(p.group, math.floor(200 * (1 - t))), 2)
    end
  end
  S.pulses = pk
  ui.circle(pub.x, pub.y, pub.r, C('glass-top', 250))
  ui.ring(pub.x, pub.y, pub.r, m and m.pub and m.pub.live and group_color(m.pub.group, 255) or C('ink-faint', 255), 3)
  ui.text_at(pub.x - 14, pub.y - 8, 'PUB', C('ink', 255))
  if m and m.pub then
    local p = m.pub
    ui.text_at(x + 12, y + 10, 'broadcast ' .. p.name .. ' \u{b7} track frames', C('ink', 255))
    ui.text_at(x + 12, y + 28, string.format('%s  %dx%d  %.0f fps', p.source ~= '' and p.source or 'first window', p.w, p.h, p.fps), C('ink-dim', 230), 0.9)
    ui.text_at(pub.x - 40, pub.y + pub.r + 6, string.format('group %d \u{b7} obj %d', p.group, p.index), group_color(p.group, 255), 0.9)
    ui.text_at(pub.x - 40, pub.y + pub.r + 22, string.format('%d groups, %d objects', p.groups, p.objects), C('ink-dim', 220), 0.8)
    if not p.live and p.why ~= '' then ui.text_at(pub.x - 40, pub.y + pub.r + 38, p.why, C('close', 255), 0.8) end
    if p.live and p.w == 0 then
      ui.text_at(x + 12, y + h - 22, 'waiting for the window: /term netlab demo TITLE | run:CMD | app:NAME picks one', C('ink-dim', 240), 0.85)
    end
  elseif m and m.started then
    ui.text_at(x + 12, y + 10, 'nothing published', C('ink-dim', 255))
  end

  -- the subscribers
  for _, sn in ipairs(Lay.subs) do
    local s = sn.sub
    local live = s.state == 'live' or s.remote
    local col = s.ended and C('close', 255) or (live and C('ok', 255) or C('ink-faint', 255))
    ui.circle(sn.x, sn.y, sn.r, C('glass-top', 250))
    ui.ring(sn.x, sn.y, sn.r, col, 2.5)
    if s.viewed then
      ui.circle(sn.x, sn.y, 6, C('accent-2', 255))
      ui.ring(sn.x, sn.y, 10, C('accent-2', 200), 1.5)
    end
    local tx = sn.x + sn.r + 10
    local title = s.label .. (s.remote and '  (remote)' or '') .. (s.slow_ms and s.slow_ms > 0 and string.format('  reads %d ms/obj', s.slow_ms) or '')
    ui.text_at(tx, sn.y - 24, title, C('ink', 255))
    if s.remote then
      ui.text_at(tx, sn.y - 6, string.format('%d objects sent', s.objects), C('ink-dim', 240), 0.9)
    elseif s.ended then
      ui.text_at(tx, sn.y - 6, 'ended: ' .. s.why, C('close', 255), 0.85)
    elseif s.state ~= 'live' then
      ui.text_at(tx, sn.y - 6, s.state .. '\u{2026}', C('ink-dim', 240), 0.9)
    else
      ui.text_at(tx, sn.y - 6, M.ms(s.lat_ms * 1000) .. ' behind the publisher', C('ink', 255), 0.95)
      local lag = s.behind > 0 and string.format('%d groups behind \u{b7} ', s.behind) or ''
      ui.text_at(tx, sn.y + 10, lag .. string.format('%d skipped \u{b7} %d cut', s.skipped, s.cut),
        (s.skipped + s.cut) > 0 and C('close', 255) or C('ink-dim', 220), 0.85)
    end
  end
  if #Lay.subs == 0 and m and m.pub then
    ui.text_at(x + w - 260, y + h / 2 - 8, 'no subscribers yet', C('ink-dim', 255))
  end
end

local function draw_paths(ui, m, w, h)
  local x, y = ui.canvas('##netlab_paths', w, h)
  if not x then return end
  ui.rect(x, y, x + w, y + h, C('panel', 120), 10)
  ui.text_at(x + 12, y + 8, 'iroh paths', C('accent', 255))
  local rows = {}
  for _, s in ipairs(m and m.subs or {}) do rows[#rows + 1] = s end
  for _, s in ipairs(m and m.remote or {}) do rows[#rows + 1] = s end
  local ly = y + 30
  local focus
  for _, s in ipairs(rows) do
    if ly > y + h - 90 then break end
    ui.text_at(x + 12, ly, s.label, C('ink', 255), 0.9)
    local c = s.conn
    if not c then
      ui.text_at(x + 90, ly, 'dialing\u{2026}', C('ink-dim', 255), 0.9)
      ly = ly + 18
    else
      if not focus and #s.events > 0 then focus = s end
      for _, p in ipairs(c.paths) do
        local cx = x + 90
        if p.selected then ui.circle(cx, ly + 7, 4.5, kind_color(p.kind, 255))
        else ui.ring(cx, ly + 7, 4.5, kind_color(p.kind, 200), 1.2) end
        ui.text_at(cx + 10, ly, p.kind, kind_color(p.kind, 255), 0.85)
        local addr = p.addr:gsub('^ip:', '')
        if #addr > 34 then addr = addr:sub(1, 33) .. '\u{2026}' end
        ui.text_at(cx + 58, ly, addr, C('ink-dim', 230), 0.85)
        -- rtt on a log scale: 0.1 ms to 1 s
        local bx = x + w - 150
        local f = math.max(0, math.min(1, (math.log(math.max(p.rtt_ms, 0.1), 10) + 1) / 4))
        ui.rect(bx, ly + 3, bx + 70, ly + 11, C('glass-flat', 200), 3)
        ui.rect(bx, ly + 3, bx + 70 * f, ly + 11, kind_color(p.kind, p.selected and 230 or 110), 3)
        ui.text_at(bx + 76, ly, string.format('%.2f ms', p.rtt_ms), C('ink', 240), 0.85)
        ly = ly + 18
      end
      -- the selected path's rtt, recently
      local hist = S.rtt[s.key]
      if hist and #hist > 1 then
        local maxv = 0.1
        for _, v in ipairs(hist) do maxv = math.max(maxv, v) end
        local pts = {}
        for i, v in ipairs(hist) do
          pts[#pts + 1] = x + 90 + (i - 1) * ((w - 260) / 59)
          pts[#pts + 1] = ly + 14 - 12 * v / maxv
        end
        ui.poly(pts, kind_color(c.kind, 160), 1.2)
        ly = ly + 18
      end
    end
    ly = ly + 6
  end

  -- the timeline of one connection: relay first, then the holepunched path
  local ty = y + h - 58
  ui.line(x + 12, ty + 20, x + w - 12, ty + 20, C('ink-faint', 160), 1)
  if focus then
    local evs = focus.events
    local t0, t1 = evs[1].t_ms, evs[#evs].t_ms
    local span = math.max(t1 - t0, 1)
    ui.text_at(x + 12, ty - 6, 'timeline: ' .. focus.label, C('ink-dim', 230), 0.85)
    local first_relay, direct_sel
    for i, e in ipairs(evs) do
      local ex = x + 20 + (w - 60) * (e.t_ms - t0) / span
      local col = kind_color(e.kind, 255)
      if e.what == 'selected' then ui.circle(ex, ty + 20, 6, col)
      elseif e.what == 'closed' or e.what == 'gone' then
        ui.line(ex - 5, ty + 15, ex + 5, ty + 25, C('close', 255), 2)
        ui.line(ex - 5, ty + 25, ex + 5, ty + 15, C('close', 255), 2)
      else ui.ring(ex, ty + 20, 5, col, 1.5) end
      ui.text_at(ex - 12, ty + (i % 2 == 0 and 30 or 2), e.kind .. ' ' .. e.what, col, 0.75)
      if e.kind == 'relay' and not first_relay then first_relay = e.t_ms end
      if e.kind == 'direct' and e.what == 'selected' and not direct_sel then direct_sel = e.t_ms end
    end
    if first_relay and direct_sel and direct_sel >= first_relay then
      ui.text_at(x + w - 230, ty - 6, string.format('holepunched in %d ms', direct_sel - first_relay), C('ok', 255), 0.85)
    elseif direct_sel then
      ui.text_at(x + w - 230, ty - 6, 'direct from the start', C('accent-2', 255), 0.85)
    end
  else
    ui.text_at(x + 12, ty - 6, 'timeline: no connection yet', C('ink-dim', 200), 0.85)
  end
end

local function draw_video(ui, m, w, h)
  local x, y = ui.canvas('##netlab_video', w, h)
  if not x then return end
  ui.rect(x, y, x + w, y + h, C('glass-flat', 230), 10)
  local sub = S.view_sub
  local drawn = sub and ghostty.netlab_image and { ghostty.netlab_image(sub, x + 8, y + 26, x + w - 8, y + h - 22) } or {}
  local flash = math.max(0, 1 - (S.now - S.key_flash) / 0.4)
  ui.frame(x, y, x + w, y + h, flash > 0 and C('accent-2', math.floor(90 + 165 * flash)) or C('accent-2', 60), 10, 1 + 2 * flash)
  ui.text_at(x + 10, y + 6, 'what the fast subscriber sees', C('accent', 255), 0.9)
  if not drawn[1] then
    ui.text_at(x + 20, y + h / 2 - 8, sub and 'waiting for a key frame\u{2026}' or 'nothing viewed', C('ink-dim', 230))
    return
  end
  local o = S.last_object
  if o then
    ui.text_at(x + 10, y + h - 19, string.format('group %d \u{b7} object %d \u{b7} %s', o.group, o.index, M.ms(o.lat_us)),
      group_color(o.group, 255), 0.85)
  end
end

local function draw_legend(ui)
  local x, y = ui.canvas('##netlab_legend', ui.width(), 18)
  if not x then return end
  ui.rect(x, y + 3, x + 10, y + 13, C('accent-2', 255), 2)
  ui.text_at(x + 16, y, 'key frame: a group starts', C('ink-dim', 230), 0.8)
  ui.circle(x + 200, y + 8, 3.6, C('accent', 255))
  ui.text_at(x + 210, y, 'delta', C('ink-dim', 230), 0.8)
  ui.line(x + 262, y + 2, x + 274, y + 14, C('close', 255), 2)
  ui.line(x + 262, y + 14, x + 274, y + 2, C('close', 255), 2)
  ui.text_at(x + 280, y, 'group skipped for a subscriber that fell behind (moq drops, it does not queue)', C('ink-dim', 230), 0.8)
end

function M.draw()
  local ui = ghostty.ui
  local m = S.model
  draw_header(ui, m)
  draw_buttons(ui, m)
  ui.spacing()
  local w = ui.width()
  draw_pipeline(ui, m, w, 250)
  draw_legend(ui)
  local lw = math.floor(w * 0.56)
  draw_paths(ui, m, lw, 250)
  ui.same_line()
  draw_video(ui, m, w - lw - 8, 250)
  if ui.key_pressed and ui.key_pressed('escape') and ui.focused and ui.focused() then M.hide() end
end

return M
