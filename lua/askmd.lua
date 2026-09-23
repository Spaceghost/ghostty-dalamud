-- Markdown for the /ask panel: an answer's text as a document the panel lays
-- out (lua/askview.lua) and links (lua/asklinks.lua). Pure Lua, no ghostty.*:
-- tests/test_ask_rich.lua runs it on its own.
--
-- A document is a list of blocks, each { t = kind, ... }:
--   { t = 'p', inl = spans }                      a paragraph
--   { t = 'h', level = 1..6, inl = spans }        a heading (# ... ######)
--   { t = 'li', depth = 0.., marker = m, inl = spans }
--       m: 'bullet', 'task', 'done' or the number text ('3.')
--   { t = 'code', lang = s, text = s, closed = bool }   ``` or ~~~ fences
--   { t = 'quote', blocks = document }            > quoted lines, parsed again
--   { t = 'table', head = { spans... }, rows = { { spans... }... }, align = { 'l'|'c'|'r'... } }
--   { t = 'hr' }
-- and spans are { text =, b =, i =, s =, code =, link =, br = } runs of one
-- style: bold, italic, strike, inline code, a link ({ kind = 'url', url = })
-- or a line break inside the block. An unclosed fence runs to the end, as it
-- does while an answer streams in.
--
-- Parsed once per message update (lua/ask.lua keeps the result), never per frame.

local M = {}

-- Inline -------------------------------------------------------------------------------

local function copy_style(st, add)
  local o = { b = st.b, i = st.i, s = st.s, link = st.link }
  if add then for k, v in pairs(add) do o[k] = v end end
  return o
end

local function push(out, text, st)
  if text == '' then return end
  local last = out[#out]
  if last and not last.br and not last.code and not st.code and last.b == st.b and last.i == st.i
     and last.s == st.s and last.link == st.link then
    last.text = last.text .. text
    return
  end
  out[#out + 1] = { text = text, b = st.b, i = st.i, s = st.s, code = st.code, link = st.link }
end

-- A bare or <...> URL's end: no trailing punctuation, no unbalanced ')'.
function M.trim_url(url)
  while true do
    local last = url:sub(-1)
    if last:match('[%.,;:!%?\'"%]>]') then
      url = url:sub(1, -2)
    elseif last == ')' then
      local _, opens = url:gsub('%(', '')
      local _, closes = url:gsub('%)', '')
      if closes > opens then url = url:sub(1, -2) else break end
    else
      break
    end
  end
  return url
end

local function is_word(c) return c ~= '' and c:match('[%w\128-\255]') ~= nil end

local parse_inline -- forward

-- The closing run of `run` (e.g. '**') in s after `from`, for an opener at `at`:
-- not preceded by whitespace, and for '_' not followed by a word character.
local function find_closer(s, run, from)
  local ch = run:sub(1, 1)
  local i = from
  while true do
    local a, b = s:find(run, i, true)
    if not a then return nil end
    local before = s:sub(a - 1, a - 1)
    local after = s:sub(b + 1, b + 1)
    local longer = after == ch -- part of a longer run: '**' is not the end of '*'
    if a > from and not before:match('%s') and not longer and not (ch == '_' and is_word(after)) then
      return a, b
    end
    i = a + (longer and #run + 1 or 1)
    if longer then while s:sub(i, i) == ch do i = i + 1 end end
  end
end

function parse_inline(s, st, out)
  out = out or {}
  st = st or {}
  local buf = {}
  local function flush()
    if #buf > 0 then push(out, table.concat(buf), st) buf = {} end
  end
  local i, n = 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == '\\' and s:sub(i + 1, i + 1):match('%p') then
      buf[#buf + 1] = s:sub(i + 1, i + 1)
      i = i + 2
    elseif c == '\n' then
      flush()
      out[#out + 1] = { br = true, text = '' }
      i = i + 1
    elseif c == '`' then
      local run = s:match('^`+', i)
      local a, b = s:find(run, i + #run, true)
      while a and s:sub(b + 1, b + 1) == '`' do a, b = s:find(run, b + 2, true) end
      if a then
        flush()
        local code = s:sub(i + #run, a - 1):gsub('\n', ' ')
        if code:match('^ .* $') and code:match('%S') then code = code:sub(2, -2) end
        out[#out + 1] = { text = code, code = true, b = st.b, i = st.i, link = st.link }
        i = b + 1
      else
        buf[#buf + 1] = run
        i = i + #run
      end
    elseif c == '[' and not st.link then
      -- [label](url "title")
      local close = s:find(']', i + 1, true)
      local url, after
      if close and s:sub(close + 1, close + 1) == '(' then
        url, after = s:match('^%(%s*<?([^%s<>%)]*)>?%s*"?[^"%)]*"?%s*%)()', close + 1)
      end
      if url and url ~= '' then
        flush()
        local link
        if url:match('^[Hh][Tt][Tt][Pp][Ss]?://') then
          link = { kind = 'url', url = url }
        elseif url:match('^thread:') then
          link = { kind = 'thread', id = url:sub(8) }
        else
          link = { kind = 'url', url = url }
        end
        parse_inline(s:sub(i + 1, close - 1), copy_style(st, { link = link }), out)
        i = after
      else
        buf[#buf + 1] = c
        i = i + 1
      end
    elseif c == '<' and s:match('^<[Hh][Tt][Tt][Pp][Ss]?://[^%s<>]+>', i) then
      flush()
      local url = s:match('^<([^>]+)>', i)
      push(out, url, copy_style(st, { link = { kind = 'url', url = url } }))
      i = i + #url + 2
    elseif (c == 'h' or c == 'H') and not st.link and s:match('^[Hh][Tt][Tt][Pp][Ss]?://%S', i)
        and not is_word(s:sub(i - 1, i - 1)) then
      local raw = s:match('^[^%s<>"`]+', i)
      local url = M.trim_url(raw)
      flush()
      push(out, url, copy_style(st, { link = { kind = 'url', url = url } }))
      i = i + #url
    elseif c == '*' or c == '_' or (c == '~' and s:sub(i + 1, i + 1) == '~') then
      local run = s:match('^' .. (c == '*' and '%*+' or c == '_' and '_+' or '~+'), i)
      if #run > 3 then run = run:sub(1, 3) end
      if c == '~' then run = '~~' end
      local nextc = s:sub(i + #run, i + #run)
      local prev = s:sub(i - 1, i - 1)
      local opens = nextc ~= '' and not nextc:match('%s') and not (c == '_' and is_word(prev))
      local a, b
      if opens then a, b = find_closer(s, run, i + #run) end
      if a then
        flush()
        local add
        if c == '~' then add = { s = true }
        elseif #run == 1 then add = { i = true }
        elseif #run == 2 then add = { b = true }
        else add = { b = true, i = true } end
        parse_inline(s:sub(i + #run, a - 1), copy_style(st, add), out)
        i = b + 1
      else
        buf[#buf + 1] = run
        i = i + #run
      end
    else
      -- a run of plain characters at once
      local plain = s:match('^[^\\\n`%[<hH%*_~]+', i)
      if plain then
        buf[#buf + 1] = plain
        i = i + #plain
      else
        buf[#buf + 1] = c
        i = i + 1
      end
    end
  end
  flush()
  return out
end

-- Spans of one line (or several joined with \n, which become line breaks).
function M.inline(s)
  return parse_inline(s or '', {}, {})
end

-- The text of spans, marks gone (for measuring, copying and tests).
function M.plain(spans)
  local out = {}
  for _, sp in ipairs(spans or {}) do out[#out + 1] = sp.br and '\n' or sp.text end
  return table.concat(out)
end

-- Blocks ----------------------------------------------------------------------------------

local function split_row(line)
  line = line:gsub('^%s*|', ''):gsub('|%s*$', '')
  local cells, cur, i = {}, {}, 1
  while i <= #line do
    local c = line:sub(i, i)
    if c == '\\' and line:sub(i + 1, i + 1) == '|' then
      cur[#cur + 1] = '|'
      i = i + 2
    elseif c == '|' then
      cells[#cells + 1] = table.concat(cur):match('^%s*(.-)%s*$')
      cur = {}
      i = i + 1
    else
      cur[#cur + 1] = c
      i = i + 1
    end
  end
  cells[#cells + 1] = table.concat(cur):match('^%s*(.-)%s*$')
  return cells
end

-- The | --- | :-: | row under a table's header, with as many cells as it.
local function is_delim_row(line, cells)
  if not line or not line:find('-', 1, true) then return false end
  local row = split_row(line)
  if #row ~= cells then return false end
  for _, cell in ipairs(row) do
    if not cell:match('^:?%-+:?$') then return false end
  end
  return true
end

local function is_hr(line)
  local ch = line:match('^%s*([%-%*_])')
  if not ch then return false end
  local rest = line:gsub('%s', '')
  return #rest >= 3 and rest == string.rep(ch, #rest)
end

local parse_blocks

local function list_item(line)
  local ind, rest = line:match('^(%s*)[%-%*%+]%s+(.*)$')
  local number
  if not ind then
    ind, number, rest = line:match('^(%s*)(%d+)[%.%)]%s+(.*)$')
    if ind and #number > 9 then ind = nil end
  end
  if not ind then return nil end
  local marker = number and (number .. '.') or 'bullet'
  if not number then
    local box, after = rest:match('^%[([ xX])%]%s+(.*)$')
    if box then
      marker = box == ' ' and 'task' or 'done'
      rest = after
    end
  end
  return #ind:gsub('\t', '    '), marker, rest
end

-- Lines -> blocks. Anything but a list item ends a list (blank lines do not:
-- a loose list keeps its nesting).
function parse_blocks(lines)
  local blocks = {}
  local para -- the paragraph or list item that takes continuation lines
  local indents = {} -- the list's indentation stack, for depth
  local i = 1
  local function close_para() para = nil end
  while i <= #lines do
    local line = lines[i]
    local fence_ind, fence, lang = line:match('^(%s*)(```+)%s*([^`]*)$')
    if not fence then fence_ind, fence, lang = line:match('^(%s*)(~~~+)%s*(.*)$') end
    if fence then
      close_para()
      indents = {}
      local code, closed = {}, false
      local j = i + 1
      while j <= #lines do
        local l = lines[j]
        local ind2, close_run = l:match('^(%s*)([`~]+)%s*$')
        if close_run and close_run:sub(1, 1) == fence:sub(1, 1) and #close_run >= #fence and #ind2 <= #fence_ind + 3 then
          closed = true
          break
        end
        -- the fence's own indentation comes off each line
        local strip = math.min(#fence_ind, #(l:match('^%s*')))
        code[#code + 1] = l:sub(strip + 1)
        j = j + 1
      end
      blocks[#blocks + 1] = { t = 'code', lang = (lang or ''):match('^%s*(%S*)') or '', text = table.concat(code, '\n'), closed = closed }
      i = j + 1
    elseif not line:match('%S') then
      close_para()
      i = i + 1
    elseif line:match('^%s*#+%s') or line:match('^%s*#+$') then
      close_para()
      indents = {}
      local hashes, text = line:match('^%s*(#+)%s*(.-)%s*$')
      text = text:gsub('%s+#+$', '')
      if #hashes <= 6 then
        blocks[#blocks + 1] = { t = 'h', level = #hashes, inl = M.inline(text) }
      else
        blocks[#blocks + 1] = { t = 'p', inl = M.inline(line) }
      end
      i = i + 1
    elseif is_hr(line) and not (para and para.t == 'li' and line:match('^%s*[%-%*]%s+%S')) then
      close_para()
      indents = {}
      blocks[#blocks + 1] = { t = 'hr' }
      i = i + 1
    elseif line:match('^%s*>') then
      close_para()
      indents = {}
      local q = {}
      while i <= #lines and lines[i]:match('^%s*>') do
        q[#q + 1] = lines[i]:gsub('^%s*>%s?', '', 1)
        i = i + 1
      end
      blocks[#blocks + 1] = { t = 'quote', blocks = parse_blocks(q) }
    elseif line:find('|', 1, true) and is_delim_row(lines[i + 1], #split_row(line)) then
      close_para()
      indents = {}
      local head = split_row(line)
      local align = {}
      for k, cell in ipairs(split_row(lines[i + 1])) do
        align[k] = cell:match('^:.*:$') and 'c' or cell:match(':$') and 'r' or 'l'
      end
      local tb = { t = 'table', head = {}, rows = {}, align = align }
      for k, cell in ipairs(head) do tb.head[k] = M.inline(cell) end
      i = i + 2
      while i <= #lines and lines[i]:find('|', 1, true) and lines[i]:match('%S') do
        local row = {}
        for k, cell in ipairs(split_row(lines[i])) do
          if k <= #head then row[k] = M.inline(cell) end
        end
        for k = #row + 1, #head do row[k] = {} end
        tb.rows[#tb.rows + 1] = row
        i = i + 1
      end
      for k = #align + 1, #head do align[k] = 'l' end
      blocks[#blocks + 1] = tb
    else
      local ind, marker, rest = list_item(line)
      if ind then
        -- depth from the indentation stack: deeper than the last item nests
        while #indents > 0 and ind < indents[#indents] do indents[#indents] = nil end
        if #indents == 0 or ind > indents[#indents] then indents[#indents + 1] = ind end
        local item = { t = 'li', depth = math.min(#indents - 1, 5), marker = marker, src = rest }
        blocks[#blocks + 1] = item
        para = item
      elseif para then
        -- a continuation line: a line break in the paragraph or item
        para.src = para.src .. '\n' .. line:match('^%s*(.-)$')
      else
        indents = {}
        para = { t = 'p', src = line:match('^%s*(.-)$') }
        blocks[#blocks + 1] = para
      end
      i = i + 1
    end
  end
  for _, b in ipairs(blocks) do
    if b.src then
      b.inl = M.inline(b.src)
      b.src = nil
    end
  end
  return blocks
end

function M.parse(text)
  if type(text) ~= 'string' or text == '' then return {} end
  local lines = {}
  for line in (text .. '\n'):gmatch('(.-)\r?\n') do lines[#lines + 1] = line end
  return parse_blocks(lines)
end

-- Walk every span of a document (quotes and table cells included):
-- fn(spans, block) for each list of spans. Code blocks have none.
function M.each_inline(doc, fn)
  for _, b in ipairs(doc) do
    if b.inl then fn(b.inl, b) end
    if b.t == 'quote' then M.each_inline(b.blocks, fn) end
    if b.t == 'table' then
      for _, cell in ipairs(b.head) do fn(cell, b) end
      for _, row in ipairs(b.rows) do for _, cell in ipairs(row) do fn(cell, b) end end
    end
  end
end

-- The document's text without marks, a block per paragraph: what "copy" and
-- the chat echo use.
function M.to_text(doc)
  local out = {}
  for _, b in ipairs(doc) do
    if b.t == 'code' then out[#out + 1] = b.text
    elseif b.t == 'quote' then out[#out + 1] = M.to_text(b.blocks)
    elseif b.t == 'table' then
      local rows = {}
      local head = {}
      for k, c in ipairs(b.head) do head[k] = M.plain(c) end
      rows[1] = table.concat(head, ' | ')
      for _, r in ipairs(b.rows) do
        local cells = {}
        for k, c in ipairs(r) do cells[k] = M.plain(c) end
        rows[#rows + 1] = table.concat(cells, ' | ')
      end
      out[#out + 1] = table.concat(rows, '\n')
    elseif b.t == 'hr' then out[#out + 1] = '---'
    elseif b.inl then
      local prefix = ''
      if b.t == 'li' then
        prefix = string.rep('  ', b.depth) .. (b.marker == 'bullet' and '- ' or b.marker == 'task' and '[ ] '
          or b.marker == 'done' and '[x] ' or (b.marker .. ' '))
      end
      out[#out + 1] = prefix .. M.plain(b.inl)
    end
  end
  return table.concat(out, '\n\n')
end

return M
