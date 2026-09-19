-- lua/ask.lua (run by tests/test_ask.nelua): /ask parsing, the argv of a
-- question (one element, in a thread or a new one), almanac's JSON lines
-- turning into chat bubbles as they stream, follow-ups, Stop, failures,
-- the thread list and history, the light markdown, the echo line, and the
-- panel drawn through a scripted ghostty.ui (the fake ImGui of these tests).
local ROOT, SCRATCH = ...
package.path = ROOT .. '/lua/?.lua;' .. package.path
GHOSTTY_PLUGIN_DIR = SCRATCH
os.remove(SCRATCH .. '/ask-state.lua')

local json = require('json')

local spawned, cancelled, echoed, opened, pins = {}, {}, {}, {}, 0
local next_id = 0
local spawn_error = nil
ghostty = {
  ask_spawn = function(argv, transport, fallback)
    if spawn_error then return nil, spawn_error end
    next_id = next_id + 1
    spawned[#spawned + 1] = { id = next_id, argv = argv, transport = transport, fallback = fallback }
    return next_id
  end,
  ask_cancel = function(id) cancelled[#cancelled + 1] = id return true end,
  ask_echo = function(text) echoed[#echoed + 1] = text return true end,
  ask_pin = function() pins = pins + 1 return true end,
  open_url = function(url) opened[#opened + 1] = url return true end,
}

-- a scripted ghostty.ui: `press` names the labels clicked this frame, `input`
-- what the input box returns, `esc` an Escape press
local press, drawn, input, esc, focused = {}, {}, nil, false, true
local function rec(kind, text, extra) drawn[#drawn + 1] = { kind = kind, text = text, extra = extra } end
ghostty.ui = {
  text = function(t) rec('text', t) end,
  wrapped = function(t) rec('wrapped', t) end,
  separator = function() end,
  spacing = function() end,
  same_line = function() end,
  tip = function(t) rec('tip', t) end,
  small_button = function(label) rec('button', label) return press[label] == true end,
  checkbox = function(label, v) rec('checkbox', label) if press[label] then return true, not v end return false, v end,
  selectable = function(label, sel) rec('selectable', label, sel) return press[label] == true end,
  bubble = function(text, role) rec('bubble', text, role) end,
  link = function(label, url) rec('link', label, url) return press[url] == true end,
  child = function(id, reserve) rec('child', id) return true end,
  end_child = function(follow) rec('end_child', nil, follow) end,
  at_bottom = function() return true end,
  focus_next = function() rec('focus_next') end,
  focused = function() return focused end,
  key_pressed = function(name) return name == 'escape' and esc end,
  input_multiline = function(label, text, h)
    rec('input', text)
    if input then return true, input.text, input.entered == true, input.shift == true end
    return false, text, false, false
  end,
}

CONFIG = { assistant = require('assistant'), tooltips = require('tooltips') }
local A = CONFIG.assistant
local M = require('ask')
CONFIG.ask = M
local S = function() return M.state end

local function frame(opts)
  opts = opts or {}
  press, drawn, input, esc = {}, {}, opts.input, opts.esc == true
  for _, c in ipairs(opts.press or {}) do press[c] = true end
  M.tick(opts.now or 1)
  M.draw()
  return drawn
end
local function find(list, kind, pred)
  for _, d in ipairs(list) do
    if d.kind == kind and (not pred or pred(d)) then return d end
  end
end
local function bubbles(list, role)
  local out = {}
  for _, d in ipairs(list) do if d.kind == 'bubble' and (not role or d.extra == role) then out[#out + 1] = d.text end end
  return out
end
local function line(t) return json.encode(t) end
local function argv_str(a) return table.concat(a, '\x1f') end
local function last() return spawned[#spawned] end

-- defaults: the panel, almanac with JSON lines, no game actions, no echo
assert(A.ui == 'panel' and A.game_actions == false and A.echo == false)
assert(argv_str(A.stream) == 'almanac\x1fask\x1f--stream-json' and argv_str(A.threads) == 'almanac\x1fthreads\x1f--json')

-- the argv: the question is one element after '--', in a thread or a new one
do
  local q = '-v "quoted"; $(rm -rf ~) naïve 日本語'
  assert(argv_str(M.ask_argv(q, nil)) == 'almanac\x1fask\x1f--stream-json\x1f--new-thread\x1f--\x1f' .. q)
  assert(argv_str(M.ask_argv(q, 't1')) == 'almanac\x1fask\x1f--stream-json\x1f--thread\x1ft1\x1f--\x1f' .. q)
  local c = { stream = { 'x' }, game_actions = true }
  assert(argv_str(M.ask_argv('q', 'id', c)) == 'x\x1f--thread\x1fid\x1f--allow-game-actions\x1f--\x1fq')
  assert(M.ask_argv('q', nil, { stream = 'almanac ask' }) == nil, 'not a list: refused')
  assert(argv_str(M.threads_argv('abc')) == 'almanac\x1fthreads\x1f--json\x1fshow\x1fabc')
end

-- the light markdown
do
  local b = M.blocks('# Title\nSee **this** and `that`:\n- one\n* two\nMore at [the docs](https://example.org/docs), '
    .. 'https://example.org/a.b). Not http://plain.example.\n```lua\nlocal x = 1\n```\nAfter.\n```\nopen')
  assert(#b == 4, #b)
  assert(b[1].kind == 'text' and b[1].text:find('^Title\nSee this and that:\n• one\n• two\nMore at the docs,'), b[1].text)
  assert(#b[1].links == 2 and b[1].links[1].url == 'https://example.org/docs' and b[1].links[1].label == 'the docs')
  assert(b[1].links[2].url == 'https://example.org/a.b', 'trailing punctuation dropped: ' .. b[1].links[2].url)
  assert(b[2].kind == 'code' and b[2].text == 'local x = 1')
  assert(b[3].kind == 'text' and b[3].text == 'After.')
  assert(b[4].kind == 'code' and b[4].text == 'open', 'an unclosed fence (still streaming) is code')
  assert(#M.blocks('') == 0 and #M.blocks(nil) == 0)
  assert(M.short('First line\ngoes on.\n\nSecond para.') == 'First line goes on.')
  assert(M.short('```\ncode\n```\nText after code') == 'Text after code')
  local long = M.short(string.rep('é', 300), 10)
  assert(utf8.len(long) == 10 and long:sub(-3) == '…', long)
end

-- /ask alone shows the panel (and takes focus once), again hides it
assert(M.command('') == true and S().shown)
local shown, focus = M.tick(0)
assert(shown and focus)
shown, focus = M.tick(0)
assert(shown and not focus, 'focus only once')
assert(M.command('   ') == true and not S().shown)

-- a question: shown (without stealing the keyboard), a new thread, streamed
assert(M.command('which retainers are full?') == true)
assert(S().shown and #spawned == 1)
assert(argv_str(last().argv) == 'almanac\x1fask\x1f--stream-json\x1f--new-thread\x1f--\x1fwhich retainers are full?')
assert(last().transport == 'agent' or last().transport == 'conpty')
local job = last().id
assert(M.busy())
M.on_line(job, 'Traceback (most recent call last):') -- not JSON: ignored
M.on_line(job, '{"type": "note", "text": "xivmcp: connected"}')
M.on_line(job, line({ type = 'thread', id = 'T1', title = '', new = true, turns = 0 }))
assert(S().thread.id == 'T1')
M.on_line(job, line({ type = 'tool', name = 'xivmcp__get_retainers', args = {} }))
M.on_line(job, line({ type = 'result', name = 'xivmcp__get_retainers', summary = 'ok', lines = 12 }))
M.on_line(job, line({ type = 'text', text = 'Two are ' }))
M.on_line(job, '{not json')
M.on_line(job + 99, line({ type = 'text', text = 'other job' })) -- not ours
M.on_line(job, line({ type = 'text', text = 'full: ' }))
local d = frame({ now = 2 })
local assist = bubbles(d, 'assistant')
assert(#assist == 1 and assist[1] == 'Two are full:', assist[1])
assert(bubbles(d, 'user')[1] == 'which retainers are full?')
local notes = table.concat(bubbles(d, 'note'), '|')
assert(notes:find('xivmcp__get_retainers  (12 lines)', 1, true), notes)
assert(#bubbles(d, 'note') == 3, 'the tool, the streaming dots and the key hint: ' .. notes)
assert(find(d, 'button', function(x) return x.text == 'Stop##ask_stop' end), 'Stop while answering')
assert(find(d, 'end_child', function(x) return x.extra == true end), 'follows new text')
M.on_line(job, line({ type = 'done', answer = 'Two are full: Alpha and Beta. See https://example.org/retainers.', thread = 'T1', title = 'which retainers are full?' }))
assert(not M.busy() or S().job ~= nil)
M.on_exit(job, 0, false)
assert(not M.busy() and S().thread.title == 'which retainers are full?')
d = frame()
assert(bubbles(d, 'assistant')[1] == 'Two are full: Alpha and Beta. See https://example.org/retainers.')
assert(find(d, 'link', function(x) return x.extra == 'https://example.org/retainers' end))
assert(#echoed == 0, 'echo is off by default')
-- the link opens in the browser
frame({ press = { 'https://example.org/retainers' } })
assert(opened[1] == 'https://example.org/retainers')
-- the thread is remembered for a reload
do
  local f = assert(io.open(SCRATCH .. '/ask-state.lua'))
  local s = f:read('a')
  f:close()
  assert(s:find('T1', 1, true), s)
end

-- a follow-up goes into the same thread; echo when turned on
A.echo = true
assert(M.command('and the third?'))
job = last().id
assert(argv_str(last().argv) == 'almanac\x1fask\x1f--stream-json\x1f--thread\x1fT1\x1f--\x1fand the third?')
-- while it answers, another question waits in the input box
assert(M.command('one more') and #spawned == 2 and S().draft == 'one more' and S().status:find('Still answering'))
M.on_line(job, line({ type = 'done', answer = 'The third has room.\n\nDetails follow.', thread = 'T1', title = 'x' }))
M.on_exit(job, 0, false)
assert(echoed[1] == 'The third has room.' and S().thread.title == 'which retainers are full?')
A.echo = false

-- Enter in the input box sends; Shift+Enter adds a line; Esc closes
S().draft = ''
d = frame({ input = { text = 'line one', entered = true, shift = true } })
assert(S().draft == 'line one\n' and #spawned == 2, 'Shift+Enter: a new line, nothing sent')
d = frame({ input = { text = 'line one\nline two', entered = true } })
assert(#spawned == 3 and S().draft == '' and argv_str(last().argv):find('line one\nline two', 1, true))
assert(S().focus_input, 'the input keeps the keyboard')
d = frame()
assert(find(d, 'focus_next'))
-- Stop: the job is cancelled and the bubble says so
job = last().id
M.on_line(job, line({ type = 'text', text = 'Partial' }))
frame({ press = { 'Stop##ask_stop' } })
assert(cancelled[#cancelled] == job and not M.busy())
local msgs = S().messages
assert(msgs[#msgs].text == 'Partial\n\n(stopped)')
M.on_line(job, line({ type = 'text', text = 'late' })) -- after the stop: ignored
assert(msgs[#msgs].text == 'Partial\n\n(stopped)')
-- Esc while the panel has focus hides it; not while the game has the keyboard
focused = false
frame({ esc = true })
assert(S().shown)
focused = true
frame({ esc = true })
assert(not S().shown)

-- failures: the command is missing (refused, or 127), memory is tight, a crash
M.command('q1')
M.on_exit(last().id, 0, true)
assert(msgs[#msgs].role == 'error' and msgs[#msgs].text:find('not found', 1, true))
M.command('q2')
M.on_exit(last().id, 127, false)
assert(msgs[#msgs].role == 'error' and msgs[#msgs].text:find('not found', 1, true))
M.command('q3')
M.on_line(last().id, line({ type = 'error', message = 'not running: memory is tight', code = 'guard' }))
M.on_exit(last().id, 75, false)
assert(msgs[#msgs].role == 'error' and msgs[#msgs].text == 'Not now: not running: memory is tight')
M.command('q4')
M.on_line(last().id, 'ModuleNotFoundError: No module named almanac')
M.on_exit(last().id, 1, false)
assert(msgs[#msgs].text:find('without an answer (status 1)', 1, true) and msgs[#msgs].text:find('ModuleNotFoundError', 1, true))
M.command('q5')
M.on_line(last().id, line({ type = 'text', text = 'half' }))
M.on_exit(last().id, 9, false)
assert(msgs[#msgs].role == 'assistant' and msgs[#msgs].text == 'half\n\n(ended early, status 9)')
spawn_error = 'could not start it (no agent configured?)'
M.command('q6')
assert(msgs[#msgs].role == 'error' and msgs[#msgs].text == spawn_error and not M.busy())
spawn_error = nil
d = frame()
assert(#bubbles(d, 'error') >= 5)

-- /ask new [question]: a new thread
assert(M.command('new what now?'))
assert(S().thread == nil or S().thread.id ~= 'T1')
assert(argv_str(last().argv):find('--new-thread', 1, true) and #S().messages == 2)
M.on_line(last().id, line({ type = 'thread', id = 'T2', title = '', new = true }))
M.on_exit(last().id, 0, false)
assert(S().thread.id == 'T2')

-- /ask threads: the list, then one thread's history
assert(M.command('threads') and S().view == 'threads')
assert(argv_str(last().argv) == 'almanac\x1fthreads\x1f--json')
job = last().id
d = frame()
assert(bubbles(d, 'note')[1] == 'loading threads...')
M.on_line(job, line({ type = 'thread_info', id = 'T2', title = 'what now?', turns = 1, updated = 2 }))
M.on_line(job, line({ type = 'thread_info', id = 'T1', title = 'which retainers are full?', turns = 3, updated = 1 }))
M.on_line(job, line({ type = 'end' }))
M.on_exit(job, 0, false)
assert(#S().threads == 2)
local label = 'which retainers are full?   \u{b7} 3##T1'
d = frame()
assert(find(d, 'selectable', function(x) return x.text == label end))
frame({ press = { label } })
assert(S().view == 'chat' and S().thread.id == 'T1' and #S().messages == 0)
assert(argv_str(last().argv) == 'almanac\x1fthreads\x1f--json\x1fshow\x1fT1')
job = last().id
M.on_line(job, line({ type = 'thread', id = 'T1', title = 'which retainers are full?', new = false, turns = 2 }))
M.on_line(job, line({ type = 'message', role = 'user', text = 'which retainers are full?' }))
M.on_line(job, line({ type = 'tool', name = 'xivmcp__get_retainers', args = {} }))
M.on_line(job, line({ type = 'message', role = 'assistant', text = 'Two.' }))
M.on_line(job, line({ type = 'message', role = 'user', text = 'and the third?' }))
M.on_line(job, line({ type = 'message', role = 'assistant', text = 'Room.' }))
M.on_line(job, line({ type = 'end' }))
M.on_exit(job, 0, false)
msgs = S().messages
assert(#msgs == 4 and msgs[2].text == 'Two.' and msgs[2].tools[1].name == 'xivmcp__get_retainers' and msgs[4].text == 'Room.')
-- a thread that is gone: the next question starts a new one
M.open_thread('gone', '')
M.on_line(last().id, line({ type = 'error', message = 'no thread gone', code = 'thread' }))
M.on_exit(last().id, 2, false)
assert(S().thread == nil and S().status == 'no thread gone')

-- after a reload: the remembered thread comes back when the panel opens
M.open_thread('T1', 'which retainers are full?')
M.on_exit(last().id, 0, false)
package.loaded.ask = nil
M = require('ask')
CONFIG.ask = M
local before = #spawned
M.command('')
assert(S().thread and S().thread.id == 'T1' and #spawned == before + 1)
assert(argv_str(last().argv) == 'almanac\x1fthreads\x1f--json\x1fshow\x1fT1')
M.on_exit(last().id, 0, false)

-- the header: new, threads, pin, game actions, close
d = frame()
for _, l in ipairs({ 'New##ask_new', 'Threads##ask_threads', 'Pin##ask_pin', 'Close##ask_close' }) do
  assert(find(d, 'button', function(x) return x.text == l end), l)
end
assert(find(d, 'tip', function(x) return x.text == CONFIG.tooltips['ask.pin'] end), 'tooltips from lua/tooltips.lua')
frame({ press = { 'Game actions##ask_actions' } })
assert(A.game_actions == true)
M.command('act')
assert(argv_str(last().argv):find('--allow-game-actions', 1, true))
M.on_exit(last().id, 0, false)
A.game_actions = false
frame({ press = { 'Pin##ask_pin' } })
assert(pins == 1)
ghostty.ask_pin = function() return false, 'no player (log in first)' end
assert(M.command('pin') and S().status == 'Pin: no player (log in first)')
frame({ press = { 'New##ask_new' } })
assert(S().thread == nil and #S().messages == 0)
frame({ press = { 'Close##ask_close' } })
assert(not S().shown)

-- the terminal: /ask term, ui = 'terminal', or the assistant off
local ok, q = M.command('term what is up')
assert(ok == false and q == 'what is up')
A.ui = 'terminal'
ok, q = M.command('hello')
assert(ok == false and q == 'hello')
A.ui = 'panel'
A.enabled = false
assert(M.command('hello') == false)
A.enabled = true

-- an old plugin build without ask_spawn: the reason in a bubble
ghostty.ask_spawn = nil
M.command('x')
msgs = S().messages
assert(msgs[#msgs].role == 'error' and msgs[#msgs].text:find('/ask term', 1, true))

os.remove(SCRATCH .. '/ask-state.lua')
print('test_ask.lua OK')
