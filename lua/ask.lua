-- /ask as a panel in the game: a conversation with a local AI assistant
-- (almanac by default) drawn as chat bubbles in Ghostty's glass, with
-- follow-ups. The core (core/app/ask.nelua) runs the command Lua builds on a
-- hidden session and hands every line of its output here; almanac's
-- `ask --stream-json` prints one JSON object per line (thread, text, tool,
-- result, done, error). almanac keeps each conversation as a thread, so a
-- follow-up reaches the model with what was said before.
--
--   /ask                 show or hide the panel
--   /ask <question>      ask in the current thread (the first question starts one)
--   /ask new [question]  start a new thread
--   /ask threads         the list of threads; click one to continue it
--   /ask pin             the panel onto a pet beside you (/window adopt ask)
--   /ask term [question] the old way: a terminal running the assistant
--
-- In the panel: Enter sends, Shift+Enter (or Ctrl+Enter) starts a new line,
-- Esc closes. Answers are markdown, drawn rich (lua/askview.lua): headings,
-- lists, tables, quotes, code blocks with a copy button, and links
-- (lua/asklinks.lua) -- https pages open in your browser, map coordinates,
-- zones, items, quests and duties open the game's own map, chat input,
-- journal or Duty Finder, slash commands go into the chat input (running one
-- asks first), and follow-up chips ask on click (right-click: in a new
-- conversation linked back to this one). Nothing is sent, run or opened
-- without a click. Game actions for the assistant stay off unless you tick
-- them, and XivMcp still asks you in game before each one.
--
-- What runs and how is configured in lua/assistant.lua (CONFIG.assistant):
-- `ui` ('panel' | 'terminal'), `stream`, `threads`, `game_actions`, `echo`.

local json = require('json')
local md = require('askmd')
local links = require('asklinks')
local view = require('askview')

local M = {}

-- State (one conversation on screen) ---------------------------------------------

local S
function M.reset()
  S = {
    shown = false,
    focus = false,          -- take focus on the next frame (tick hands it to the core once)
    focus_input = false,    -- the input box takes the keyboard on the next draw
    view = 'chat',          -- 'chat' | 'threads'
    thread = nil,           -- { id =, title = } of the conversation on screen; nil: the next question starts one
    messages = {},          -- { role = 'user'|'assistant'|'error', text =, tools = {}, streaming = bool }
    job = nil,              -- the command running: { id =, kind = 'ask'|'list'|'show', ... }
    threads = nil,          -- almanac's thread list (threads view), newest first
    draft = '',
    status = '',
    stick = true,           -- the conversation follows new text (scrolled to the end)
    dirty = false,
    now = 0,
    loaded = false,
    parents = {},           -- thread id -> { id =, title = } of the conversation it was branched from
    pending_parent = nil,   -- the parent of the thread the next answer starts
    note = nil,             -- what the last click did (shown for a few seconds)
    confirm = nil,          -- a slash command waiting for Run
  }
  M.state = S
end
M.reset()

local function cfg()
  local c = CONFIG and CONFIG.assistant
  if type(c) ~= 'table' then c = require('assistant') end
  return c
end

local function assistant() return require('assistant') end

local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end

local function list_copy(t)
  local out = {}
  if type(t) ~= 'table' then return out end
  for i = 1, #t do
    if type(t[i]) ~= 'string' or t[i] == '' then return {} end
    out[i] = t[i]
  end
  return out
end

-- Remembering the thread across /term reload and game restarts --------------------

local function state_path() return (GHOSTTY_PLUGIN_DIR or '.') .. '/ask-state.lua' end

local function save_thread()
  local f = io.open(state_path(), 'w')
  if not f then return end
  local parents, n = {}, 0
  for id, p in pairs(S.parents) do
    n = n + 1
    if n > 200 then break end
    parents[#parents + 1] = string.format('[%q] = { id = %q, title = %q }', id, p.id, p.title or '')
  end
  table.sort(parents)
  local ps = #parents > 0 and (', parents = { ' .. table.concat(parents, ', ') .. ' }') or ''
  if S.thread then
    f:write(string.format('return { thread = %q, title = %q%s }\n', S.thread.id, S.thread.title or '', ps))
  else
    f:write(string.format('return { %s }\n', (ps:gsub('^, ', ''))))
  end
  f:close()
end

local function load_thread()
  if S.loaded then return end
  S.loaded = true
  local chunk = loadfile(state_path(), 't', {})
  if not chunk then return end
  local ok, t = pcall(chunk)
  if ok and type(t) == 'table' and type(t.thread) == 'string' and t.thread ~= '' then
    S.thread = { id = t.thread, title = type(t.title) == 'string' and t.title or '' }
  end
  if ok and type(t) == 'table' and type(t.parents) == 'table' then
    for id, p in pairs(t.parents) do
      if type(id) == 'string' and type(p) == 'table' and type(p.id) == 'string' then
        S.parents[id] = { id = p.id, title = type(p.title) == 'string' and p.title or '' }
      end
    end
  end
end

-- Markdown, lightly ------------------------------------------------------------------
-- An answer as blocks: { kind = 'text' | 'code', text =, links = { { label =, url = } } }.
-- Fenced code blocks (```) are code (an unclosed fence runs to the end, as
-- while it streams); in text, **bold** and `code` lose their marks, headings
-- their #, list items get a bullet, and [label](https://...) links and bare
-- https:// links become clickable links under their block.

local function strip_url_tail(url)
  local tail = url:match('[%.,;:!%?%)%]\'"]+$')
  if tail then url = url:sub(1, #url - #tail) end
  return url
end

local function text_block(lines)
  local found, seen = {}, {}
  local function add(label, url)
    if url:match('^https://%S') and not seen[url] then
      seen[url] = true
      found[#found + 1] = { label = label, url = url }
    end
  end
  local out = {}
  for _, line in ipairs(lines) do
    line = line:gsub('^%s*#+%s+', '')
    line = line:gsub('^(%s*)[%-%*]%s+', '%1• ')
    line = line:gsub('%[([^%]]+)%]%((%S-)%)', function(label, url)
      add(label, url)
      return label
    end)
    for url in line:gmatch('https://[^%s<>"]+') do
      url = strip_url_tail(url)
      local short = url:gsub('^https://', '')
      if #short > 48 then short = short:sub(1, 47) .. '…' end
      add(short, url)
    end
    line = line:gsub('%*%*(.-)%*%*', '%1'):gsub('__(.-)__', '%1'):gsub('`([^`]+)`', '%1')
    out[#out + 1] = line
  end
  local text = trim(table.concat(out, '\n'))
  return { kind = 'text', text = text, links = found }
end

function M.blocks(answer)
  local blocks = {}
  if type(answer) ~= 'string' or answer == '' then return blocks end
  local text, code, in_code = {}, {}, false
  local function flush_text()
    if #text > 0 then
      local b = text_block(text)
      if b.text ~= '' or #b.links > 0 then blocks[#blocks + 1] = b end
      text = {}
    end
  end
  for line in (answer .. '\n'):gmatch('(.-)\r?\n') do
    if line:match('^%s*```') then
      if in_code then
        blocks[#blocks + 1] = { kind = 'code', text = table.concat(code, '\n'), links = {} }
        code, in_code = {}, false
      else
        flush_text()
        in_code = true
      end
    elseif in_code then
      code[#code + 1] = line
    else
      text[#text + 1] = line
    end
  end
  if in_code and #code > 0 then blocks[#blocks + 1] = { kind = 'code', text = table.concat(code, '\n'), links = {} } end
  flush_text()
  return blocks
end

-- The short form of an answer for the game's chat: its first paragraph of
-- text, on one line, cut to `limit` characters.
function M.short(answer, limit)
  limit = limit or 200
  for _, b in ipairs(M.blocks(answer)) do
    if b.kind == 'text' and b.text ~= '' then
      local para = b.text:match('^(.-)\n%s*\n') or b.text
      para = trim(para:gsub('%s+', ' '))
      if utf8.len(para) and utf8.len(para) > limit then
        para = para:sub(1, utf8.offset(para, limit) - 1) .. '…'
      end
      return para
    end
  end
  return ''
end

-- Running almanac --------------------------------------------------------------------

-- The argv of a question in thread `thread_id` (nil: a new thread).
function M.ask_argv(question, thread_id, c)
  c = c or cfg()
  local argv = list_copy(c.stream)
  if #argv == 0 then return nil, 'assistant.stream must be a list of words, e.g. { "almanac", "ask", "--stream-json" }' end
  if thread_id then
    argv[#argv + 1] = '--thread'
    argv[#argv + 1] = thread_id
  else
    argv[#argv + 1] = '--new-thread'
  end
  if c.game_actions then argv[#argv + 1] = '--allow-game-actions' end
  argv[#argv + 1] = '--'
  argv[#argv + 1] = question
  return argv
end

-- The argv of `almanac threads --json [show ID]`.
function M.threads_argv(show_id, c)
  c = c or cfg()
  local argv = list_copy(c.threads)
  if #argv == 0 then return nil, 'assistant.threads must be a list of words, e.g. { "almanac", "threads", "--json" }' end
  if show_id then
    argv[#argv + 1] = 'show'
    argv[#argv + 1] = show_id
  end
  return argv
end

local function spawn(argv, kind, extra)
  local spawn_fn = ghostty and ghostty.ask_spawn
  if not spawn_fn then return nil, 'this plugin build cannot run the assistant in a panel (/ask term works)' end
  local transport, fallback = assistant().transport_for(cfg().transport)
  local id, err = spawn_fn(argv, transport, fallback)
  if not id then return nil, err or 'could not start it' end
  local job = extra or {}
  job.id, job.kind, job.started = id, kind, S.now
  S.job = job
  return job
end

local function cancel_job()
  local job = S.job
  if not job then return end
  S.job = nil
  if ghostty and ghostty.ask_cancel then ghostty.ask_cancel(job.id) end
  if job.kind == 'ask' and job.reply and job.reply.streaming then
    job.reply.streaming = false
    job.reply.text = job.reply.text ~= '' and (job.reply.text .. '\n\n(stopped)') or '(stopped)'
    job.reply.stopped = true
  end
end

function M.busy() return S.job ~= nil and S.job.kind == 'ask' end

-- Stop the answer (or thread load) that is running.
function M.stop() cancel_job() end

-- Ask `question` in the thread on screen. False (and a status) while an
-- answer is still coming.
function M.send(question)
  question = assistant().clean(question or '')
  if question == '' then return false end
  if M.busy() then
    S.status = 'Still answering; Stop it or wait.'
    if S.draft == '' then S.draft = question end -- kept for when it is done
    return false
  end
  cancel_job() -- a thread list or a loading thread
  S.view = 'chat'
  local argv, err = M.ask_argv(question, S.thread and S.thread.id)
  S.messages[#S.messages + 1] = { role = 'user', text = question }
  local reply = { role = 'assistant', text = '', tools = {}, streaming = true }
  S.messages[#S.messages + 1] = reply
  S.stick, S.dirty = true, true
  if argv then
    local job
    job, err = spawn(argv, 'ask', { reply = reply, question = question })
    if job then
      S.status = ''
      return true
    end
  end
  reply.role, reply.text, reply.streaming = 'error', err, false
  return true
end

function M.new_thread()
  cancel_job()
  S.thread, S.messages, S.view, S.status = nil, {}, 'chat', ''
  S.confirm, S.pending_parent = nil, nil
  S.focus_input = true
  save_thread()
end

-- Ask `question` in a new thread that remembers this one as where it came from.
function M.branch(question)
  if M.busy() then
    S.status = 'Still answering; Stop it or wait.'
    return false
  end
  local parent = S.thread and { id = S.thread.id, title = S.thread.title or '' }
  M.new_thread()
  S.pending_parent = parent
  return M.send(question)
end

function M.refresh_threads()
  if M.busy() then return end
  cancel_job()
  local argv, err = M.threads_argv(nil)
  S.threads = nil
  if not argv then S.status = err return end
  local job
  job, err = spawn(argv, 'list', { list = {} })
  if not job then S.status = err end
end

function M.open_thread(id, title)
  if M.busy() then
    S.status = 'Still answering; Stop it or wait.'
    return
  end
  cancel_job()
  S.thread = { id = id, title = title or '' }
  S.messages, S.view, S.status = {}, 'chat', ''
  S.stick, S.dirty, S.focus_input = true, true, true
  save_thread()
  local argv, err = M.threads_argv(id)
  if not argv then S.status = err return end
  local job
  job, err = spawn(argv, 'show', {})
  if not job then S.status = err end
end

function M.show(focus)
  load_thread()
  if not S.shown then
    S.shown = true
    -- a thread from before a reload: bring its conversation back
    if S.thread and #S.messages == 0 and not S.job then M.open_thread(S.thread.id, S.thread.title) end
  end
  if focus then
    S.focus = true
    S.focus_input = true
  end
end

function M.hide() S.shown = false end

function M.pin()
  M.show(false)
  local pin = ghostty and ghostty.ask_pin
  if not pin then S.status = 'this plugin build cannot pin the panel' return false end
  local ok, err = pin()
  if not ok then S.status = 'Pin: ' .. tostring(err) end
  return ok
end

-- Output of the running command --------------------------------------------------------

local function echo_answer(answer)
  local c = cfg()
  if not c.echo or not (ghostty and ghostty.ask_echo) then return end
  local short = M.short(answer, tonumber(c.echo_chars) or 200)
  if short ~= '' then ghostty.ask_echo(short) end
end

local function on_ask_event(job, ev)
  local reply = job.reply
  if ev.type == 'thread' and type(ev.id) == 'string' then
    S.thread = { id = ev.id, title = type(ev.title) == 'string' and ev.title or '' }
    if S.pending_parent and S.pending_parent.id ~= ev.id then S.parents[ev.id] = S.pending_parent end
    S.pending_parent = nil
    save_thread()
  elseif ev.type == 'text' and type(ev.text) == 'string' then
    reply.text = reply.text .. ev.text
  elseif ev.type == 'tool' and type(ev.name) == 'string' then
    reply.tools[#reply.tools + 1] = { name = ev.name }
  elseif ev.type == 'result' and type(ev.name) == 'string' then
    local t = reply.tools[#reply.tools]
    if t and t.name == ev.name then t.lines = tonumber(ev.lines) end
  elseif ev.type == 'done' then
    job.done = true
    reply.streaming = false
    if type(ev.answer) == 'string' and ev.answer ~= '' then reply.text = ev.answer end
    if S.thread and type(ev.title) == 'string' and ev.title ~= '' and S.thread.title == '' then
      S.thread.title = ev.title
      save_thread()
    end
    echo_answer(reply.text)
  elseif ev.type == 'error' then
    job.done = true
    reply.streaming = false
    reply.role = 'error'
    reply.text = type(ev.message) == 'string' and ev.message or 'the assistant failed'
    if ev.code == 'guard' then reply.text = 'Not now: ' .. reply.text end
  end
end

local function on_show_event(ev)
  if ev.type == 'thread' and type(ev.id) == 'string' and S.thread and S.thread.id == ev.id then
    if type(ev.title) == 'string' then S.thread.title = ev.title end
  elseif ev.type == 'message' and (ev.role == 'user' or ev.role == 'assistant') and type(ev.text) == 'string' then
    local last = S.messages[#S.messages]
    if ev.role == 'assistant' and last and last.role == 'assistant' and last.text == '' then
      last.text = ev.text -- after its tool calls
    else
      S.messages[#S.messages + 1] = { role = ev.role, text = ev.text, tools = {} }
    end
  elseif ev.type == 'tool' and type(ev.name) == 'string' then
    local last = S.messages[#S.messages]
    if not last or last.role ~= 'assistant' then
      last = { role = 'assistant', text = '', tools = {} }
      S.messages[#S.messages + 1] = last
    end
    last.tools[#last.tools + 1] = { name = ev.name }
  elseif ev.type == 'error' then
    S.status = type(ev.message) == 'string' and ev.message or 'could not load the thread'
    if ev.code == 'thread' then -- gone: the next question starts a new one
      S.thread = nil
      save_thread()
    end
  end
end

function M.on_line(id, line)
  local job = S.job
  if not job or job.id ~= id or type(line) ~= 'string' then return end
  if line:sub(1, 1) ~= '{' then
    if line:match('%S') then job.noise = line:sub(1, 300) end -- a traceback, "command not found"...
    return
  end
  local ev = json.decode(line)
  if type(ev) ~= 'table' or type(ev.type) ~= 'string' then return end
  S.dirty = true
  if job.kind == 'ask' then
    on_ask_event(job, ev)
  elseif job.kind == 'list' then
    if ev.type == 'thread_info' and type(ev.id) == 'string' then
      job.list[#job.list + 1] = { id = ev.id, title = type(ev.title) == 'string' and ev.title or '',
        turns = tonumber(ev.turns) or 0, updated = tonumber(ev.updated) or 0 }
    elseif ev.type == 'end' then
      S.threads = job.list
    elseif ev.type == 'error' then
      S.status = type(ev.message) == 'string' and ev.message or 'could not list threads'
    end
  elseif job.kind == 'show' then
    on_show_event(ev)
  end
end

-- What the panel says when the assistant command was not there: worded for
-- the platform (lua/assistant.lua), or the text the configuration sets.
local function not_found()
  return assistant().not_found_text(cfg())
end

function M.on_exit(id, status, refused)
  local job = S.job
  if not job or job.id ~= id then return end
  S.job = nil
  S.dirty = true
  local missing = refused or status == 127
  if job.kind == 'ask' and not job.done then
    local reply = job.reply
    reply.streaming = false
    if missing then
      reply.role, reply.text = 'error', not_found()
    elseif reply.text == '' then
      reply.role = 'error'
      reply.text = string.format('The assistant ended without an answer (status %d).', status)
      if job.noise then reply.text = reply.text .. '\n' .. job.noise end
    else
      reply.text = reply.text .. string.format('\n\n(ended early, status %d)', status)
    end
  elseif job.kind == 'list' then
    if not S.threads then S.threads = job.list end
    if missing then S.status = not_found() end
  elseif job.kind == 'show' and missing then
    S.status = not_found()
  end
end

-- /ask ------------------------------------------------------------------------------------

-- CONFIG.ask.command(args) -> true when the panel took the line; false and
-- the question when the assistant terminal should (ui = 'terminal', the
-- assistant turned off, or /ask term ...).
function M.command(args)
  local c = cfg()
  args = type(args) == 'string' and args or ''
  if c.ui ~= 'panel' or not c.enabled then return false, args end
  local a = trim(assistant().clean(args))
  local word, rest = a:match('^(%S+)%s*(.-)$')
  word = word and word:lower() or ''
  if a == '' then
    if S.shown then M.hide() else M.show(true) end
  elseif word == 'term' or word == 'terminal' then
    return false, rest
  elseif word == 'new' then
    M.new_thread()
    M.show(true)
    if rest ~= '' then M.send(rest) end
  elseif a == 'threads' or a == 'history' then
    M.show(true)
    S.view = 'threads'
    M.refresh_threads()
  elseif a == 'close' or a == 'hide' then
    M.hide()
  elseif a == 'pin' then
    M.pin()
  else
    M.show(false)
    M.send(a)
  end
  return true
end

-- Per frame: whether the panel is up, and (once) whether it takes focus.
function M.tick(now)
  S.now = tonumber(now) or S.now
  local focus = S.focus and S.shown
  S.focus = false
  return S.shown, focus
end

-- Drawing (ghostty.ui) --------------------------------------------------------------------
-- An answer is drawn rich (lua/askmd.lua, lua/asklinks.lua, lua/askview.lua):
-- parsed and linked once per change of its text, laid out once per width,
-- drawn with draw-list primitives only. A core without those primitives (or a
-- message whose rich drawing fails) gets the plain bubbles of before.

local function tip(key)
  local ui = ghostty.ui
  local T = CONFIG and CONFIG.tooltips
  if ui.tip and type(T) == 'table' and T[key] then ui.tip(T[key]) end
end

local function open_link(url)
  local open = ghostty and ghostty.open_url
  if not open then S.status = 'this plugin build cannot open links' return end
  local ok, err = open(url)
  if not ok then S.status = 'Link: ' .. tostring(err) end
end

-- A short line under the conversation for what a click did; it fades after a while.
local function note(text)
  if text and text ~= '' then S.note, S.note_at = text, S.now end
end

local function rich_ui(ui)
  return ui.measure and ui.text_at and ui.rect_at and ui.frame_at and ui.line_at and ui.origin and ui.advance
    and ui.mouse and ui.font_size
end

local measure, measure_ui
local function measurer(ui)
  if measure_ui ~= ui then measure, measure_ui = view.measurer(ui), ui end
  return measure
end

-- The document of message `m`, parsed and linked again only when its text
-- changed (or the game was still indexing its names last time).
local function prepare(m)
  local now = S.now or 0
  if m.doc_src ~= m.text or (m.unlinked and now >= links.resolver.retry_at) then
    m.doc = md.parse(m.text)
    m.unlinked = not links.link(m.doc, now)
    m.doc_src = m.text
    m.lay = nil
    m.sources = nil
    m.followups = nil
  end
  if not m.streaming and not m.sources then
    m.sources = links.sources(m.doc)
    m.followups = links.followups(m.doc)
  end
  return m.doc
end

local FADE = 0.35

-- The alpha of text ending at character `cum` of a message still streaming in.
local function fader(m, now)
  local f = m.fade
  if not f or #f == 0 or now - f[#f].t > FADE then return nil end
  return function(cum)
    for i = #f, 1, -1 do
      local s = f[i]
      if now - s.t > FADE then return 1 end
      if cum > (f[i - 1] and f[i - 1].upto or 0) and cum <= s.upto then
        return math.max(0.15, math.min(1, (now - s.t) / FADE))
      end
    end
    return 1
  end
end

local function describe_tip(ui, l)
  local title, body, hint = links.describe(l)
  if ui.tip_rich then
    ui.tip_rich(title or '', body or '', hint or '', l.icon or 0)
  elseif ui.tip then
    ui.tip(table.concat({ title or '', body or '', hint or '' }, '\n'):gsub('\n+', '\n'):gsub('^\n', ''), nil, true)
  end
end

-- One answer, rich. Returns the link under the pointer, if any.
local function draw_rich(ui, m, frame, extra_followups)
  prepare(m)
  local x, y, w, c0, c1 = ui.origin()
  local pad = 11
  local inner = math.max(w - 2 * pad, 40)
  local fs = ui.font_size()
  local fups = extra_followups and m.followups or nil
  local key = string.format('%d:%.1f:%d:%s', math.floor(inner), fs, fups and #fups or 0, m.sources and #m.sources or '-')
  if not m.lay or m.lay_key ~= key then
    m.lay = view.layout(m.doc, inner, fs, measurer(ui), {
      icons = ui.icons and ui.icons() or false,
      sources = m.sources,
      followups = fups,
    })
    m.lay_key = key
    if m.streaming then
      m.fade = m.fade or {}
      local last = m.fade[#m.fade]
      if m.lay.chars > (last and last.upto or 0) then m.fade[#m.fade + 1] = { upto = m.lay.chars, t = S.now or 0 } end
    end
  end
  local L = m.lay
  local h = L.h + 2 * pad
  local hot
  if y + h >= c0 and y <= c1 then
    if frame.hovered then hot = view.hit(L, x + pad, y + pad, frame.mx, frame.my) end
    ui.rect_at(x, y, x + w, y + h, view.C.glass_top, 225, 10)
    ui.frame_at(x, y, x + w, y + h, view.C.accent2, 55, 10)
    view.draw(ui, L, x + pad, y + pad, {
      clip0 = c0, clip1 = c1, hot = hot or frame.hot, fade = fader(m, S.now or 0),
      icon = ui.icon_at and function(id, x0, y0, x1, y1) return ui.icon_at(id, x0, y0, x1, y1) end,
      copied = S.copied_at and (S.now or 0) - S.copied_at < 2 and S.copied or nil,
    })
  end
  ui.advance(h)
  return hot
end

local function draw_tools(ui, m)
  for _, t in ipairs(m.tools or {}) do
    ui.bubble('\u{2192} ' .. t.name .. (t.lines and string.format('  (%d lines)', t.lines) or ''), 'note')
  end
end

-- The plain answer of before: text bubbles, code blocks, links under them.
local function draw_plain(ui, m)
  local blocks = M.blocks(m.text)
  for _, b in ipairs(blocks) do
    if b.kind == 'code' then
      ui.bubble(b.text ~= '' and b.text or ' ', 'code')
    elseif b.text ~= '' then
      ui.bubble(b.text, 'assistant')
    end
    for i, l in ipairs(b.links) do
      if i > 1 then ui.same_line() end
      if ui.link('\u{2197} ' .. l.label, l.url) then open_link(l.url) end
    end
  end
  return #blocks
end

local function draw_reply(ui, m, frame, last)
  draw_tools(ui, m)
  local shown = m.text ~= ''
  if shown then
    if frame.rich and not m.rich_error then
      local ok, hot = pcall(draw_rich, ui, m, frame, last)
      if ok then
        if hot and not frame.hot then frame.hot, frame.hot_msg = hot, m end
      else
        -- never again for this message: the plain bubbles instead, and say why once
        m.rich_error = tostring(hot)
        S.status = 'This answer is shown plain: ' .. m.rich_error:sub(1, 160)
        draw_plain(ui, m)
      end
    else
      draw_plain(ui, m)
    end
  end
  if m.streaming then
    local dots = string.rep('.', 1 + math.floor((S.now or 0) * 3) % 3)
    ui.bubble(not shown and ('thinking' .. dots) or dots, 'note')
  end
end

-- What a click on link `l` does (lua/asklinks.lua), with the panel's side of it.
local function click(ui, l, right)
  if l.kind == 'copy' then
    if ui.copy then ui.copy(l.text) end
    S.copied, S.copied_at = l.text, S.now
    return
  end
  local said = links.activate(l, {
    open_url = function(url) open_link(url) return nil end,
    copy = ui.copy,
    open_thread = function(id) M.open_thread(id, '') end,
    ask = function(q, new_thread)
      if new_thread then M.branch(q) else M.send(q) end
    end,
    confirm = function(cmd) S.confirm = cmd end,
  }, right and 'right' or 'left')
  note(said)
end

local INPUT_H = 64

local function draw_confirm(ui)
  local cmd = S.confirm
  if not cmd then return 0 end
  ui.bubble('Run ' .. cmd .. ' now?', 'note')
  if ui.small_button('Run##ask_run') then
    local ok, err = links.run_command(cmd)
    note(ok and ('Ran ' .. cmd) or ('Not run: ' .. tostring(err)))
    S.confirm = nil
  end
  tip('ask.run')
  ui.same_line()
  if ui.small_button('Cancel##ask_run_cancel') then S.confirm = nil end
  return 1
end

local function draw_chat(ui)
  local extra = 0
  if S.confirm then extra = extra + 30 end
  local show_note = S.note and (S.now or 0) - (S.note_at or 0) < 6
  if show_note then extra = extra + 22 end
  local visible = ui.child('##ask_log', INPUT_H + 44 + extra)
  local follow = S.stick and S.dirty
  local frame = { rich = rich_ui(ui) and true or false }
  if visible then
    if frame.rich then
      frame.mx, frame.my, frame.hovered, frame.clicked, frame.right = ui.mouse()
    end
    if #S.messages == 0 then
      ui.bubble(S.job and 'loading the conversation...' or
        'Ask anything: the knowledge base, your machines, the game. Follow-ups keep the conversation.', 'note')
    end
    local last_assistant
    for i = #S.messages, 1, -1 do
      if S.messages[i].role == 'assistant' then last_assistant = S.messages[i] break end
    end
    for _, m in ipairs(S.messages) do
      if m.role == 'user' then
        ui.bubble(m.text, 'user')
      elseif m.role == 'error' then
        ui.bubble(m.text, 'error')
      else
        draw_reply(ui, m, frame, m == last_assistant and not M.busy())
      end
      ui.spacing()
    end
    local hot = frame.hot
    if hot then
      if ui.hand then ui.hand() end
      describe_tip(ui, hot)
      if frame.clicked or frame.right then click(ui, hot, frame.right) end
    end
    S.stick = ui.at_bottom() or follow
  end
  ui.end_child(follow)
  S.dirty = false
  if show_note then ui.bubble(S.note, 'note') end
  draw_confirm(ui)
  -- the input box
  if S.focus_input then
    ui.focus_next()
    S.focus_input = false
  end
  local changed, text, entered, shift = ui.input_multiline('##ask_input', S.draft, INPUT_H)
  if changed then S.draft = text end
  if entered then
    if shift then
      S.draft = text .. '\n'
    elseif trim(text) ~= '' and M.send(text) then
      S.draft = ''
    end
    S.focus_input = true
  end
  if M.busy() then
    if ui.small_button('Stop##ask_stop') then M.stop() end
    tip('ask.stop')
    ui.same_line()
  elseif ui.small_button('Send##ask_send') and trim(S.draft) ~= '' then
    if M.send(S.draft) then S.draft = '' end
    S.focus_input = true
  end
  if not M.busy() then tip('ask.send') ui.same_line() end
  ui.bubble('Enter sends \u{b7} Shift+Enter new line \u{b7} Esc closes', 'note')
end

local function draw_threads(ui)
  local visible = ui.child('##ask_threads', 8)
  if visible then
    if not S.threads then
      ui.bubble(S.job and 'loading threads...' or 'no threads yet', 'note')
    elseif #S.threads == 0 then
      ui.bubble('No threads yet: ask something.', 'note')
    else
      for _, t in ipairs(S.threads) do
        local from = S.parents[t.id]
        local label = (t.title ~= '' and t.title or t.id) .. string.format('   \u{b7} %d', t.turns)
          .. (from and ('   \u{b7} from ' .. (from.title ~= '' and from.title or from.id)) or '') .. '##' .. t.id
        if ui.selectable(label, S.thread ~= nil and S.thread.id == t.id) then M.open_thread(t.id, t.title) end
      end
    end
  end
  ui.end_child(false)
end

-- The newest answer on screen, as written (for Copy).
local function last_answer()
  for i = #S.messages, 1, -1 do
    local m = S.messages[i]
    if m.role == 'assistant' and m.text ~= '' then return m.text end
  end
end

function M.draw()
  local ui = ghostty and ghostty.ui
  if not ui then return end
  -- Esc closes (while the panel has the keyboard), before the input box sees it
  if ui.focused() and ui.key_pressed('escape') then
    M.hide()
    return
  end
  local title = S.thread and S.thread.title ~= '' and S.thread.title or (S.thread and 'Ask' or 'Ask \u{b7} new thread')
  ui.text(title)
  -- the conversation this one was branched from
  local from = S.thread and S.parents[S.thread.id]
  if from and ui.link then
    if ui.link('from: ' .. (from.title ~= '' and from.title or from.id), 'thread ' .. from.id) then M.open_thread(from.id, from.title) end
  end
  if ui.small_button('New##ask_new') then M.new_thread() end
  tip('ask.new')
  ui.same_line()
  if S.view == 'threads' then
    if ui.small_button('Chat##ask_chat') then S.view = 'chat' end
    tip('ask.chat')
  elseif ui.small_button('Threads##ask_threads') then
    S.view = 'threads'
    M.refresh_threads()
  end
  if S.view ~= 'threads' then tip('ask.threads') end
  ui.same_line()
  local answer = last_answer()
  if answer and ui.copy then
    if ui.small_button('Copy##ask_copy') then
      ui.copy(answer)
      note('The last answer is on the clipboard')
    end
    tip('ask.copy')
    ui.same_line()
  end
  if ui.small_button('Pin##ask_pin') then M.pin() end
  tip('ask.pin')
  ui.same_line()
  local c = cfg()
  local changed, v = ui.checkbox('Game actions##ask_actions', c.game_actions == true)
  if changed then c.game_actions = v end
  tip('ask.game_actions')
  ui.same_line()
  if ui.small_button('Close##ask_close') then M.hide() end
  tip('ask.close')
  if S.status ~= '' then ui.wrapped(S.status, 0.94, 0.62, 0.52) end
  ui.separator()
  if S.view == 'threads' then draw_threads(ui) else draw_chat(ui) end
end

return M
