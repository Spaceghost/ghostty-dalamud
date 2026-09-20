-- lua/assistant.lua (run by tests/test_assistant.nelua): the argv for a
-- question (one element, whatever it holds), chat without one, the view and
-- transport choices, the off switch and the exit / not-found text.
local ROOT = ...
package.path = ROOT .. '/lua/?.lua;' .. package.path
local A = require('assistant')

local function same(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end
local function show(t) return '{' .. table.concat(t, '|') .. '}' end

-- defaults: almanac, as a pet, on
assert(A.enabled == true and A.view == 'pet' and A.transport == 'default')
assert(same(A.chat, { 'almanac', 'chat' }) and same(A.ask, { 'almanac', 'ask', '--' }))

-- a question is exactly one argv element, nothing interpreted
local questions = {
  "what's my next MSQ step?",
  'say "hi"; rm -rf ~ && echo $(whoami) `id` | tee x > y',
  '-- --help -v',
  'naïve café ✓ 日本語 🐉',
  "a\\b 'c' \"d\" $HOME %APPDATA% ^&",
  'multiple   inner   spaces',
}
for _, q in ipairs(questions) do
  local argv = A.argv(q)
  assert(same(argv, { 'almanac', 'ask', '--', q }), 'argv for ' .. q .. ': ' .. show(argv))
end
-- only surrounding blanks go
assert(same(A.argv('  padded question \t'), { 'almanac', 'ask', '--', 'padded question' }))

-- nothing to ask: the interactive session
for _, q in ipairs({ '', '   ', '\t', nil }) do
  assert(same(A.argv(q), { 'almanac', 'chat' }), 'chat for ' .. tostring(q))
end

-- the returned argv is a copy: changing it leaves the config alone
do
  local argv = A.argv('x')
  argv[1] = 'changed'
  assert(A.ask[1] == 'almanac' and #A.ask == 3)
  local c = A.argv('')
  c[#c + 1] = 'extra'
  assert(#A.chat == 2)
end

-- the chat line is cut at a byte limit: an incomplete UTF-8 tail goes
do
  local dragon = '🐉' -- 4 bytes
  for cut = 1, 3 do
    local q = 'ask ' .. dragon:sub(1, cut)
    assert(A.clean(q) == 'ask', 'cut after ' .. cut .. ' bytes')
  end
  assert(A.clean('ok ' .. dragon) == 'ok ' .. dragon)
  -- invalid in the middle is not ours to fix
  local odd = 'a\xffb'
  assert(A.clean(odd) == odd)
end

-- a custom command
do
  local cfg = { enabled = true, chat = { 'my-ai' }, ask = { 'my-ai', '-q' }, view = 'tab' }
  assert(same(A.argv('why?', cfg), { 'my-ai', '-q', 'why?' }))
  assert(same(A.argv('', cfg), { 'my-ai' }))
  -- unusable commands are refused with a message, not run
  for _, bad in ipairs({ {}, 'almanac ask', { 'almanac', 3 }, { '' } }) do
    local r, err = A.argv('q', { ask = bad, chat = bad })
    assert(r == nil and type(err) == 'string' and err:find('assistant.ask', 1, true), 'bad ask')
    r, err = A.argv('', { ask = bad, chat = bad })
    assert(r == nil and err:find('assistant.chat', 1, true), 'bad chat')
  end
end

-- view: pet | tab | window, anything else is a pet
do
  for _, v in ipairs({ 'pet', 'tab', 'window' }) do
    local o = A.open('q', { enabled = true, chat = A.chat, ask = A.ask, view = v }, 'linux')
    assert(o.view == v, v)
  end
  for _, v in ipairs({ 'dropdown', '', 42 }) do
    local o = A.open('q', { enabled = true, chat = A.chat, ask = A.ask, view = v }, 'linux')
    assert(o.view == 'pet', 'unknown view ' .. tostring(v))
  end
  local o = A.open('q', { enabled = true, chat = A.chat, ask = A.ask }, 'linux')
  assert(o.label == 'assistant' and same(o.argv, { 'almanac', 'ask', '--', 'q' }))
end

-- off: nothing opens, and the message says where to turn it on
do
  local o, err = A.open('q', { enabled = false, chat = A.chat, ask = A.ask })
  assert(o == nil and err:find('turned off', 1, true))
  o, err = A.open('q', {})
  assert(o == nil, 'a table without enabled is off')
end

-- transport: the platform's first profile by default
do
  local t, fb = A.transport_for('default', 'wine')
  assert(t == 'agent' and fb == false, 'Wine: the Linux agent, no local fallback')
  t, fb = A.transport_for('default', 'linux')
  assert(t == 'agent' and fb == false)
  t, fb = A.transport_for('default', 'windows')
  assert(t == 'agent' and fb == true, 'native Windows: the agent, locally while none answers')
  t, fb = A.transport_for(nil, 'windows')
  assert(t == 'agent' and fb == true, 'unset is the default')
  t, fb = A.transport_for('agent', 'windows')
  assert(t == 'agent' and fb == false, 'an explicit agent has no fallback')
  t, fb = A.transport_for('conpty', 'linux')
  assert(t == 'conpty' and fb == false)
  t = A.transport_for('ssh', 'linux')
  assert(t == 'agent', 'unknown: the default')
  local o = A.open('q', { enabled = true, chat = A.chat, ask = A.ask, transport = 'default' }, 'windows')
  assert(o.transport == 'agent' and o.local_fallback == true)
end

-- exit text: always "[assistant exited]", the hint only for a missing command
do
  local ok = A.exit_message(0, false)
  assert(ok:find('[assistant exited]', 1, true) and not ok:find('not found', 1, true))
  local failed = A.exit_message(1, false)
  assert(failed:find('[assistant exited] (status 1)', 1, true) and not failed:find('not found', 1, true))
  local missing = A.exit_message(127, false)
  assert(missing:find('not found', 1, true) and missing:find('almanac', 1, true))
  assert(missing:find('[assistant exited] (status 127)', 1, true))
  local refused = A.exit_message(0, true)
  assert(refused:find('not found', 1, true) and refused:find('[assistant did not start]', 1, true))
  -- fed straight to the screen: CRLF line ends, never a bare LF
  for _, m in ipairs({ ok, failed, missing, refused }) do
    assert(not m:gsub('\r\n', ''):find('\n'), 'bare LF')
  end
  -- a hint of one's own
  local own = A.exit_message(127, false, { not_found = 'install my-ai' })
  assert(own:find('install my-ai', 1, true))
  -- generic: no personal paths or hosts in the shipped hint
  assert(not A.not_found:find('/home/', 1, true) and not A.not_found:find('\\Users\\', 1, true))
  assert(not A.not_found:find('https?://'))
end

-- the hint is worded for the platform: where the command has to exist differs
do
  local win = A.not_found_text(A, 'windows')
  assert(win:find('almanac', 1, true) and win:find('PATH', 1, true), win)
  assert(win:find('ghostty-agent', 1, true), 'it offers the agent on another machine')
  assert(win:find('stream', 1, true), 'it offers another program')
  assert(win:find('/ask term', 1, true), 'it names the terminal fallback')
  local wine = A.not_found_text(A, 'wine')
  assert(wine ~= win and wine:find('ghostty-agent', 1, true), 'Wine: where the agent runs')
  assert(A.not_found_text(A, 'linux') == A.not_found, 'anything else keeps the plain text')
  -- a hint of one's own wins over the platform's wording
  assert(A.not_found_text({ not_found = 'install my-ai' }, 'windows') == 'install my-ai')
  -- and the assistant terminal prints it
  local m = A.exit_message(127, false, A, 'windows')
  assert(m:find('Windows machine', 1, true) and m:find('[assistant exited] (status 127)', 1, true))
  for _, t in ipairs({ win, wine }) do
    assert(not t:find('/home/', 1, true) and not t:find('C:\\Users', 1, true), 'no personal paths')
    assert(not t:find('\n'), 'one paragraph: it is printed as one line')
  end
end

-- the core's entry points read CONFIG.assistant
do
  local saved = CONFIG
  CONFIG = { assistant = setmetatable({ view = 'window' }, { __index = A }) }
  local o = A.core_open('hello')
  assert(o.view == 'window' and same(o.argv, { 'almanac', 'ask', '--', 'hello' }))
  CONFIG.assistant.enabled = false
  assert(A.core_open('hello') == nil)
  CONFIG = saved
end

print('assistant.lua OK')
