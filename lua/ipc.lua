-- GhosttyDalamud.v1.Call: what other plugins may ask, and how (docs/IPC.md).
-- The core runs this module twice (core/app/ipc.nelua):
--
--   * M.call(request_json) -> response_json in a small Lua state of its own,
--     on whatever thread the calling plugin uses. It sees only
--     ghostty.ipc_snapshot() (the last frame's JSON), ghostty.ipc_enqueue()
--     (hand a change to the next frame) and ghostty.ipc_request_id(). Reads answer at once from the
--     snapshot; changes are checked here and queued.
--   * M.run(queued_json) and M.snapshot() -> json in the core's own Lua state,
--     from the frame: run a queued change through ghostty.window_* (and
--     ghostty.panel_*, terminal_new, agent_windows_refresh), then describe the
--     window panels, the focus and the agent's window list for the next reads.
--
-- Request:  {"method": "...", "params": {...}, "caller": "PluginName"}
-- Response: {"ok": true, "result": ...} or {"ok": false, "error": "..."}

local json = require('json')

local M = {}

-- Results of queued changes kept for window.list's `requests`, newest last.
M.max_results = 16
-- Longest string parameter (commands, match text, pin arguments, caller).
M.max_string = 1024

-- The call side (any thread) ------------------------------------------------------------

local function reply(result)
  return json.encode({ ok = true, result = result })
end

local function refuse(reason)
  return json.encode({ ok = false, error = reason })
end

local function is_object(v)
  return type(v) == 'table' and v ~= json.null and getmetatable(v) ~= json.array_mt
end

-- A string parameter: nil when absent; false and why when unusable.
local function opt_string(p, k, non_empty)
  local v = p[k]
  if v == nil or v == json.null then return nil end
  if type(v) ~= 'string' then return false, k .. ' must be a string' end
  if #v > M.max_string then return false, k .. ' is too long' end
  if v:find('[%z\1-\31\127]') then return false, k .. ' must not contain control characters' end
  if non_empty and v == '' then return false, k .. ' must not be empty' end
  return v
end

local function panel_id(p)
  local id = p.id
  if math.type(id) ~= 'integer' or id < 1 then return false, 'id must be a panel id (a positive integer from window.list)' end
  return id
end

-- Each change: params -> the params the frame gets, or false and why.
local changes = {}

changes['window.open'] = function(p)
  local out, err = {}, nil
  for _, k in ipairs({ 'run', 'match', 'pin', 'agent' }) do
    out[k], err = opt_string(p, k, k ~= 'match')
    if out[k] == false then return false, err end
  end
  if p.wid ~= nil and p.wid ~= json.null then
    if math.type(p.wid) ~= 'integer' or p.wid < 1 or p.wid > 0xffffffff then
      return false, 'wid must be a window id (a positive integer)'
    end
    out.wid = p.wid
  end
  local n = (out.run and 1 or 0) + (out.match and 1 or 0) + (out.wid and 1 or 0)
  if n > 1 then return false, 'give at most one of run, match and wid' end
  return out
end

changes['window.close'] = function(p)
  local id, err = panel_id(p)
  if not id then return false, err end
  return { id = id }
end

changes['window.focus'] = changes['window.close']
changes['window.toggle_pet'] = changes['window.close']

changes['window.hide'] = function(p)
  local id, err = panel_id(p)
  if not id then return false, err end
  if type(p.hidden) ~= 'boolean' then return false, 'hidden must be true or false' end
  return { id = id, hidden = p.hidden }
end

changes['agent.windows.refresh'] = function(p)
  local agent, err = opt_string(p, 'agent', true)
  if agent == false then return false, err end
  if agent and agent ~= 'default' then return false, 'agent may only be "default" so far' end
  return {}
end

changes['terminal.new'] = function(p)
  local out, err = {}, nil
  out.pin, err = opt_string(p, 'pin', true)
  if out.pin == false then return false, err end
  local prof = p.profile
  if prof == nil or prof == json.null then
    out.profile = nil
  elseif math.type(prof) == 'integer' then
    if prof < 1 then return false, 'profile must be a name or a number from 1' end
    out.profile = prof
  else
    out.profile, err = opt_string(p, 'profile', true)
    if not out.profile then return false, err or 'profile must be a name or a number from 1' end
  end
  return out
end

changes['focus.cycle'] = function(p)
  local dir = p.dir
  if dir == nil or dir == json.null then dir = 'next' end
  if dir == 1 then dir = 'next' elseif dir == -1 then dir = 'prev' end
  if dir ~= 'next' and dir ~= 'prev' then return false, 'dir must be "next" or "prev"' end
  return { dir = dir }
end

changes['window.place'] = function(p)
  local id, err = panel_id(p)
  if not id then return false, err end
  local pin
  pin, err = opt_string(p, 'pin', true)
  if not pin then return false, err or 'pin is required (arguments as /term pin takes them)' end
  return { id = id, pin = pin }
end

-- keys.reserve {chords = {'super+*', ...}}: the caller's chords (replacing
-- its earlier ones; [] lets them go). Checked here for shape, by the core for
-- meaning (core/keychords.nelua).
M.max_chords = 64
changes['keys.reserve'] = function(p)
  local c = p.chords
  if type(c) ~= 'table' or getmetatable(c) ~= json.array_mt then return false, 'chords must be an array of strings' end
  if #c > M.max_chords then return false, 'at most ' .. M.max_chords .. ' chords' end
  local out = json.array()
  for i, v in ipairs(c) do
    if type(v) ~= 'string' or v == '' or #v > 64 or v:find('[%z\1-\31\127 ]') then
      return false, 'chords must be strings like "super+*" or "alt+shift+q"'
    end
    out[i] = v
  end
  return { chords = out }
end

-- The part of the snapshot each read returns.
local reads = {
  ['window.list'] = function(s) return { rev = s.rev, windows = s.windows, requests = s.requests } end,
  ['agent.status'] = function(s) return s.agent end,
  ['agent.windows'] = function(s) return s.agent_windows end,
  ['agent.apps'] = function(s) return s.agent_apps end,
  ['focus.get'] = function(s) return s.focus end,
  ['status'] = function(s) return s.status end,
}

function M.call(text)
  local req, err = json.decode(text)
  if req == nil then return refuse('malformed JSON: ' .. err) end
  if not is_object(req) then return refuse('the request must be a JSON object') end
  if type(req.method) ~= 'string' then return refuse('the request has no method') end
  local params = req.params
  if params == nil or params == json.null then params = {} end
  if not is_object(params) then return refuse('params must be a JSON object') end
  local caller
  caller, err = opt_string(req, 'caller')
  if caller == false then return refuse(err) end
  if caller == nil then
    caller, err = opt_string(params, 'caller')
    if caller == false then return refuse(err) end
  end

  local read = reads[req.method]
  if read then
    local raw = ghostty.ipc_snapshot()
    local snap = raw and json.decode(raw)
    if not snap then return refuse('ghostty is starting; ask again after the next frame') end
    return reply(read(snap))
  end

  local check = changes[req.method]
  if not check then return refuse('unknown method: ' .. req.method) end
  local clean
  clean, err = check(params)
  if not clean then return refuse(err) end
  -- request ids are opaque and increasing (core/app/ipc.nelua hands them out)
  local id = ghostty.ipc_request_id()
  local queued = json.encode({ request = id, method = req.method, params = clean, caller = caller })
  if not ghostty.ipc_enqueue(queued) then return refuse('too many changes waiting; ask again after the next frame') end
  return reply({ queued = true, request = id })
end

-- The frame side (the core's Lua state) -------------------------------------------------

M.results = {}

-- The world anchor of panel `id` (lua/world.lua), or nil.
local function anchor(id)
  local ok, world = pcall(require, 'world')
  return ok and world.anchors and world.anchors[id] or nil
end

-- A world panel's anchor as it is: pet, pin (fixed in the world), me or
-- target (following a character), orbit, or whatever kind a config added.
local function anchor_name(a)
  if not a then return 'none' end
  if a.kind == 'world' then return 'pin' end
  if a.kind == 'follow' then return a.player and 'me' or 'target' end
  return tostring(a.kind)
end

-- focus.cycle: the next (or previous) shown world panel after the focused one.
local function cycle(dir)
  local list = {}
  for _, p in ipairs(ghostty.world_panels()) do
    local a = anchor(p.id)
    if a and not a.hidden then list[#list + 1] = p end
  end
  if #list == 0 then return nil, 'no world panel shown' end
  local at
  for i, p in ipairs(list) do if p.focused then at = i end end
  local k
  if dir == 'prev' then k = at and ((at - 2) % #list + 1) or #list
  else k = at and (at % #list + 1) or 1 end
  local id = list[k].id
  local ok, err = ghostty.panel_focus(id)
  if not ok then return nil, err end
  return { id = id }
end

local function record(entry)
  local r = M.results
  r[#r + 1] = entry
  while #r > M.max_results do table.remove(r, 1) end
end

-- Run one queued change (written by M.call above, so its shape is known).
function M.run(text)
  local req = json.decode(text)
  if not req then return end
  local p = req.params
  local caller = type(req.caller) == 'string' and req.caller or nil
  local result, err
  if req.method == 'window.open' then
    local id
    id, err = ghostty.window_open({ run = p.run, match = p.match, wid = p.wid, pin = p.pin, agent = p.agent, caller = caller or 'IPC' })
    if id then result = { id = id } end
  elseif req.method == 'window.close' then
    result, err = ghostty.window_close(p.id)
  elseif req.method == 'window.focus' then
    local a = anchor(p.id)
    if a and a.hidden then err = 'the panel is hidden (window.hide it with hidden false first)'
    else result, err = ghostty.panel_focus(p.id) end
  elseif req.method == 'window.hide' then
    result, err = ghostty.panel_hide(p.id, p.hidden)
  elseif req.method == 'window.toggle_pet' then
    result, err = ghostty.panel_toggle_pet(p.id)
  elseif req.method == 'agent.windows.refresh' then
    result, err = ghostty.agent_windows_refresh()
  elseif req.method == 'terminal.new' then
    local id
    id, err = ghostty.terminal_new({ profile = p.profile and tostring(p.profile) or nil, pin = p.pin })
    if id then result = { id = id } end
  elseif req.method == 'focus.cycle' then
    result, err = cycle(p.dir)
  elseif req.method == 'window.place' then
    result, err = ghostty.window_place(p.id, p.pin)
  elseif req.method == 'keys.reserve' then
    local n
    n, err = ghostty.keys_reserve(caller or '', p.chords)
    if n then result = { chords = n } end
  else
    err = 'unknown method: ' .. tostring(req.method)
  end
  local entry = { request = req.request, method = req.method, ok = result ~= nil }
  if result ~= nil then
    entry.result = type(result) == 'table' and result or {}
  else
    entry.error = err or 'failed'
    if ghostty.log then ghostty.log(string.format('ipc: %s%s: %s', req.method, caller and (' from ' .. caller) or '', entry.error)) end
  end
  record(entry)
end

local rev, last_body = 0, nil

-- A window panel's kind: full, tab, or its world anchor's (pet, hud or pin).
local function kind_of(w)
  if w.view ~= 'world' then return w.view end
  local a = anchor(w.id)
  if a and (a.kind == 'pet' or a.kind == 'hud') then return a.kind end
  return 'pin'
end

-- What the reads answer from, as JSON; `rev` moves whenever the windows or
-- the request results change.
function M.snapshot()
  local windows = json.array()
  for _, w in ipairs(ghostty.window_list()) do
    local a = anchor(w.id)
    windows[#windows + 1] = {
      id = w.id, sid = w.sid, title = w.title, app = w.app, w = w.w, h = w.h,
      state = w.state, kind = kind_of(w), focused = w.focused,
      hidden = (a and a.hidden) and true or false, anchor = anchor_name(a),
      agent = w.agent or 'default', key = w.key or '',
    }
  end
  local requests = json.array()
  for i, r in ipairs(M.results) do requests[i] = r end
  local body = json.encode({ windows = windows, requests = requests })
  if body ~= last_body then
    rev = rev + 1
    last_body = body
  end
  -- the agent's last WLISTR, and the focused world panel
  local listed = ghostty.agent_windows and ghostty.agent_windows() or { windows = {}, apps = {} }
  local wins, apps = json.array(), json.array()
  for i, e in ipairs(listed.windows) do
    local extra = json.array()
    for k, v in ipairs(e.extra or {}) do extra[k] = v end
    wins[i] = { wid = e.wid, w = e.w, h = e.h, app = e.app, title = e.title, key = e.key, extra = extra }
  end
  for i, a in ipairs(listed.apps) do apps[i] = { id = a.id, name = a.name, icon = a.icon, categories = a.categories } end
  local focus = { id = 0 }
  for _, p in ipairs(ghostty.world_panels and ghostty.world_panels() or {}) do
    if p.focused then focus = { id = p.id, kind = p.window and 'window' or 'terminal' } end
  end
  return json.encode({
    rev = rev, windows = windows, requests = requests,
    agent = ghostty.agent_status(), status = ghostty.status(),
    agent_windows = wins, agent_apps = apps, focus = focus,
  })
end

return M
