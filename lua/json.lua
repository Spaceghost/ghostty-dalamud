-- A small, strict JSON (RFC 8259) encoder and decoder in plain Lua 5.4, for
-- the IPC channel other plugins call (lua/ipc.lua, docs/IPC.md).
--
--   json.decode(text) -> value            or nil, 'reason at byte N'
--   json.encode(value) -> text            or nil, 'reason'
--
-- Decoding is strict: one value and nothing after it but whitespace, no
-- comments, no trailing commas, no leading zeros, no raw control characters
-- in strings, only the standard escapes, \u escapes combined into UTF-8
-- (surrogate pairs joined, a lone surrogate refused), valid UTF-8 only,
-- nesting at most json.max_depth deep. Integers without a fraction or
-- exponent that fit decode as Lua integers, everything else as floats.
-- `null` decodes as json.null (so a key holding null stays visible); arrays
-- carry json.array_mt, so an empty array encodes back as [] and not {}.
--
-- Encoding: nil and json.null are null; a table is an array when it carries
-- json.array_mt or its keys are exactly 1..n (n >= 1), otherwise an object
-- whose keys must be strings (emitted sorted, so equal tables encode equal);
-- an empty unmarked table is {}. NaN and infinities, functions, cycles and
-- mixed keys are refused. A whole float keeps its '.0' (3.0 reads back as a
-- float, 3 as an integer). Invalid UTF-8 in strings becomes U+FFFD, so the
-- output is always valid JSON.

local M = {}

M.null = setmetatable({}, { __tostring = function() return 'null' end, __name = 'json.null' })
M.array_mt = { __name = 'json.array' }
M.max_depth = 64

-- Mark `t` (default: a new table) as an array.
function M.array(t)
  return setmetatable(t or {}, M.array_mt)
end

-- Decoding --------------------------------------------------------------------------

local byte, sub, char, find = string.byte, string.sub, string.char, string.find
local utf8char = utf8.char

local function fail(pos, what)
  error({ json_error = what .. ' at byte ' .. pos }, 0)
end

local function skip_ws(s, i)
  -- space, tab, newline, carriage return only
  local _, e = find(s, '^[ \t\n\r]*', i)
  return e + 1
end

local escapes = { [34] = '"', [92] = '\\', [47] = '/', [98] = '\b', [102] = '\f', [110] = '\n', [114] = '\r', [116] = '\t' }

local function hex4(s, i)
  local h = sub(s, i, i + 3)
  if #h < 4 or not find(h, '^%x%x%x%x$') then fail(i, 'bad \\u escape') end
  return tonumber(h, 16)
end

local function decode_string(s, i)
  -- s[i] is the opening quote
  local parts, n = {}, 0
  local j = i + 1
  while true do
    -- the longest run of plain characters
    local a, b = find(s, '^[^"\\%z\1-\31]+', j)
    if a then
      n = n + 1
      parts[n] = sub(s, a, b)
      j = b + 1
    end
    local c = byte(s, j)
    if c == nil then fail(j, 'unterminated string') end
    if c == 34 then
      local str = table.concat(parts)
      if not utf8.len(str) then fail(i, 'invalid UTF-8 in string') end
      return str, j + 1
    elseif c == 92 then
      local e = byte(s, j + 1)
      if e == 117 then -- \u
        local cp = hex4(s, j + 2)
        j = j + 6
        if cp >= 0xD800 and cp <= 0xDBFF then
          if sub(s, j, j + 1) ~= '\\u' then fail(j, 'lone high surrogate') end
          local lo = hex4(s, j + 2)
          if lo < 0xDC00 or lo > 0xDFFF then fail(j, 'lone high surrogate') end
          cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
          j = j + 6
        elseif cp >= 0xDC00 and cp <= 0xDFFF then
          fail(j - 6, 'lone low surrogate')
        end
        n = n + 1
        parts[n] = utf8char(cp)
      else
        local r = e and escapes[e]
        if not r then fail(j, 'bad escape') end
        n = n + 1
        parts[n] = r
        j = j + 2
      end
    else
      fail(j, 'control character in string')
    end
  end
end

local function decode_number(s, i)
  local _, e = find(s, '^-?%d+', i)
  if not e then fail(i, 'bad number') end
  if find(s, '^-?0%d', i) then fail(i, 'leading zero') end
  local j, float = e + 1, false
  if byte(s, j) == 46 then -- .
    _, e = find(s, '^%d+', j + 1)
    if not e then fail(j, 'bad number') end
    j, float = e + 1, true
  end
  local c = byte(s, j)
  if c == 101 or c == 69 then -- e E
    _, e = find(s, '^[-+]?%d+', j + 1)
    if not e then fail(j, 'bad number') end
    j, float = e + 1, true
  end
  local v = tonumber(sub(s, i, j - 1))
  -- an integer too large for 64 bits comes back from tonumber as a float
  if float or math.type(v) ~= 'integer' then v = v + 0.0 end
  if v ~= v or v == math.huge or v == -math.huge then fail(i, 'number out of range') end
  return v, j
end

local decode_value

local function decode_array(s, i, depth)
  local t, n = setmetatable({}, M.array_mt), 0
  i = skip_ws(s, i + 1)
  if byte(s, i) == 93 then return t, i + 1 end
  while true do
    local v
    v, i = decode_value(s, i, depth)
    n = n + 1
    t[n] = v
    i = skip_ws(s, i)
    local c = byte(s, i)
    if c == 93 then return t, i + 1 end
    if c ~= 44 then fail(i, "expected ',' or ']'") end
    i = skip_ws(s, i + 1)
  end
end

local function decode_object(s, i, depth)
  local t = {}
  i = skip_ws(s, i + 1)
  if byte(s, i) == 125 then return t, i + 1 end
  while true do
    if byte(s, i) ~= 34 then fail(i, 'expected a string key') end
    local k
    k, i = decode_string(s, i)
    i = skip_ws(s, i)
    if byte(s, i) ~= 58 then fail(i, "expected ':'") end
    local v
    v, i = decode_value(s, skip_ws(s, i + 1), depth)
    t[k] = v
    i = skip_ws(s, i)
    local c = byte(s, i)
    if c == 125 then return t, i + 1 end
    if c ~= 44 then fail(i, "expected ',' or '}'") end
    i = skip_ws(s, i + 1)
  end
end

function decode_value(s, i, depth)
  local c = byte(s, i)
  if c == 123 or c == 91 then
    if depth >= M.max_depth then fail(i, 'nested too deep') end
    if c == 123 then return decode_object(s, i, depth + 1) end
    return decode_array(s, i, depth + 1)
  elseif c == 34 then
    return decode_string(s, i)
  elseif c == 45 or (c and c >= 48 and c <= 57) then
    return decode_number(s, i)
  elseif c == 116 and sub(s, i, i + 3) == 'true' then
    return true, i + 4
  elseif c == 102 and sub(s, i, i + 4) == 'false' then
    return false, i + 5
  elseif c == 110 and sub(s, i, i + 3) == 'null' then
    return M.null, i + 4
  elseif c == nil then
    fail(i, 'unexpected end')
  end
  fail(i, 'unexpected character')
end

function M.decode(s)
  if type(s) ~= 'string' then return nil, 'not a string' end
  local ok, v, i = pcall(function()
    local v, i = decode_value(s, skip_ws(s, 1), 0)
    return v, skip_ws(s, i)
  end)
  if not ok then
    if type(v) == 'table' and v.json_error then return nil, v.json_error end
    error(v, 0)
  end
  if i <= #s then return nil, 'trailing characters at byte ' .. i end
  return v
end

-- Encoding --------------------------------------------------------------------------

local escape_map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
for c = 0, 31 do
  local k = char(c)
  if not escape_map[k] then escape_map[k] = string.format('\\u%04x', c) end
end
escape_map['\127'] = '\\u007f'

-- Valid UTF-8 as is; each byte that starts no valid character becomes U+FFFD.
local function clean_utf8(s)
  if utf8.len(s) then return s end
  local out, i = {}, 1
  while i <= #s do
    local n, bad = utf8.len(s, i)
    if n then
      out[#out + 1] = sub(s, i)
      break
    end
    out[#out + 1] = sub(s, i, bad - 1)
    out[#out + 1] = '\u{FFFD}'
    i = bad + 1
  end
  return table.concat(out)
end

local function encode_string(s)
  return '"' .. clean_utf8(s):gsub('[%c"\\]', escape_map) .. '"'
end

local function is_array(t)
  if getmetatable(t) == M.array_mt then return true end
  local n = #t
  if n == 0 then return false end
  local count = 0
  for k in pairs(t) do
    if math.type(k) ~= 'integer' or k < 1 or k > n then return false end
    count = count + 1
  end
  return count == n
end

local function enc(v, out, seen, depth)
  local tv = type(v)
  if v == nil or v == M.null then
    out[#out + 1] = 'null'
  elseif tv == 'boolean' then
    out[#out + 1] = v and 'true' or 'false'
  elseif tv == 'number' then
    if math.type(v) == 'integer' then
      out[#out + 1] = string.format('%d', v)
    else
      if v ~= v or v == math.huge or v == -math.huge then error({ json_error = 'cannot encode NaN or infinity' }, 0) end
      if v == math.floor(v) and math.abs(v) < 1e15 then
        out[#out + 1] = string.format('%.1f', v) -- 3.0 stays a float when read back
      else
        out[#out + 1] = string.format('%.17g', v)
      end
    end
  elseif tv == 'string' then
    out[#out + 1] = encode_string(v)
  elseif tv == 'table' then
    if seen[v] then error({ json_error = 'cycle' }, 0) end
    if depth >= M.max_depth then error({ json_error = 'nested too deep' }, 0) end
    seen[v] = true
    if is_array(v) then
      out[#out + 1] = '['
      for i = 1, #v do
        if i > 1 then out[#out + 1] = ',' end
        enc(v[i], out, seen, depth + 1)
      end
      out[#out + 1] = ']'
    else
      local keys = {}
      for k in pairs(v) do
        if type(k) ~= 'string' then error({ json_error = 'object key is not a string: ' .. tostring(k) }, 0) end
        keys[#keys + 1] = k
      end
      table.sort(keys)
      out[#out + 1] = '{'
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = ',' end
        out[#out + 1] = encode_string(k)
        out[#out + 1] = ':'
        enc(v[k], out, seen, depth + 1)
      end
      out[#out + 1] = '}'
    end
    seen[v] = nil
  else
    error({ json_error = 'cannot encode a ' .. tv }, 0)
  end
end

function M.encode(v)
  local out = {}
  local ok, err = pcall(enc, v, out, {}, 0)
  if not ok then
    if type(err) == 'table' and err.json_error then return nil, err.json_error end
    error(err, 0)
  end
  return table.concat(out)
end

return M
