-- Links in /ask answers: what in an answer's markdown (lua/askmd.lua) is
-- clickable, what each link does, and the follow-up questions under an answer.
--
--   url      https links (and [label](url)): open in your browser through
--            ghostty.open_url, on click only. Other schemes are shown, never opened.
--   coord    map coordinates like (X: 9.9, Y: 8.6): a flag on the map of the
--            zone named before them in the answer (else where you are), and
--            the map opens.
--   command  a slash command in a code span (`/term selftest`): put in the
--            game's chat input, never sent; running it takes an explicit
--            confirm in the panel, and chat commands (/say, /tell, /p...) never run.
--   thread   [label](thread:ID): that conversation.
--   item, zone, aetheryte, quest, duty, npc, action, status
--            names the game knows (ghostty.game_lookup: the game's own sheets):
--            an item links into the chat input (not sent), a zone opens its
--            map, an aetheryte or NPC is flagged on the map, a quest opens in
--            the journal, a duty in the Duty Finder. Actions and statuses only
--            explain themselves in a tooltip. Nothing here moves your
--            character or uses an action, and the host refuses every game
--            action while you are in combat.
--
-- Everything that touches the game goes through two host calls, so the tests
-- replace them with fakes: ghostty.game_lookup(names) and
-- ghostty.game_action(verb, arg).

local md = require('askmd')

local M = {}

-- Game names -----------------------------------------------------------------------------

-- One resolver per panel: every name asked about once, the answers kept.
-- ghostty.game_lookup(request) -> response text:
--   request   candidate names, one per line
--   response  'ok' or 'pending' (the host is still indexing the sheets; ask
--             again), then one line per name it knows:
--             query \t kind \t id \t icon \t name \t territory \t map \t detail
--             (detail: the tooltip's text, '\n' written as the two characters \n)
local R = { known = {}, retry_at = 0, calls = 0 }
M.resolver = R

function M.reset_resolver()
  R.known, R.retry_at, R.calls = {}, 0, 0
end

local function key(name) return (name:lower():gsub('^the%s+', '')) end

local KINDS = { item = true, zone = true, aetheryte = true, quest = true, duty = true, npc = true, action = true, status = true }

function M.parse_lookup(text)
  local out, status = {}, nil
  for line in (text .. '\n'):gmatch('(.-)\r?\n') do
    if not status then
      status = line
    elseif line ~= '' then
      local f = {}
      for field in (line .. '\t'):gmatch('(.-)\t') do f[#f + 1] = field end
      local kind = f[2]
      if f[1] and KINDS[kind] and tonumber(f[3]) then
        out[key(f[1])] = {
          kind = kind, id = tonumber(f[3]), icon = tonumber(f[4]) or 0, name = f[5] ~= '' and f[5] or f[1],
          territory = tonumber(f[6]) or 0, map = tonumber(f[7]) or 0,
          detail = (f[8] or ''):gsub('\\n', '\n'),
        }
      end
    end
  end
  return out, status == 'ok'
end

-- The game's answers for `names`: { [key] = info | false }, and whether all
-- of them are known (false while the host is still indexing).
function M.lookup(names, now)
  local want, seen = {}, {}
  for _, n in ipairs(names) do
    local k = key(n)
    if R.known[k] == nil and not seen[k] then
      seen[k] = true
      want[#want + 1] = n
    end
  end
  local complete = true
  if #want > 0 then
    local fn = ghostty and ghostty.game_lookup
    if not fn then
      for _, n in ipairs(want) do R.known[key(n)] = false end
    elseif (now or 0) < R.retry_at then
      complete = false
    else
      R.calls = R.calls + 1
      local ok, text = pcall(fn, table.concat(want, '\n'))
      if not ok or type(text) ~= 'string' then
        for _, n in ipairs(want) do R.known[key(n)] = false end
      else
        local found, done = M.parse_lookup(text)
        if done then
          for _, n in ipairs(want) do R.known[key(n)] = found[key(n)] or false end
        else
          complete = false
          R.retry_at = (now or 0) + 1
        end
      end
    end
  end
  return R.known, complete
end

-- Candidate names ---------------------------------------------------------------------------

-- Short words that may sit inside a name ("Tincture of Strength", "the Keeper
-- of the Lake") but never start or end one.
local JOIN = { ['of'] = true, ['the'] = true, ['and'] = true, ['de'] = true, ['du'] = true, ['la'] = true,
  ['le'] = true, ['des'] = true, ['in'] = true, ['on'] = true, ['to'] = true, ['a'] = true, ['an'] = true,
  ['for'] = true, ['with'] = true, ['at'] = true, ['from'] = true, ['under'] = true, ['over'] = true }
-- Single capitalised words that are names in the game and ordinary words in
-- an answer: never a link on their own unless emphasised.
local COMMON = { ['the'] = true, ['you'] = true, ['your'] = true, ['this'] = true, ['that'] = true, ['it'] = true,
  ['yes'] = true, ['no'] = true, ['map'] = true, ['earth'] = true, ['fire'] = true, ['water'] = true,
  ['wind'] = true, ['ice'] = true, ['lightning'] = true, ['return'] = true, ['sprint'] = true,
  ['teleport'] = true, ['gil'] = true, ['note'] = true, ['tip'] = true, ['step'] = true, ['then'] = true,
  ['if'] = true, ['when'] = true, ['once'] = true, ['after'] = true, ['before'] = true, ['also'] = true,
  ['i'] = true, ['a'] = true, ['in'] = true, ['on'] = true, ['for'] = true, ['go'] = true, ['talk'] = true }

local function words(text)
  local out = {}
  local pos = 1
  while true do
    local a, b = text:find("[%w\128-\255][%w\128-\255'%-]*", pos)
    if not a then break end
    local w = text:sub(a, b)
    -- a trailing apostrophe or hyphen belongs to the text around it
    while w:match("['%-]$") do
      w = w:sub(1, -2)
      b = b - 1
    end
    out[#out + 1] = { w = w, a = a, b = b }
    pos = b + 1
    if pos <= a then pos = a + 1 end
  end
  return out
end

local function cap(w) return w:match('^[A-Z]') ~= nil end
local function num(w) return w:match('^%d') ~= nil end

-- Phrases of `text` that could be names: runs of capitalised words (numbers
-- and joining words inside), every sub-run that starts and ends on a
-- capitalised word, at most 8 words. { text =, a =, b =, n = words, first = sentence-initial }
function M.candidates(text, at_start)
  local ws = words(text)
  local out = {}
  local i = 1
  while i <= #ws do
    if cap(ws[i].w) then
      local j = i
      while j + 1 <= #ws do
        local gap = text:sub(ws[j].b + 1, ws[j + 1].a - 1)
        local nw = ws[j + 1].w
        if not gap:match('^ +$') or not (cap(nw) or num(nw) or JOIN[nw]) then break end
        j = j + 1
      end
      for s = i, j do
        if cap(ws[s].w) then
          local before = text:sub(1, ws[s].a - 1)
          local first = (s == 1 and at_start and not before:match('%S')) or before:match('[%.!%?:]%s*$') ~= nil
          for e = s, math.min(j, s + 7) do
            if cap(ws[e].w) or num(ws[e].w) then
              out[#out + 1] = { text = text:sub(ws[s].a, ws[e].b), a = ws[s].a, b = ws[e].b, n = e - s + 1, first = first }
            end
          end
        end
      end
      i = j + 1
    else
      i = i + 1
    end
  end
  return out
end

-- Whether a resolved candidate should become a link.
function M.accept(c, info, emph)
  if not info then return false end
  if emph then return true end
  if c.n > 1 then return true end
  local k = c.text:lower()
  if COMMON[k] or #c.text < 4 then return false end
  if info.kind == 'npc' or info.kind == 'action' or info.kind == 'status' then return false end
  -- a sentence starting "Potion ..." is about potions; one starting "Sastasha ..." is about Sastasha
  return not (c.first and info.kind == 'item')
end

-- Coordinates ------------------------------------------------------------------------------

local function coord_ok(v) return v and v > 0 and v < 50 end

-- Map coordinates in `text`: { a =, b =, x =, y = } for "(X: 9.9, Y: 8.6)",
-- "X: 9.9 Y: 8.6", "x9.9, y8.6" and a bare "(9.9, 8.6)" (one decimal each).
function M.coords(text)
  local out = {}
  local pos = 1
  while pos <= #text do
    local a, b, x, y = text:find('[Xx]%s*[:=]?%s*(%d+%.?%d*)%s*[,/;]?%s*[Yy]%s*[:=]?%s*(%d+%.?%d*)', pos)
    local a2, b2, x2, y2 = text:find('%((%d%d?%.%d)%s*,%s*(%d%d?%.%d)%)', pos)
    if a2 and (not a or a2 < a) then a, b, x, y = a2, b2, x2, y2 end
    if not a then break end
    local prev = text:sub(a - 1, a - 1)
    x, y = tonumber(x), tonumber(y)
    if not prev:match('[%a]') and coord_ok(x) and coord_ok(y) then
      -- the brackets around it and a ", Z: 0.1" after it belong to it
      local z1, z2 = text:find('^%s*,?%s*[Zz]%s*[:=]?%s*%d+%.?%d*', b + 1)
      if z1 then b = z2 end
      if text:sub(a - 1, a - 1) == '(' and text:sub(b + 1, b + 1) == ')' then a, b = a - 1, b + 1 end
      out[#out + 1] = { a = a, b = b, x = x, y = y }
    end
    pos = b + 1
  end
  return out
end

-- Slash commands ---------------------------------------------------------------------------

function M.command(code)
  if type(code) ~= 'string' or #code > 200 or code:find('\n', 1, true) then return nil end
  local cmd = code:match('^%s*(/[%a][%w_%-]*.-)%s*$')
  return cmd
end

-- Chat channels and emotes that say something to other players: never run
-- from the panel, only put in the chat input for you to send yourself.
local CHANNELS = { 's', 'say', 'sh', 'shout', 'y', 'yell', 't', 'tell', 'r', 'reply', 'p', 'party', 'fc',
  'freecompany', 'a', 'alliance', 'n', 'novice', 'beginner', 'em', 'emote', 'pvpteam', 'cwlinkshell',
  'linkshell', 'l', 'cwl', 'ls', 'fellowship', 'fw' }
local CHANNEL = {}
for _, c in ipairs(CHANNELS) do CHANNEL[c] = true end

function M.says_something(cmd)
  local verb = (cmd or ''):match('^/(%a+)')
  if not verb then return true end
  if CHANNEL[verb:lower()] then return true end
  -- the numbered ones: /l1../l8, /cwl1.., /linkshell1.., /cwlinkshell1..
  local numbered = cmd:match('^/(%a+)%d')
  return numbered ~= nil and CHANNEL[numbered:lower()] == true
end

-- Linking a document -----------------------------------------------------------------------

local function split_span(sp, cuts)
  -- cuts: sorted, non-overlapping { a =, b =, link = } byte ranges of sp.text
  local out, pos = {}, 1
  for _, c in ipairs(cuts) do
    if c.a > pos then out[#out + 1] = { text = sp.text:sub(pos, c.a - 1), b = sp.b, i = sp.i, s = sp.s } end
    out[#out + 1] = { text = sp.text:sub(c.a, c.b), b = sp.b, i = sp.i, s = sp.s, link = c.link }
    pos = c.b + 1
  end
  if pos <= #sp.text then out[#out + 1] = { text = sp.text:sub(pos), b = sp.b, i = sp.i, s = sp.s } end
  return out
end

local function overlaps(cuts, a, b)
  for _, c in ipairs(cuts) do
    if a <= c.b and b >= c.a then return true end
  end
  return false
end

local function entity_link(info)
  return { kind = info.kind, id = info.id, icon = info.icon, name = info.name, territory = info.territory,
    map = info.map, detail = info.detail }
end

-- Turn what can be a link into one, in place: coordinates, slash commands in
-- code spans and the names the game knows. Returns whether every name could
-- be asked about (false: ask again in a second, the host is still indexing).
function M.link(doc, now)
  -- first pass: what to ask the game about
  local names = {}
  md.each_inline(doc, function(spans)
    for idx, sp in ipairs(spans) do
      if not sp.br and not sp.code and not sp.link and sp.text ~= '' then
        local prev = spans[idx - 1]
        local at_start = idx == 1 or (prev and (prev.br or (prev.text or ''):match('[%.!%?:]%s*$')))
        for _, c in ipairs(M.candidates(sp.text, at_start)) do names[#names + 1] = c.text end
        if (sp.b or sp.i) and #sp.text <= 60 then names[#names + 1] = sp.text:match('^%s*(.-)%s*$') end
      end
    end
  end)
  local known, complete = M.lookup(names, now)
  -- second pass: split spans at the links
  local zone -- the last zone or aetheryte named so far: coordinates after it are in it
  md.each_inline(doc, function(spans)
    local out = {}
    for idx, sp in ipairs(spans) do
      if sp.code and not sp.link then
        local cmd = M.command(sp.text)
        if cmd then sp.link = { kind = 'command', text = cmd } end
        out[#out + 1] = sp
      elseif sp.br or sp.link or sp.text == '' then
        if sp.link and KINDS[sp.link.kind] and (sp.link.kind == 'zone' or sp.link.kind == 'aetheryte') then zone = sp.link end
        out[#out + 1] = sp
      else
        local cuts = {}
        local trimmed = sp.text:match('^%s*(.-)%s*$')
        local whole = (sp.b or sp.i) and known[key(trimmed)]
        if whole then
          local a = sp.text:find(trimmed, 1, true)
          cuts[1] = { a = a, b = a + #trimmed - 1, link = entity_link(whole) }
        else
          local prev = spans[idx - 1]
          local at_start = idx == 1 or (prev and (prev.br or (prev.text or ''):match('[%.!%?:]%s*$')))
          local cands = M.candidates(sp.text, at_start)
          -- longest first, then leftmost
          table.sort(cands, function(x, y) if x.n ~= y.n then return x.n > y.n end return x.a < y.a end)
          for _, c in ipairs(cands) do
            local info = known[key(c.text)]
            if info and M.accept(c, info, false) and not overlaps(cuts, c.a, c.b) then
              cuts[#cuts + 1] = { a = c.a, b = c.b, link = entity_link(info) }
            end
          end
        end
        for _, c in ipairs(M.coords(sp.text)) do
          if not overlaps(cuts, c.a, c.b) then
            cuts[#cuts + 1] = { a = c.a, b = c.b, link = { kind = 'coord', x = c.x, y = c.y } }
          end
        end
        table.sort(cuts, function(x, y) return x.a < y.a end)
        -- in reading order, so coordinates take the zone named before them
        for _, c in ipairs(cuts) do
          if c.link.kind == 'zone' or c.link.kind == 'aetheryte' then
            zone = c.link
          elseif c.link.kind == 'coord' and zone then
            c.link.territory, c.link.map, c.link.zone = zone.territory, zone.map, zone.name
          end
        end
        if #cuts == 0 then
          out[#out + 1] = sp
        else
          for _, piece in ipairs(split_span(sp, cuts)) do out[#out + 1] = piece end
        end
      end
    end
    -- in place: the block keeps its table
    for k = 1, math.max(#spans, #out) do spans[k] = out[k] end
  end)
  return complete
end

-- Every link of a document, in order, each once: { link }.
function M.collect(doc)
  local out, seen = {}, {}
  md.each_inline(doc, function(spans)
    for _, sp in ipairs(spans) do
      if sp.link and not seen[sp.link] then
        seen[sp.link] = true
        out[#out + 1] = sp.link
      end
    end
  end)
  return out
end

-- The sources under an answer: its https links, each once.
function M.sources(doc)
  local out, seen = {}, {}
  for _, l in ipairs(M.collect(doc)) do
    if l.kind == 'url' and l.url:match('^[Hh][Tt][Tt][Pp][Ss]://') and not seen[l.url] then
      seen[l.url] = true
      out[#out + 1] = l
    end
  end
  return out
end

function M.domain(url)
  return (url:match('^%a+://([^/%?#]+)') or url):gsub('^www%.', '')
end

-- What a link says under the pointer: title, body, and what a click does.
function M.describe(l)
  local k = l.kind
  if k == 'url' then
    if not l.url:match('^[Hh][Tt][Tt][Pp][Ss]://') then return l.url, nil, 'Only https links open from here' end
    return M.domain(l.url), l.url, 'Click: open in your browser'
  elseif k == 'coord' then
    local where = l.zone or 'the zone you are in'
    return string.format('X %.1f, Y %.1f', l.x, l.y), where, 'Click: place a flag there and open the map'
  elseif k == 'command' then
    local hint = 'Click: put it in your chat input (not sent); running it asks first'
    if M.says_something(l.text) then hint = 'Click: put it in your chat input (not sent). Chat is never sent from here' end
    return l.text, nil, hint
  elseif k == 'thread' then
    return 'Another conversation', l.id, 'Click: open it'
  elseif k == 'followup' then
    return l.text, nil, 'Click: ask it \u{b7} right-click: ask it in a new conversation'
  elseif k == 'copy' then
    return 'Copy', nil, 'Click: copy this code to the clipboard'
  end
  local hints = {
    item = 'Click: link it in your chat input (not sent)',
    zone = 'Click: open its map',
    aetheryte = 'Click: flag it on the map',
    quest = 'Click: open it in your journal',
    duty = 'Click: open it in the Duty Finder',
    npc = 'Click: flag where they stand, when the game knows',
  }
  local label = { item = 'Item', zone = 'Zone', aetheryte = 'Aetheryte', quest = 'Quest', duty = 'Duty',
    npc = 'NPC', action = 'Action', status = 'Status' }
  local body = label[k] or ''
  if l.detail and l.detail ~= '' then body = body .. ' \u{b7} ' .. l.detail end
  return l.name or '', body, hints[k]
end

-- Acting on a click --------------------------------------------------------------------------

local ACTION_RESULT = {
  [0] = 'the game could not do that right now',
  [2] = 'not while you are in combat',
  [3] = 'not before you are logged in',
}

local function act(verb, arg)
  local fn = ghostty and ghostty.game_action
  if not fn then return false, 'this plugin build cannot reach the game from /ask' end
  local ok, r = pcall(fn, verb, arg)
  if not ok then return false, 'the game refused it' end
  r = tonumber(r) or (r == true and 1) or 0
  if r == 1 then return true end
  return false, ACTION_RESULT[r] or ACTION_RESULT[0]
end
M.act = act

-- A click on link `l`. `ctx` is the panel's: { open_url = fn(url), copy = fn(text),
-- open_thread = fn(id), ask = fn(question, new_thread), confirm = fn(cmd) }.
-- Returns a status line for the panel (nil: nothing to say).
function M.activate(l, ctx, button)
  local k = l.kind
  if k == 'url' then
    if not l.url:match('^[Hh][Tt][Tt][Pp][Ss]://') then return 'Only https links open: ' .. l.url end
    return ctx.open_url(l.url)
  elseif k == 'thread' then
    ctx.open_thread(l.id)
    return nil
  elseif k == 'followup' then
    ctx.ask(l.text, button == 'right')
    return nil
  elseif k == 'command' then
    local ok = act('chat_input', l.text)
    if not ok then
      if ctx.copy then ctx.copy(l.text) end
      return 'Copied ' .. l.text .. ': paste it in your chat'
    end
    if M.says_something(l.text) then return 'In your chat input: ' .. l.text .. ' (sending it is up to you)' end
    ctx.confirm(l.text)
    return 'In your chat input: ' .. l.text .. ' (Enter there, or Run here, runs it)'
  elseif k == 'coord' then
    local ok, err = act('flag', string.format('%d\t%d\t%.2f\t%.2f', l.territory or 0, l.map or 0, l.x, l.y))
    if not ok then return 'Map: ' .. err end
    return string.format('Flag at X %.1f, Y %.1f%s', l.x, l.y, l.zone and (' in ' .. l.zone) or '')
  elseif k == 'item' or k == 'zone' or k == 'aetheryte' or k == 'quest' or k == 'duty' or k == 'npc' then
    local ok, err = act('open', k .. '\t' .. tostring(l.id))
    if not ok then return (l.name or k) .. ': ' .. err end
    local done = { item = ' is linked in your chat input', zone = ': map open', aetheryte = ': flagged on the map',
      quest = ': in your journal', duty = ': in the Duty Finder', npc = ': flagged on the map' }
    return (l.name or k) .. done[k]
  end
  return nil
end

-- Run a slash command after the panel's confirm; never a chat line.
function M.run_command(cmd)
  if not M.command(cmd) then return false, 'not a command' end
  if M.says_something(cmd) then return false, 'chat is never sent from /ask' end
  return act('chat_run', cmd)
end

-- Follow-up questions ------------------------------------------------------------------------

local TEMPLATES = {
  duty = 'How do I unlock %s?',
  quest = 'What comes after %s?',
  item = 'Where can I get %s?',
  zone = 'What is worth doing in %s?',
  aetheryte = 'What is near %s?',
  npc = 'Where do I find %s?',
  action = 'When should I use %s?',
}
local ORDER = { 'duty', 'quest', 'item', 'zone', 'aetheryte', 'npc', 'action' }
local GENERIC = { 'Can you go into more detail?', 'Sum that up in one line.' }

-- Two or three questions to ask next about `doc`: ones the answer itself
-- offers (a "Follow-up questions" section of items ending in '?'), else one
-- per kind of thing it named, then general ones.
function M.followups(doc, max)
  max = max or 3
  local out, seen = {}, {}
  local function add(q)
    if #out < max and q and not seen[q:lower()] then
      seen[q:lower()] = true
      out[#out + 1] = q
    end
  end
  local offered = false
  for _, b in ipairs(doc) do
    if (b.t == 'h' or b.t == 'p') and md.plain(b.inl):lower():match('follow[%- ]?up') then
      offered = true
    elseif offered and b.t == 'li' then
      local q = md.plain(b.inl):match('^%s*(.-)%s*$')
      if q:match('%?$') and #q <= 120 then add(q) end
    elseif offered and b.t ~= 'li' then
      offered = false
    end
  end
  if #out > 0 then return out end
  local first = {}
  for _, l in ipairs(M.collect(doc)) do
    if TEMPLATES[l.kind] and not first[l.kind] then first[l.kind] = l end
  end
  for _, k in ipairs(ORDER) do
    if first[k] then add(string.format(TEMPLATES[k], first[k].name)) end
  end
  for _, g in ipairs(GENERIC) do
    if #out < 2 then add(g) end
  end
  return out
end

return M
