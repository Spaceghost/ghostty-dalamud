-- Laying out and drawing an /ask answer: a document from lua/askmd.lua (its
-- links from lua/asklinks.lua) as positioned runs of text, rules, boxes and
-- icons, word-wrapped at the panel's width.
--
-- layout() is pure: it takes a measure function, so tests/test_ask_rich.lua
-- runs it with a fake one. lua/ask.lua keeps a layout per message and width
-- and makes a new one only when the text or the width changes.
--
-- draw() only calls ghostty.ui's draw-list primitives (text_at, rect_at,
-- frame_at, line_at, icon_at): none of them pushes or begins anything in
-- ImGui, so an error half way through a message cannot leave ImGui unbalanced.

local md = require('askmd')

local M = {}

-- Chrome colours, by their index in core/theme.nelua's ChromeColor.
local C = {
  accent = 0, accent2 = 1, ok = 2, ink = 3, ink_dim = 4, ink_faint = 5, glass_top = 6, glass_bottom = 7,
  glass_flat = 8, glow = 9, panel = 10, tooltip = 11, close = 13, chip = 21, chip_hot = 22, chip_ink = 23,
}
M.C = C

-- text_at style bits (core/ui.nelua)
local BOLD, ITALIC, UNDERLINE, STRIKE = 1, 2, 4, 8
M.BOLD, M.ITALIC, M.UNDERLINE, M.STRIKE = BOLD, ITALIC, UNDERLINE, STRIKE

local LINK_COL = { url = C.accent2, thread = C.accent2, command = C.ok, followup = C.accent2 }
local function link_col(l) return LINK_COL[l.kind] or C.accent end
M.link_col = link_col

-- Game map icons shown before a link that has no icon of its own.
local ICON_FLAG, ICON_AETHERYTE = 60561, 60453
local function link_icon(l)
  if l.icon and l.icon > 0 then return l.icon end
  if l.kind == 'coord' then return ICON_FLAG end
  if l.kind == 'aetheryte' then return ICON_AETHERYTE end
  return nil
end

local HEAD = { { 1.32, C.accent }, { 1.16, C.accent }, { 1.05, C.ink }, { 1.0, C.ink_dim }, { 1.0, C.ink_dim }, { 1.0, C.ink_dim } }

-- utf8-safe pieces of `s` no wider than `w` (a word longer than the line).
local function char_split(s, w, measure, font, scale)
  local out, cur = {}, ''
  for _, cp in utf8.codes(s) do
    local ch = utf8.char(cp)
    if cur ~= '' and measure(cur .. ch, font, scale) > w then
      out[#out + 1] = cur
      cur = ch
    else
      cur = cur .. ch
    end
  end
  if cur ~= '' then out[#out + 1] = cur end
  return out
end

-- Inline layout ---------------------------------------------------------------------------
-- Spans -> lines of runs. Returns { lines = { { y =, h =, w =, runs = { run... } } }, h = }
-- where a run is { x =, text =, w =, h =, font =, scale =, col =, style =, link =, code =, icon = }.
-- opt: { x = left, w = right edge, scale =, col =, bold =, icons = bool }

local function inline_lines(spans, opt, measure, fs)
  local lines = {}
  local left, right = opt.x or 0, opt.w
  local scale = opt.scale or 1
  local line
  local x = left
  local pending, pending_text = 0, '' -- the spaces before the next word: width and text
  local function new_line()
    line = { runs = {}, h = fs * scale, w = 0 }
    lines[#lines + 1] = line
    x, pending, pending_text = left, 0, ''
  end
  new_line()
  local iconed = {}
  local function place(text, w, h, sp, style, font, col)
    local runs = line.runs
    local last = runs[#runs]
    if last and last.span == sp and not sp.code and not last.icon then
      -- the same span on the same line: one run
      last.text = last.text .. pending_text .. text
      last.w = (x + pending + w) - last.x
    else
      runs[#runs + 1] = { x = x + pending, text = text, w = w, h = h, font = font, scale = scale, col = col,
        style = style, link = sp.link, code = sp.code, span = sp }
    end
    x = x + pending + w
    pending, pending_text = 0, ''
    if h > line.h then line.h = h end
    line.w = x - left
  end
  for _, sp in ipairs(spans) do
    if sp.br then
      new_line()
    elseif sp.text ~= '' then
      local style = 0
      if sp.b or opt.bold then style = style | BOLD end
      if sp.i then style = style | ITALIC end
      if sp.s then style = style | STRIKE end
      local font = sp.code and 1 or 0
      local col = opt.col or C.ink
      if sp.code then col = C.accent2 end
      if sp.link then col = link_col(sp.link) end
      -- the icon before the first run of a game link
      local icon = sp.link and opt.icons and link_icon(sp.link)
      if icon and not iconed[sp.link] then
        iconed[sp.link] = true
        local isz = fs * scale
        if x + pending + isz + 2 > right and x > left then new_line() end
        local runs = line.runs
        runs[#runs + 1] = { x = x + pending, icon = icon, w = isz, h = isz, link = sp.link, span = sp }
        x = x + pending + isz + 3
        pending, pending_text = 0, ''
        line.w = x - left
      end
      if sp.code then
        -- one unit, broken by characters only when it is wider than a line
        local w, h = measure(sp.text, font, scale)
        local pad = 3
        if x + pending + w + 2 * pad > right and x > left then new_line() end
        if w + 2 * pad > right - left then
          for _, piece in ipairs(char_split(sp.text, right - left - 2 * pad, measure, font, scale)) do
            local pw, ph = measure(piece, font, scale)
            if x > left then new_line() end
            x = x + pad
            place(piece, pw, ph, sp, style, font, col)
            x = x + pad
          end
        else
          x = x + pad
          place(sp.text, w, h, sp, style, font, col)
          x = x + pad
        end
      else
        local text = sp.text
        local pos = 1
        while pos <= #text do
          local sa, sb = text:find('^%s+', pos)
          if sa then
            if x > left or #line.runs > 0 then
              pending = pending + measure(text:sub(sa, sb), font, scale)
              pending_text = pending_text .. text:sub(sa, sb)
            end
            pos = sb + 1
          else
            local wa, wb = text:find('^%S+', pos)
            local word = text:sub(wa, wb)
            pos = wb + 1
            local w, h = measure(word, font, scale)
            if x + pending + w > right and x > left then new_line() end
            if w > right - left then
              for _, piece in ipairs(char_split(word, right - left, measure, font, scale)) do
                local pw, ph = measure(piece, font, scale)
                if x > left then new_line() end
                place(piece, pw, ph, sp, style, font, col)
              end
            else
              place(word, w, h, sp, style, font, col)
            end
          end
        end
      end
    end
  end
  -- a trailing empty line (a final <br>) takes no room
  while #lines > 1 and #lines[#lines].runs == 0 do lines[#lines] = nil end
  return lines
end

-- Block layout ------------------------------------------------------------------------------

local Layout = {}
Layout.__index = Layout

local function new_layout(width, fs, measure, opt)
  return setmetatable({ ops = {}, hits = {}, y = 0, w = width, fs = fs, measure = measure, icons = opt and opt.icons,
    chars = 0 }, Layout)
end

function Layout:op(o)
  self.ops[#self.ops + 1] = o
  return o
end

-- Lines from inline_lines at the current y; each run becomes a text op (and a
-- hit area when it is a link). Returns the height used.
function Layout:emit_lines(lines, top, align_w, align)
  local y = top
  local gap = math.floor(self.fs * 0.22 + 0.5)
  for _, line in ipairs(lines) do
    local shift = 0
    if align_w and align == 'r' then shift = align_w - line.w
    elseif align_w and align == 'c' then shift = (align_w - line.w) / 2 end
    if shift < 0 then shift = 0 end
    for _, r in ipairs(line.runs) do
      local ry = y + (line.h - r.h) -- bottom aligned
      if r.icon then
        self:op({ op = 'icon', x0 = r.x + shift, y0 = ry, x1 = r.x + shift + r.w, y1 = ry + r.h, icon = r.icon, link = r.link, y = ry, h = r.h })
      else
        if r.code then
          self:op({ op = 'rect', x0 = r.x + shift - 3, y0 = ry - 1, x1 = r.x + shift + r.w + 3, y1 = ry + r.h + 1,
            col = C.panel, alpha = 200, rounding = 4, y = ry, h = r.h, link = r.link })
        end
        self.chars = self.chars + #r.text
        self:op({ op = 'text', x = r.x + shift, y = ry, w = r.w, h = r.h, text = r.text, font = r.font, scale = r.scale,
          col = r.col, style = r.style, link = r.link, cum = self.chars })
      end
      if r.link then
        self.hits[#self.hits + 1] = { x0 = r.x + shift - 1, y0 = ry - 1, x1 = r.x + shift + r.w + 1, y1 = ry + r.h + 1, link = r.link }
      end
    end
    y = y + line.h + gap
  end
  return y - top - (#lines > 0 and gap or 0)
end

function Layout:inline(spans, x, right, opt)
  opt = opt or {}
  opt.x, opt.w, opt.icons = x, right, self.icons
  local lines = inline_lines(spans, opt, self.measure, self.fs)
  return lines
end

function Layout:blocks(doc, x, right, col)
  local fs = self.fs
  local para_gap = math.floor(fs * 0.55 + 0.5)
  local prev
  for _, b in ipairs(doc) do
    if prev then
      local gap = para_gap
      if prev.t == 'li' and b.t == 'li' then gap = math.floor(fs * 0.2 + 0.5) end
      if b.t == 'h' then gap = math.floor(fs * 0.85 + 0.5) end
      self.y = self.y + gap
    end
    prev = b
    local t = b.t
    if t == 'p' then
      self.y = self.y + self:emit_lines(self:inline(b.inl, x, right, { col = col }), self.y)
    elseif t == 'h' then
      local h = HEAD[b.level] or HEAD[6]
      self.y = self.y + self:emit_lines(self:inline(b.inl, x, right, { scale = h[1], col = h[2], bold = true }), self.y)
      if b.level <= 2 then
        self.y = self.y + 3
        self:op({ op = 'line', x0 = x, y0 = self.y, x1 = right, y1 = self.y, col = C.ink_faint, alpha = 110, y = self.y, h = 1 })
        self.y = self.y + 1
      end
    elseif t == 'li' then
      local indent = math.floor(fs * 1.35 + 0.5)
      local lx = x + b.depth * indent
      local tx = lx + indent
      local lines = self:inline(b.inl, tx, right, { col = col })
      local first_h = lines[1] and lines[1].h or fs
      local cy = self.y + first_h / 2
      if b.marker == 'bullet' then
        local r = math.max(2, math.floor(fs * 0.16 + 0.5))
        local cx = lx + indent * 0.45
        if b.depth % 3 == 1 then
          self:op({ op = 'frame', x0 = cx - r, y0 = cy - r, x1 = cx + r, y1 = cy + r, col = C.accent, alpha = 220, rounding = r, y = cy - r, h = 2 * r })
        else
          self:op({ op = 'rect', x0 = cx - r, y0 = cy - r, x1 = cx + r, y1 = cy + r, col = C.accent, alpha = 220,
            rounding = b.depth % 3 == 0 and r or 0, y = cy - r, h = 2 * r })
        end
      elseif b.marker == 'task' or b.marker == 'done' then
        local s = math.floor(fs * 0.62 + 0.5)
        local bx = lx + indent * 0.5 - s / 2
        self:op({ op = 'frame', x0 = bx, y0 = cy - s / 2, x1 = bx + s, y1 = cy + s / 2, col = C.ink_dim, alpha = 220, rounding = 2, y = cy - s / 2, h = s })
        if b.marker == 'done' then
          self:op({ op = 'rect', x0 = bx + 3, y0 = cy - s / 2 + 3, x1 = bx + s - 3, y1 = cy + s / 2 - 3, col = C.ok, alpha = 240, rounding = 1, y = cy - s / 2, h = s })
        end
      else
        local w = self.measure(b.marker, 0, 1)
        self:op({ op = 'text', x = tx - w - 5, y = self.y + first_h - fs, w = w, h = fs, text = b.marker, font = 0, scale = 1,
          col = C.accent, style = 0 })
      end
      self.y = self.y + self:emit_lines(lines, self.y)
    elseif t == 'code' then
      self:code(b, x, right)
    elseif t == 'quote' then
      local top = self.y
      local bar = 3
      self:blocks(b.blocks, x + bar + 10, right, C.ink_dim)
      self:op({ op = 'rect', x0 = x, y0 = top, x1 = x + bar, y1 = self.y, col = C.accent, alpha = 150, rounding = 1, y = top, h = self.y - top })
    elseif t == 'table' then
      self:table(b, x, right)
    elseif t == 'hr' then
      self.y = self.y + math.floor(fs * 0.3)
      self:op({ op = 'line', x0 = x + 8, y0 = self.y, x1 = right - 8, y1 = self.y, col = C.ink_faint, alpha = 150, y = self.y, h = 1 })
      self.y = self.y + math.floor(fs * 0.3)
    end
  end
end

function Layout:code(b, x, right)
  local fs = self.fs
  local pad = 8
  local top = self.y
  local header = math.floor(fs * 0.9 + 0.5)
  local cw = self.measure('M', 1, 1)
  local lh = select(2, self.measure('M', 1, 1)) or fs
  local cols = math.max(8, math.floor((right - x - 2 * pad) / math.max(cw, 1)))
  local ops_at = #self.ops + 1
  local y = top + header + 4
  local text = b.text:gsub('\t', '    ')
  for line in (text .. '\n'):gmatch('(.-)\n') do
    local n = utf8.len(line) or #line
    if n == 0 then
      y = y + lh + 1
    else
      local i = 1
      while i <= n do
        local j = math.min(n, i + cols - 1)
        local a = utf8.offset(line, i) or 1
        local e = (utf8.offset(line, j + 1) or (#line + 1)) - 1
        local piece = line:sub(a, e)
        local w = self.measure(piece, 1, 1)
        self.chars = self.chars + #piece
        self:op({ op = 'text', x = x + pad, y = y, w = w, h = lh, text = piece, font = 1, scale = 1, col = C.accent2, style = 0, cum = self.chars })
        y = y + lh + 1
        i = j + 1
      end
    end
  end
  local bottom = y + pad - 2
  -- behind the text: the box, its header and the copy button
  table.insert(self.ops, ops_at, { op = 'rect', x0 = x, y0 = top, x1 = right, y1 = bottom, col = C.panel, alpha = 235, rounding = 6, y = top, h = bottom - top })
  table.insert(self.ops, ops_at + 1, { op = 'frame', x0 = x, y0 = top, x1 = right, y1 = bottom, col = C.ink_faint, alpha = 90, rounding = 6, y = top, h = bottom - top })
  if b.lang ~= '' then
    table.insert(self.ops, ops_at + 2, { op = 'text', x = x + pad, y = top + 3, w = self.measure(b.lang, 0, 0.85), h = fs * 0.85,
      text = b.lang, font = 0, scale = 0.85, col = C.ink_faint, style = 0 })
  end
  local label = 'copy'
  local lw = self.measure(label, 0, 0.85)
  local copy = { kind = 'copy', text = b.text }
  local cx = right - pad - lw
  self:op({ op = 'text', x = cx, y = top + 3, w = lw, h = fs * 0.85, text = label, font = 0, scale = 0.85, col = C.ink_dim, style = 0, link = copy })
  self.hits[#self.hits + 1] = { x0 = cx - 4, y0 = top, x1 = right - pad + 4, y1 = top + header + 2, link = copy }
  self.y = bottom
end

function Layout:table(b, x, right)
  local fs = self.fs
  local n = #b.head
  if n == 0 then return end
  local cpad, gap = 6, 2
  local avail = right - x - n * 2 * cpad - (n - 1) * gap
  -- natural (one line) and least (longest word) widths per column
  local nat, least = {}, {}
  local function measure_cell(k, spans, bold)
    local w = 0
    local longest = 0
    for _, sp in ipairs(spans) do
      if not sp.br and sp.text ~= '' then
        local font = sp.code and 1 or 0
        w = w + self.measure(sp.text, font, 1) + (sp.code and 6 or 0) + (sp.link and self.icons and link_icon(sp.link) and fs + 3 or 0)
        for word in sp.text:gmatch('%S+') do longest = math.max(longest, self.measure(word, font, 1)) end
      end
    end
    if bold then w = w + 2 end
    nat[k] = math.max(nat[k] or 0, w)
    least[k] = math.max(least[k] or 0, math.min(longest, avail / n))
  end
  for k = 1, n do measure_cell(k, b.head[k], true) end
  for _, row in ipairs(b.rows) do for k = 1, n do measure_cell(k, row[k] or {}, false) end end
  local widths, sum_nat, sum_least = {}, 0, 0
  for k = 1, n do
    nat[k] = math.max(nat[k], 8)
    sum_nat = sum_nat + nat[k]
    sum_least = sum_least + least[k]
  end
  if sum_nat <= avail then
    for k = 1, n do widths[k] = nat[k] end
  elseif sum_least >= avail then
    for k = 1, n do widths[k] = avail * (least[k] / math.max(sum_least, 1)) end
  else
    local extra, want = avail - sum_least, sum_nat - sum_least
    for k = 1, n do widths[k] = least[k] + extra * ((nat[k] - least[k]) / math.max(want, 1)) end
  end
  local top = self.y
  local ops_at = #self.ops + 1
  local y = top
  local total_w = 0
  for k = 1, n do total_w = total_w + widths[k] + 2 * cpad end
  total_w = total_w + (n - 1) * gap
  local function row_layout(cells, bold, shade)
    local lines_of, h = {}, fs
    local cx = x
    for k = 1, n do
      local lines = self:inline(cells[k] or {}, cx + cpad, cx + cpad + widths[k], { bold = bold })
      lines_of[k] = { lines = lines, x = cx + cpad }
      local lh = 0
      for i, l in ipairs(lines) do lh = lh + l.h + (i > 1 and math.floor(fs * 0.22 + 0.5) or 0) end
      h = math.max(h, lh)
      cx = cx + widths[k] + 2 * cpad + gap
    end
    local rt = y
    if shade then
      self:op({ op = 'rect', x0 = x, y0 = rt, x1 = x + total_w, y1 = rt + h + 8, col = shade[1], alpha = shade[2], rounding = 0, y = rt, h = h + 8 })
    end
    for k = 1, n do
      self:emit_lines(lines_of[k].lines, rt + 4, widths[k], b.align[k])
      -- emit_lines positions runs at their own x; alignment shifts inside the column
    end
    y = rt + h + 8
    self:op({ op = 'line', x0 = x, y0 = y, x1 = x + total_w, y1 = y, col = C.ink_faint, alpha = 80, y = y, h = 1 })
  end
  row_layout(b.head, true, { C.chip, 170 })
  for i, row in ipairs(b.rows) do row_layout(row, false, i % 2 == 0 and { C.glass_flat, 90 } or nil) end
  table.insert(self.ops, ops_at, { op = 'frame', x0 = x, y0 = top, x1 = x + total_w, y1 = y, col = C.ink_faint, alpha = 110, rounding = 4, y = top, h = y - top })
  self.y = y
end

-- The layout of `doc` at `width` (the width of the answer's text):
--   { h =, ops = { op... }, hits = { { x0, y0, x1, y1, link }... }, chars = }
-- extra: { sources = { url links }, followups = { questions }, copy = text,
--          icons = bool (ghostty.game_icon exists) }
function M.layout(doc, width, fs, measure, extra)
  extra = extra or {}
  local L = new_layout(width, fs, measure, extra)
  L:blocks(doc, 0, width, nil)
  local small = 0.86
  if extra.sources and #extra.sources > 0 then
    L.y = L.y + math.floor(fs * 0.7)
    L:op({ op = 'line', x0 = 0, y0 = L.y, x1 = width, y1 = L.y, col = C.ink_faint, alpha = 90, y = L.y, h = 1 })
    L.y = L.y + math.floor(fs * 0.35)
    local spans = { { text = 'Sources  ' } }
    for i, l in ipairs(extra.sources) do
      spans[#spans + 1] = { text = string.format('%d\u{a0}', i) }
      spans[#spans + 1] = { text = M.domain(l.url), link = l }
      if i < #extra.sources then spans[#spans + 1] = { text = '   ' } end
    end
    local lines = inline_lines(spans, { x = 0, w = width, scale = small, col = C.ink_faint }, measure, fs)
    L.y = L.y + L:emit_lines(lines, L.y)
  end
  if extra.followups and #extra.followups > 0 then
    L.y = L.y + math.floor(fs * 0.7)
    local x = 0
    local ch = math.floor(fs * 1.55 + 0.5)
    for _, q in ipairs(extra.followups) do
      local tw = measure(q, 0, small)
      local w = math.min(tw + 20, width)
      if x > 0 and x + w > width then
        x = 0
        L.y = L.y + ch + 6
      end
      local link = { kind = 'followup', text = q }
      L:op({ op = 'chip', x0 = x, y0 = L.y, x1 = x + w, y1 = L.y + ch, link = link, y = L.y, h = ch })
      L:op({ op = 'text', x = x + 10, y = L.y + (ch - fs * small) / 2, w = math.min(tw, w - 20), h = fs * small, text = q,
        font = 0, scale = small, col = C.ink, style = 0, link = link, clip = x + w - 8 })
      L.hits[#L.hits + 1] = { x0 = x, y0 = L.y, x1 = x + w, y1 = L.y + ch, link = link }
      x = x + w + 6
    end
    L.y = L.y + ch
  end
  L.h = L.y
  return L
end

function M.domain(url)
  return ((url:match('^%a+://([^/%?#]+)') or url):gsub('^www%.', ''))
end

-- Measuring, cached ------------------------------------------------------------------------

-- A measure function over ui.measure, remembering every word by font, scale
-- and font size (a Dalamud font change starts over).
function M.measurer(ui)
  local cache, size, count = {}, nil, 0
  return function(text, font, scale)
    font, scale = font or 0, scale or 1
    local fs = ui.font_size and ui.font_size() or 13
    if fs ~= size or count > 20000 then cache, size, count = {}, fs, 0 end
    local k = font .. ':' .. scale
    local t = cache[k]
    if not t then t = {} cache[k] = t end
    local v = t[text]
    if not v then
      local w, h = ui.measure(text, font, scale)
      v = { w or 0, h or fs * scale }
      t[text] = v
      count = count + 1
    end
    return v[1], v[2]
  end
end

-- Drawing ----------------------------------------------------------------------------------

-- The link under the pointer in layout `L` drawn at (ox, oy), or nil.
function M.hit(L, ox, oy, mx, my)
  if not mx then return nil end
  local x, y = mx - ox, my - oy
  if y < -2 or y > L.h + 2 then return nil end
  for _, h in ipairs(L.hits) do
    if x >= h.x0 and x <= h.x1 and y >= h.y0 and y <= h.y1 then return h.link end
  end
  return nil
end

-- Draw layout `L` with its top left at (ox, oy). ctx:
--   clip0, clip1   the visible band (screen y): anything outside is skipped
--   hot            the link under the pointer (every run of it lights up)
--   fade(cum)      the alpha (0..1) of text ending at character `cum` (nil: 1)
--   icon(id, x0, y0, x1, y1)   draws a game icon there (nil: no icons)
--   copied         the text last copied from a code block (its button says so)
function M.draw(ui, L, ox, oy, ctx)
  ctx = ctx or {}
  local c0, c1 = (ctx.clip0 or -1e9) - oy, (ctx.clip1 or 1e9) - oy
  local hot = ctx.hot
  for _, o in ipairs(L.ops) do
    local y, h = o.y or 0, o.h or 0
    if y + h >= c0 and y <= c1 then
      local kind = o.op
      local lit = hot ~= nil and o.link == hot
      if kind == 'text' then
        local a = 255
        if ctx.fade and o.cum then a = math.floor(255 * ctx.fade(o.cum)) end
        local style = o.style
        if o.link and lit then style = style | UNDERLINE end
        if lit and o.link.kind ~= 'copy' and o.link.kind ~= 'followup' then
          ui.rect_at(ox + o.x - 2, oy + o.y - 1, ox + o.x + o.w + 2, oy + o.y + o.h + 1, C.accent, 45, 3)
        end
        local col, text = o.col, o.text
        if o.link and o.link.kind == 'copy' then
          if lit then col = C.ink end
          if ctx.copied == o.link.text then text, col = 'copied', C.ok end
        end
        if a > 0 then ui.text_at(ox + o.x, oy + o.y, text, col, a, o.font, o.scale, style, o.clip and (ox + o.clip) or nil) end
      elseif kind == 'rect' then
        ui.rect_at(ox + o.x0, oy + o.y0, ox + o.x1, oy + o.y1, o.col, o.alpha, o.rounding or 0)
      elseif kind == 'frame' then
        ui.frame_at(ox + o.x0, oy + o.y0, ox + o.x1, oy + o.y1, o.col, o.alpha, o.rounding or 0)
      elseif kind == 'line' then
        ui.line_at(ox + o.x0, oy + o.y0, ox + o.x1, oy + o.y1, o.col, o.alpha)
      elseif kind == 'chip' then
        ui.rect_at(ox + o.x0, oy + o.y0, ox + o.x1, oy + o.y1, lit and C.chip_hot or C.chip, lit and 235 or 200, (o.y1 - o.y0) / 2)
        ui.frame_at(ox + o.x0, oy + o.y0, ox + o.x1, oy + o.y1, C.accent2, lit and 200 or 90, (o.y1 - o.y0) / 2)
      elseif kind == 'icon' then
        if ctx.icon then ctx.icon(o.icon, ox + o.x0, oy + o.y0, ox + o.x1, oy + o.y1) end
      end
    end
  end
end

-- The text of a document for the clipboard: the answer as written.
M.plain = md.to_text

return M
