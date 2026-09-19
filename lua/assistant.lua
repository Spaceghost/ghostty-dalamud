-- /term ask: talk to a local AI assistant, in the /ask panel (lua/ask.lua)
-- or a terminal of its own.
--
-- The default assistant is almanac, a separate project: `almanac chat` is
-- its interactive REPL and `almanac ask "question"` answers once. Any other
-- program that takes the question as an argument works the same way: change
-- `chat` and `ask` below (in a copy of this file in the config directory's
-- lua/, or through CONFIG.assistant in your init.lua copy).
--
-- The question is never given to a shell. It becomes one argv element after
-- `ask`, so quotes, semicolons, `$(...)` and the like reach the assistant as
-- plain text. The terminal stays open after the assistant exits so the
-- answer can be read; close it like any other terminal.

local A = {
  -- false turns /term ask off (it then only prints a line in the log).
  enabled = true,
  -- 'panel': /ask answers in a chat panel in the game (lua/ask.lua), with
  -- follow-ups in threads; 'terminal': /ask opens a terminal running `chat`
  -- or `ask` below, as before. `/ask term <question>` always opens the terminal.
  ui = 'panel',
  -- The panel runs this argv, then --thread ID (or --new-thread),
  -- --allow-game-actions when ticked, '--' and the question. It must print
  -- JSON lines like `almanac ask --stream-json` (see almanac's README).
  stream = { 'almanac', 'ask', '--stream-json' },
  -- The panel's thread list and a thread's history: this argv, plus
  -- `show ID` for one thread.
  threads = { 'almanac', 'threads', '--json' },
  -- Offer the model the game's action and chat tools (XivMcp). The game
  -- still asks you to confirm each one; the panel has a tick box for it.
  game_actions = false,
  -- Also print the start of each answer in the game's chat (only you see it),
  -- at most echo_chars characters.
  echo = false,
  echo_chars = 200,
  -- /term ask with no question: the interactive session.
  chat = { 'almanac', 'chat' },
  -- /term ask <question>: this argv with the question appended as one more
  -- element. The '--' keeps a question starting with '-' from being read as
  -- an option.
  ask = { 'almanac', 'ask', '--' },
  -- 'default' uses the transport of the platform's first profile
  -- (lua/platform.lua): the agent, and on native Windows with a local
  -- ConPTY fallback while no agent answers. Or 'agent' | 'conpty'.
  transport = 'default',
  -- Where the terminal opens: 'pet' (floats beside your character; falls
  -- back to a tab when no character is loaded), 'tab' (the drop-down) or
  -- 'window' (a floating window).
  view = 'pet',
  -- Tab label.
  label = 'assistant',
  -- Printed when the command was not found (exit status 127, or an agent
  -- that refused to start it).
  not_found = 'The assistant command was not found on the machine running the shell. '
    .. 'Install almanac (a separate project) so that `almanac` is on PATH there, '
    .. 'or point CONFIG.assistant.chat / .ask (lua/assistant.lua) at another program.',
}

A.VIEWS = { 'pet', 'tab', 'window' }
A.TRANSPORTS = { 'default', 'agent', 'conpty' }

local function one_of(v, list, def)
  for _, x in ipairs(list) do if v == x then return v end end
  return def
end

-- A list of non-empty strings, copied; nil when it is not one.
local function argv_copy(t)
  if type(t) ~= 'table' or #t == 0 then return nil end
  local out = {}
  for i = 1, #t do
    if type(t[i]) ~= 'string' or t[i] == '' then return nil end
    out[i] = t[i]
  end
  return out
end

-- The chat line arrives cut at a byte limit: drop a UTF-8 sequence the cut
-- left incomplete, then surrounding blanks.
function A.clean(question)
  if type(question) ~= 'string' then return '' end
  local s = question
  -- only a lead byte followed by too few continuation bytes at the very end
  -- is a cut; invalid bytes anywhere else are left for the assistant
  local n, bad = utf8.len(s)
  if not n then
    local tail = s:sub(bad)
    local lead = tail:byte(1)
    local need = lead >= 0xF0 and 4 or lead >= 0xE0 and 3 or lead >= 0xC0 and 2 or 0
    if need > #tail and not tail:sub(2):find('[^\x80-\xBF]') then s = s:sub(1, bad - 1) end
  end
  return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

-- The argv for a question: `chat` for none, else `ask` plus the question as
-- one element. nil and a message when the configured command is unusable.
function A.argv(question, cfg)
  cfg = cfg or A
  local q = A.clean(question)
  if q == '' then
    local argv = argv_copy(cfg.chat)
    if not argv then return nil, 'assistant.chat must be a list of words, e.g. { "almanac", "chat" }' end
    return argv
  end
  local argv = argv_copy(cfg.ask)
  if not argv then return nil, 'assistant.ask must be a list of words, e.g. { "almanac", "ask", "--" }' end
  argv[#argv + 1] = q
  return argv
end

-- The transport for `setting` on `platform_name`: (transport, local_fallback).
-- 'default' follows the platform's first profile; local_fallback is true
-- when that profile has a fallback, i.e. the same command runs over ConPTY
-- while no agent answers (native Windows).
function A.transport_for(setting, platform_name)
  setting = one_of(setting, A.TRANSPORTS, 'default')
  if setting ~= 'default' then return setting, false end
  local ok, platform = pcall(require, 'platform')
  if not ok then return 'agent', false end
  local d = platform.defaults(platform_name or platform.name())
  local p = d and d.profiles and d.profiles[1]
  if not p then return 'agent', false end
  return p.transport or 'agent', p.transport == 'agent' and p.fallback ~= nil
end

-- What /term ask opens, for the core: nil and a message when it opens
-- nothing (disabled, bad command), else
--   { argv = {...}, transport = 'agent'|'conpty', local_fallback = bool,
--     view = 'pet'|'tab'|'window', label = '...' }
function A.open(question, cfg, platform_name)
  cfg = cfg or A
  if not cfg.enabled then return nil, 'the assistant is turned off (Settings, Assistant)' end
  local argv, err = A.argv(question, cfg)
  if not argv then return nil, err end
  local transport, fallback = A.transport_for(cfg.transport, platform_name)
  return {
    argv = argv,
    transport = transport,
    local_fallback = fallback,
    view = one_of(cfg.view, A.VIEWS, 'pet'),
    label = type(cfg.label) == 'string' and cfg.label ~= '' and cfg.label or 'assistant',
  }
end

-- The lines shown when the assistant's process ends. `status` is its exit
-- status; `refused` is true when it never started (the agent refused it).
function A.exit_message(status, refused, cfg)
  cfg = cfg or A
  local lines = { '' }
  if refused or status == 127 then
    lines[#lines + 1] = '\27[33m' .. tostring(cfg.not_found or A.not_found) .. '\27[0m'
  end
  local what
  if refused then
    what = '[assistant did not start]'
  elseif status == 0 then
    what = '[assistant exited]'
  else
    what = string.format('[assistant exited] (status %d)', status)
  end
  lines[#lines + 1] = '\27[90m' .. what .. ' Close this terminal when you are done reading.\27[0m'
  lines[#lines + 1] = ''
  -- terminal line ends: the text is fed to the screen, not through a tty
  return table.concat(lines, '\r\n')
end

-- Called by the core through CONFIG.assistant (A with CONFIG.assistant's own
-- values as the configuration).
function A.core_open(question) return A.open(question, CONFIG and CONFIG.assistant or A) end
function A.core_exit(status, refused) return A.exit_message(status, refused, CONFIG and CONFIG.assistant or A) end

return A
