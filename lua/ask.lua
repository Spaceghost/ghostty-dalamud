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
-- Esc closes. Links (https only) open in your browser. Game actions stay off
-- unless you tick them, and XivMcp still asks you in game before each one.
--
-- What runs and how is configured in lua/assistant.lua (CONFIG.assistant):
-- `ui` ('panel' | 'terminal'), `stream`, `threads`, `game_actions`, `echo`.

local json = require('json')

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
  if S.thread then
    f:write(string.format('return { thread = %q, title = %q }\n', S.thread.id, S.thread.title or ''))
  else
    f:write('return {}\n')
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
  local links, seen = {}, {}
  local function add(label, url)
    if url:match('^https://%S') and not seen[url] then
      seen[url] = true
      links[#links + 1] = { label = label, url = url }
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
  return { kind = 'text', text = text, links = links }
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
  S.focus_input = true
  save_thread()
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

local function not_found()
  return tostring(cfg().not_found or assistant().not_found)
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

local function draw_reply(ui, m)
  for _, t in ipairs(m.tools or {}) do
    ui.bubble('\u{2192} ' .. t.name .. (t.lines and string.format('  (%d lines)', t.lines) or ''), 'note')
  end
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
  if m.streaming then
    local dots = string.rep('.', 1 + math.floor((S.now or 0) * 3) % 3)
    ui.bubble(#blocks == 0 and ('thinking' .. dots) or dots, 'note')
  end
end

local INPUT_H = 64

local function draw_chat(ui)
  local visible = ui.child('##ask_log', INPUT_H + 44)
  local follow = S.stick and S.dirty
  if visible then
    if #S.messages == 0 then
      ui.bubble(S.job and 'loading the conversation...' or
        'Ask anything: the knowledge base, your machines, the game. Follow-ups keep the conversation.', 'note')
    end
    for _, m in ipairs(S.messages) do
      if m.role == 'user' then
        ui.bubble(m.text, 'user')
      elseif m.role == 'error' then
        ui.bubble(m.text, 'error')
      else
        draw_reply(ui, m)
      end
      ui.spacing()
    end
    S.stick = ui.at_bottom() or follow
  end
  ui.end_child(follow)
  S.dirty = false
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
        local label = (t.title ~= '' and t.title or t.id) .. string.format('   \u{b7} %d', t.turns) .. '##' .. t.id
        if ui.selectable(label, S.thread ~= nil and S.thread.id == t.id) then M.open_thread(t.id, t.title) end
      end
    end
  end
  ui.end_child(false)
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
