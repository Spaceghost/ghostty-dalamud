-- The rich /ask answer, host side (tests/run.sh runs it with vendor's Lua 5.4):
-- lua/askmd.lua's markdown, lua/asklinks.lua's links (the game faked through
-- ghostty.game_lookup / game_action), lua/askview.lua's layout at a width and
-- its drawing, and lua/ask.lua drawing answers through a fake ghostty.ui that
-- records every primitive -- hover, click, tooltips, follow-ups, copy, the
-- confirm before a command runs, and an error part way through a message.
local ROOT = ...
ROOT = ROOT or '.'
package.path = ROOT .. '/lua/?.lua;' .. package.path
local SCRATCH = os.getenv('GHOSTTY_TEST_SCRATCH') or (ROOT .. '/build/test-scratch/ask-rich')
os.execute('mkdir -p "' .. SCRATCH .. '"')
GHOSTTY_PLUGIN_DIR = SCRATCH
os.remove(SCRATCH .. '/ask-state.lua')

local md = require('askmd')
local links = require('asklinks')
local view = require('askview')

local function eq(a, b, what)
  if a ~= b then error(string.format('%s: got %s, wanted %s', what or 'value', tostring(a), tostring(b)), 2) end
end

-- Markdown ----------------------------------------------------------------------------------

do
  local d = md.parse('# Title\n## Sub\n###### six\n####### seven\nplain')
  eq(#d, 5, 'blocks')
  eq(d[1].t, 'h') eq(d[1].level, 1) eq(md.plain(d[1].inl), 'Title')
  eq(d[2].level, 2) eq(d[3].level, 6)
  eq(d[4].t, 'p', 'seven hashes are text')
  eq(d[5].t, 'p')
end

do
  local s = md.inline('a **bold** and *it* and ***both*** ~~gone~~ `co*de` x')
  local by = {}
  for _, sp in ipairs(s) do by[sp.text] = sp end
  assert(by['bold'].b and not by['bold'].i)
  assert(by['it'].i and not by['it'].b)
  assert(by['both'].b and by['both'].i)
  assert(by['gone'].s)
  assert(by['co*de'].code, 'code keeps its stars')
  eq(md.plain(s), 'a bold and it and both gone co*de x')
  -- not emphasis: snake_case, a lone star, 2 * 3 * 4, an unclosed run
  eq(md.plain(md.inline('my_var_name and 2 * 3 * 4 and **open')), 'my_var_name and 2 * 3 * 4 and **open')
  for _, sp in ipairs(md.inline('my_var_name')) do assert(not sp.i) end
  -- escapes
  eq(md.plain(md.inline('\\*not\\* \\`x\\`')), '*not* `x`')
  -- nested: a link inside bold keeps both
  local n = md.inline('**see [the docs](https://example.org/d)**')
  local l
  for _, sp in ipairs(n) do if sp.link then l = sp end end
  assert(l and l.b and l.link.url == 'https://example.org/d' and l.text == 'the docs')
end

do
  local s = md.inline('Read https://example.org/a.b). Or <https://example.org/x>, or [t](thread:T9), '
    .. 'or http://plain.example/q. And (https://en.wikipedia.org/wiki/Foo_(bar)).')
  local urls = {}
  for _, sp in ipairs(s) do if sp.link then urls[#urls + 1] = sp.link.kind .. ' ' .. (sp.link.url or sp.link.id) end end
  eq(urls[1], 'url https://example.org/a.b', 'trailing punctuation dropped')
  eq(urls[2], 'url https://example.org/x')
  eq(urls[3], 'thread T9')
  eq(urls[4], 'url http://plain.example/q', 'http is a link, which only refuses to open')
  eq(urls[5], 'url https://en.wikipedia.org/wiki/Foo_(bar)', 'balanced brackets stay')
end

do
  local d = md.parse('- one\n- two\n  - nested\n    - deeper\n- back\n\n1. first\n2) second\ncontinued\n- [ ] todo\n- [x] done')
  local kinds = {}
  for _, b in ipairs(d) do kinds[#kinds + 1] = b.t .. ':' .. (b.depth or '') .. ':' .. (b.marker or '') end
  eq(table.concat(kinds, ' '), 'li:0:bullet li:0:bullet li:1:bullet li:2:bullet li:0:bullet li:0:1. li:0:2. li:0:task li:0:done')
  eq(md.plain(d[7].inl), 'second\ncontinued', 'a continuation line stays in its item')
end

do
  local d = md.parse('Intro\n```lua\nlocal x = 1\n  indented\n```\n  ~~~\n  a\n  b\n  ~~~\n```\nstill streaming')
  eq(#d, 4)
  eq(d[2].t, 'code') eq(d[2].lang, 'lua') eq(d[2].text, 'local x = 1\n  indented') assert(d[2].closed)
  eq(d[3].text, 'a\nb', 'the fence indentation comes off')
  eq(d[4].text, 'still streaming') assert(not d[4].closed, 'unclosed while streaming')
end

do
  local d = md.parse('> quoted **text**\n> - item\n\n---\n| Name | Lv | Where |\n|:--|:-:|--:|\n| a \\| b | 1 | x |\n| c |\n\nafter')
  eq(d[1].t, 'quote') eq(d[1].blocks[1].t, 'p') eq(d[1].blocks[2].t, 'li')
  eq(d[2].t, 'hr')
  local tb = d[3]
  eq(tb.t, 'table') eq(#tb.head, 3) eq(tb.align[1], 'l') eq(tb.align[2], 'c') eq(tb.align[3], 'r')
  eq(md.plain(tb.rows[1][1]), 'a | b', 'an escaped pipe is text')
  eq(#tb.rows[2], 3, 'short rows are padded')
  eq(d[4].t, 'p')
  -- a pipe line without its delimiter row is a paragraph (a table still arriving)
  eq(md.parse('| a | b |')[1].t, 'p')
  local text = md.to_text(md.parse('# H\n- a\n```\ncode\n```'))
  eq(text, 'H\n\n- a\n\ncode')
end

-- Links -----------------------------------------------------------------------------------

-- the game, faked: what it knows, what it was asked, what it was told to do
local lookups, actions, action_result = {}, {}, 1
local pending = false
local GAME = {
  ['limsa lominsa lower decks'] = 'zone\t129\t0\tLimsa Lominsa Lower Decks\t129\t12\tLa Noscea',
  ['hi-potion'] = 'item\t4552\t20002\tHi-Potion\t0\t0\tMedicine \u{b7} iLvl 1\\nRestores HP.',
  ['alphinaud'] = 'npc\t1008888\t0\tAlphinaud\t156\t25\tMor Dhona',
  ['praetorium'] = 'duty\t16\t61801\tthe Praetorium\t0\t0\tDungeon \u{b7} Lv 50',
  ['sastasha'] = 'duty\t4\t61801\tSastasha\t0\t0\tDungeon \u{b7} Lv 15',
  ['potion'] = 'item\t4551\t20001\tPotion\t0\t0\tMedicine',
  ['swiftcast'] = 'action\t7561\t2805\tSwiftcast\t0\t0\tLv 18',
  ['it'] = 'status\t1\t0\tIt\t0\t0\t',
  ['ultimate weapon'] = 'quest\t66060\t61412\tThe Ultimate Weapon\t0\t0\tMain Scenario',
  ['aetheryte plaza'] = 'aetheryte\t8\t0\tAetheryte Plaza\t132\t2\tNew Gridania',
}
ghostty = {
  game_lookup = function(req)
    if pending then return 'pending\n' end
    local out = { 'ok' }
    for name in (req .. '\n'):gmatch('(.-)\n') do
      lookups[#lookups + 1] = name
      local k = name:lower():gsub('^the%s+', '')
      if GAME[k] then out[#out + 1] = name .. '\t' .. GAME[k] end
    end
    return table.concat(out, '\n') .. '\n'
  end,
  game_action = function(verb, arg)
    actions[#actions + 1] = verb .. ' ' .. arg
    return action_result
  end,
}

local function links_of(doc)
  local out = {}
  for _, l in ipairs(links.collect(doc)) do
    out[#out + 1] = l.kind .. ':' .. (l.name or l.url or l.text or (l.x and string.format('%.1f,%.1f', l.x, l.y)) or '?')
  end
  return table.concat(out, ' | ')
end

do
  local c = links.coords('Go to (X: 9.9, Y: 8.6), then X:10.2 Y:11.5, x9.9, y 8.6 and (21.3, 14.0) and (X: 9.9, Y: 8.6, Z: 0.1). Max 3 Y 4 no. (X: 99.0, Y: 1.0)')
  eq(#c, 5, 'coordinates found')
  eq(c[1].x, 9.9) eq(c[1].y, 8.6)
  eq(c[3].x, 9.9, 'x9.9, y 8.6')
  eq(c[4].x, 21.3, 'a bare pair in brackets')
  local z = 'Go to (X: 9.9, Y: 8.6, Z: 0.1) now'
  local zc = links.coords(z)[1]
  eq(z:sub(zc.a, zc.b), '(X: 9.9, Y: 8.6, Z: 0.1)', 'the whole of it, brackets and Z included')
end

do
  eq(links.command('/term selftest'), '/term selftest')
  eq(links.command('term selftest'), nil)
  eq(links.command('/a\nb'), nil, 'one line only')
  for _, c in ipairs({ '/say hi', '/s hi', '/p go', '/tell A B hi', '/l1 hi', '/cwl3 x', '/linkshell2 x', '/em waves', '/SH loud', '/fc hi' }) do
    assert(links.says_something(c), c)
  end
  for _, c in ipairs({ '/term selftest', '/gpose', '/echo hi', '/ask what', '/wave', '/tp' }) do
    assert(not links.says_something(c), c)
  end
end

do
  local doc = md.parse('In **Limsa Lominsa Lower Decks** at (X: 9.9, Y: 8.6) buy a Hi-Potion. Talk to Alphinaud. '
    .. 'Then run the Praetorium or `/dutyfinder`.\n\nPotion is fine. Use *Swiftcast*. It works. Sastasha is first. '
    .. 'Also [The Ultimate Weapon](https://example.org/q) and The Ultimate Weapon and Aetheryte Plaza (X: 11.0, Y: 12.3).')
  assert(links.link(doc, 0), 'every name asked about')
  eq(links_of(doc), 'zone:Limsa Lominsa Lower Decks | coord:9.9,8.6 | item:Hi-Potion | duty:the Praetorium | '
    .. 'command:/dutyfinder | action:Swiftcast | duty:Sastasha | url:https://example.org/q | quest:The Ultimate Weapon | '
    .. 'aetheryte:Aetheryte Plaza | coord:11.0,12.3')
  -- the coordinates took the zone named before them
  local coords = {}
  for _, l in ipairs(links.collect(doc)) do if l.kind == 'coord' then coords[#coords + 1] = l end end
  eq(coords[1].territory, 129) eq(coords[1].map, 12) eq(coords[1].zone, 'Limsa Lominsa Lower Decks')
  eq(coords[2].territory, 132, 'the aetheryte just before')
  -- sentence-initial "Potion", an unemphasised single-word NPC, "It": not links
  local text = links_of(doc)
  assert(not text:find('item:Potion |', 1, true) and not text:find('npc:', 1, true) and not text:find('status:', 1, true), text)
  -- the item's tooltip body carries the game's detail, line breaks restored
  local hp
  for _, l in ipairs(links.collect(doc)) do if l.name == 'Hi-Potion' then hp = l end end
  eq(hp.icon, 20002) eq(hp.detail, 'Medicine \u{b7} iLvl 1\nRestores HP.')
  -- asked once per name: a second document asks nothing new
  local asked = #lookups
  links.link(md.parse('get a Hi-Potion, then **Limsa Lominsa Lower Decks**'), 0)
  eq(#lookups, asked, 'the resolver remembers')
end

do
  -- while the game is still indexing: nothing linked, asked again after a second
  links.reset_resolver()
  pending = true
  local doc = md.parse('Buy a Hi-Potion.')
  assert(not links.link(doc, 10), 'pending')
  eq(links_of(doc), '')
  local calls = links.resolver.calls
  links.link(md.parse('Buy a Hi-Potion.'), 10.5)
  eq(links.resolver.calls, calls, 'not asked again within the second')
  pending = false
  doc = md.parse('Buy a Hi-Potion.')
  assert(links.link(doc, 11.1))
  eq(links_of(doc), 'item:Hi-Potion')
  -- no game in this build: nothing but pages and commands
  links.reset_resolver()
  local saved = ghostty.game_lookup
  ghostty.game_lookup = nil
  doc = md.parse('Buy a Hi-Potion at (X: 1.0, Y: 2.0) and run `/gpose`.')
  assert(links.link(doc, 0))
  eq(links_of(doc), 'coord:1.0,2.0 | command:/gpose')
  ghostty.game_lookup = saved
  links.reset_resolver()
end

do
  -- what a click does
  local opened, copied, confirmed, asked, threads = {}, {}, {}, {}, {}
  local ctx = {
    open_url = function(u) opened[#opened + 1] = u end,
    copy = function(t) copied[#copied + 1] = t end,
    confirm = function(c) confirmed[#confirmed + 1] = c end,
    ask = function(q, new) asked[#asked + 1] = q .. (new and ' (new)' or '') end,
    open_thread = function(id) threads[#threads + 1] = id end,
  }
  links.activate({ kind = 'url', url = 'https://example.org' }, ctx)
  eq(opened[1], 'https://example.org')
  assert(links.activate({ kind = 'url', url = 'http://example.org' }, ctx):find('Only https', 1, true))
  eq(#opened, 1, 'http never opens')
  local said = links.activate({ kind = 'coord', x = 9.9, y = 8.6, territory = 129, map = 12, zone = 'Limsa' }, ctx)
  eq(actions[#actions], 'flag 129\t12\t9.90\t8.60') assert(said:find('Flag at X 9.9, Y 8.6 in Limsa', 1, true), said)
  links.activate({ kind = 'coord', x = 1, y = 2 }, ctx)
  eq(actions[#actions], 'flag 0\t0\t1.00\t2.00', 'no zone named: where you are')
  links.activate({ kind = 'item', id = 4552, name = 'Hi-Potion' }, ctx)
  eq(actions[#actions], 'open item\t4552')
  for _, k in ipairs({ 'zone', 'aetheryte', 'quest', 'duty', 'npc' }) do
    links.activate({ kind = k, id = 7, name = 'x' }, ctx)
    eq(actions[#actions], 'open ' .. k .. '\t7')
  end
  local n = #actions
  eq(links.activate({ kind = 'action', id = 1, name = 'Sprint' }, ctx), nil, 'actions only explain themselves')
  eq(links.activate({ kind = 'status', id = 1, name = 'Weakness' }, ctx), nil)
  eq(#actions, n, 'nothing used')
  -- combat and logged out: refused by the host, said in the panel
  action_result = 2
  assert(links.activate({ kind = 'duty', id = 16, name = 'the Praetorium' }, ctx):find('combat', 1, true))
  action_result = 3
  assert(links.activate({ kind = 'coord', x = 1, y = 1 }, ctx):find('logged in', 1, true))
  action_result = 1
  -- a command: into the chat input, then a confirm; chat never runs
  said = links.activate({ kind = 'command', text = '/term selftest' }, ctx)
  eq(actions[#actions], 'chat_input /term selftest') eq(confirmed[1], '/term selftest')
  assert(said:find('Run here', 1, true))
  links.activate({ kind = 'command', text = '/say hello' }, ctx)
  eq(actions[#actions], 'chat_input /say hello') eq(#confirmed, 1, 'no Run for chat')
  local ok, err = links.run_command('/say hello')
  assert(not ok and err:find('never', 1, true))
  eq(actions[#actions], 'chat_input /say hello', 'not run')
  assert(links.run_command('/term selftest'))
  eq(actions[#actions], 'chat_run /term selftest')
  -- no chat input in this build: the clipboard instead
  local saved = ghostty.game_action
  ghostty.game_action = nil
  said = links.activate({ kind = 'command', text = '/gpose' }, ctx)
  eq(copied[1], '/gpose') assert(said:find('Copied', 1, true))
  ghostty.game_action = saved
  links.activate({ kind = 'followup', text = 'Where?' }, ctx)
  links.activate({ kind = 'followup', text = 'Why?' }, ctx, 'right')
  eq(asked[1], 'Where?') eq(asked[2], 'Why? (new)')
  links.activate({ kind = 'thread', id = 'T7' }, ctx)
  eq(threads[1], 'T7')
end

do
  -- follow-ups: the answer's own, else one per kind of thing it named, else general
  local doc = md.parse('Answer.\n\n**Follow-up questions:**\n- What about B?\n- And C?\n- not a question\n\nEnd.')
  local f = links.followups(doc)
  eq(#f, 2) eq(f[1], 'What about B?') eq(f[2], 'And C?')
  doc = md.parse('Run the Praetorium with a Hi-Potion in Limsa Lominsa Lower Decks.')
  links.link(doc, 0)
  f = links.followups(doc)
  eq(#f, 3) eq(f[1], 'How do I unlock the Praetorium?') eq(f[2], 'Where can I get Hi-Potion?')
  eq(f[3], 'What is worth doing in Limsa Lominsa Lower Decks?')
  f = links.followups(md.parse('Nothing named here.'))
  eq(#f, 2) eq(f[1], 'Can you go into more detail?')
end

-- Layout ------------------------------------------------------------------------------------

local measured = 0
local function fake_measure(text, font, scale)
  measured = measured + 1
  local per = (font == 1 and 8 or 7) * (scale or 1)
  return (utf8.len(text) or #text) * per, 16 * (scale or 1)
end

do
  local doc = md.parse('# A heading\nThe quick brown fox jumps over the lazy dog and keeps running far away.\n\n'
    .. '- item one is here\n  - nested item\n1. first\n\n> a quote\n\n```sh\necho ' .. string.rep('x', 80) .. '\n```\n\n'
    .. '| Col | Other |\n|---|--:|\n| a very long cell that must wrap somewhere | 2 |\n\n---\n'
    .. 'Averyveryverylongwordwithoutanyspacesthatcannotfitonalineatall and https://example.org/page.')
  links.link(doc, 0)
  local W = 200
  local L = view.layout(doc, W, 16, fake_measure, { sources = links.sources(doc), followups = { 'Next?', 'And then what happens after that?' } })
  assert(L.h > 0)
  for _, o in ipairs(L.ops) do
    if o.op == 'text' then
      assert(o.x >= -8 and o.x + o.w <= W + 1, string.format('"%s" at %s+%s is outside the width', o.text, o.x, o.w))
    end
  end
  -- the paragraph wrapped, the heading is bigger and bold
  local heads, body_lines = 0, {}
  for _, o in ipairs(L.ops) do
    if o.op == 'text' and o.text:find('heading', 1, true) then heads = heads + 1 assert(o.scale > 1 and o.style & view.BOLD ~= 0) end
    if o.op == 'text' and (o.text:find('fox', 1, true) or o.text:find('lazy', 1, true)) then body_lines[o.y] = true end
  end
  eq(heads, 1)
  local n = 0
  for _ in pairs(body_lines) do n = n + 1 end
  assert(n >= 2, 'the paragraph wraps onto more than one line')
  -- the code block: monospace, cut at the width, a copy button over its header
  local code_runs, copy = 0, nil
  for _, o in ipairs(L.ops) do
    if o.op == 'text' and o.font == 1 then code_runs = code_runs + 1 end
  end
  for _, h in ipairs(L.hits) do if h.link.kind == 'copy' then copy = h end end
  assert(code_runs >= 2, 'the long code line wraps')
  assert(copy and copy.link.text:find('^echo x'), 'copy takes the code')
  -- the source link and the two follow-ups are hit areas
  local kinds = {}
  for _, h in ipairs(L.hits) do kinds[h.link.kind] = (kinds[h.link.kind] or 0) + 1 end
  assert(kinds.url >= 2, 'the inline link and its source entry')
  eq(kinds.followup, 2)
  -- hit(): the pointer over the first follow-up chip
  local chip
  for _, h in ipairs(L.hits) do if h.link.kind == 'followup' then chip = h break end end
  local got = view.hit(L, 100, 50, 100 + (chip.x0 + chip.x1) / 2, 50 + (chip.y0 + chip.y1) / 2)
  eq(got, chip.link)
  eq(view.hit(L, 100, 50, 100 - 50, 50), nil)
  -- a wider panel lays out again, shorter
  local L2 = view.layout(doc, 600, 16, fake_measure, {})
  assert(L2.h < L.h)
end

do
  -- draw: only what is inside the visible band, the hot link underlined
  local calls = {}
  local ui = {
    text_at = function(x, y, t, col, a, font, scale, style) calls[#calls + 1] = { 'text', y, t, style, a } end,
    rect_at = function() calls[#calls + 1] = { 'rect' } end,
    frame_at = function() calls[#calls + 1] = { 'frame' } end,
    line_at = function() calls[#calls + 1] = { 'line' } end,
  }
  local doc = md.parse(string.rep('line of text\n\n', 40) .. 'see https://example.org/z')
  links.link(doc, 0)
  local L = view.layout(doc, 300, 16, fake_measure, {})
  view.draw(ui, L, 0, 0, {})
  local all = #calls
  calls = {}
  view.draw(ui, L, 0, 0, { clip0 = 0, clip1 = 100 })
  assert(#calls > 0 and #calls < all / 4, 'off-screen lines are skipped: ' .. #calls .. ' of ' .. all)
  local link
  for _, h in ipairs(L.hits) do link = h.link end
  calls = {}
  view.draw(ui, L, 0, 0, { hot = link })
  local underlined = false
  for _, c in ipairs(calls) do if c[1] == 'text' and c[3] == 'https://example.org/z' and c[4] & view.UNDERLINE ~= 0 then underlined = true end end
  assert(underlined, 'the hot link is underlined')
  -- fade: text arriving now is drawn faint
  calls = {}
  view.draw(ui, L, 0, 0, { fade = function(cum) return cum > L.chars - 5 and 0.2 or 1 end })
  local faint = 0
  for _, c in ipairs(calls) do if c[1] == 'text' and c[5] < 255 then faint = faint + 1 end end
  assert(faint >= 1, 'the newest text fades in')
end

-- The panel -----------------------------------------------------------------------------------

-- a recording ghostty.ui with the rich primitives: 400 px wide, a mouse you move
local rec, mouse, press = {}, { x = -1, y = -1, click = false, right = false }, {}
local text_fail = false
local copied_text
local ui = {}
local function R(kind, ...) rec[#rec + 1] = { kind, ... } end
local cursor_y = 0
ui.text = function(t) R('text', t) end
ui.wrapped = function(t) R('wrapped', t) end
ui.separator = function() end
ui.spacing = function() cursor_y = cursor_y + 4 end
ui.same_line = function() end
ui.tip = function(t) R('tip', t) end
ui.small_button = function(label) R('button', label) return press[label] == true end
ui.checkbox = function(label, v) return false, v end
ui.selectable = function(label) R('selectable', label) return press[label] == true end
ui.bubble = function(text, role) R('bubble', text, role) cursor_y = cursor_y + 20 end
ui.link = function(label, url) R('link', label, url) return press[url] == true end
ui.child = function() R('child') cursor_y = 0 return true end
ui.end_child = function(follow) R('end_child', follow) end
ui.at_bottom = function() return true end
ui.focus_next = function() end
ui.focused = function() return true end
ui.key_pressed = function() return false end
ui.input_multiline = function(_, text) return false, text, false, false end
ui.font_size = function() return 16 end
ui.measure = function(t, font, scale) return fake_measure(t, font, scale) end
ui.text_at = function(x, y, t, col, a, font, scale, style)
  if text_fail then error('text_at broke') end
  R('text_at', t, x, y, style, col)
end
ui.rect_at = function() end
ui.frame_at = function() end
ui.line_at = function() end
ui.icons = function() return true end
ui.icon_at = function(id) R('icon', id) return true end
ui.origin = function() return 0, cursor_y, 400, 0, 5000 end
ui.advance = function(h) cursor_y = cursor_y + h end
ui.mouse = function() return mouse.x, mouse.y, true, mouse.click, mouse.right end
ui.hand = function() R('hand') end
ui.copy = function(t) copied_text = t end
ui.tip_rich = function(title, body, hint, icon) R('tip_rich', title, body, hint, icon) end
ghostty.ui = ui

local spawned, opened = {}, {}
ghostty.ask_spawn = function(argv) spawned[#spawned + 1] = argv return #spawned end
ghostty.ask_cancel = function() return true end
ghostty.open_url = function(u) opened[#opened + 1] = u return true end
CONFIG = { assistant = require('assistant'), tooltips = require('tooltips') }
local M = require('ask')
CONFIG.ask = M

local function frame(now)
  rec = {}
  cursor_y = 0
  M.tick(now or 1)
  M.draw()
  press = {}
  mouse.click, mouse.right = false, false
  return rec
end
local function find(kind, pred)
  for _, r in ipairs(rec) do if r[1] == kind and (not pred or pred(r)) then return r end end
end
local function count(kind)
  local n = 0
  for _, r in ipairs(rec) do if r[1] == kind then n = n + 1 end end
  return n
end
local function line(t) return require('json').encode(t) end

M.command('where do I start?')
local job = #spawned
M.on_line(job, line({ type = 'thread', id = 'R1', title = 'where do I start?' }))
M.on_line(job, line({ type = 'text', text = '## Start\nGo to **Limsa Lominsa Lower Decks** (X: 9.9, Y: 8.6)' }))
frame(1)
assert(find('text_at', function(r) return r[2] == 'Start' end), 'the heading is drawn rich')
assert(find('icon', function(r) return r[2] == 60561 end), 'a flag icon before the coordinates')
M.on_line(job, line({ type = 'text', text = ' and buy a Hi-Potion.\n\n```\n/term selftest\n```\nRun `/term selftest`. See https://example.org/guide.' }))
M.on_line(job, line({ type = 'done', answer = '## Start\nGo to **Limsa Lominsa Lower Decks** (X: 9.9, Y: 8.6) and buy a Hi-Potion.\n\n```\n/term selftest\n```\nRun `/term selftest`. See https://example.org/guide.' }))
M.on_exit(job, 0, false)
local msgs = M.state.messages
local answer = msgs[#msgs]
measured = 0
frame(2)
local first = measured
assert(first > 0, 'laid out')
assert(find('icon', function(r) return r[2] == 20002 end), 'the item icon')
frame(2.1)
eq(measured, first, 'the same width lays out nothing again')
assert(answer.followups and #answer.followups >= 2, 'follow-ups for the finished answer')
assert(find('text_at', function(r) return r[2] == answer.followups[1] end), 'the follow-up chip is drawn')

-- hover the https link in the text: hand, tooltip, click opens it
local function at(text, col)
  local r = find('text_at', function(x) return x[2] == text and (not col or x[6] == col) end)
  assert(r, 'drawn: ' .. text)
  return r[3] + 2, r[4] + 2
end
frame(3)
mouse.x, mouse.y = at('https://example.org/guide')
frame(3.1)
assert(find('hand'), 'a hand over a link')
local t = find('tip_rich')
assert(t and t[2] == 'example.org' and t[3] == 'https://example.org/guide', 'the link in a tooltip')
assert(find('text_at', function(r) return r[2] == 'https://example.org/guide' and (r[5] & view.UNDERLINE) ~= 0 end), 'underlined')
mouse.click = true
frame(3.2)
eq(opened[#opened], 'https://example.org/guide', 'opened on click')
local n_open = #opened
frame(3.3)
eq(#opened, n_open, 'hovering again opens nothing')

-- the coordinates: a flag in the zone named before them
actions = {}
frame(4)
mouse.x, mouse.y = at('(X: 9.9, Y: 8.6)')
mouse.click = true
frame(4.1)
eq(actions[#actions], 'flag 129\t12\t9.90\t8.60')
assert(M.state.note:find('Flag at X 9.9', 1, true))

-- the command: into the chat input, and Run asks first
frame(5)
mouse.x, mouse.y = at('/term selftest', view.C.ok) -- the code span, not the code block
mouse.click = true
frame(5.1)
eq(actions[#actions], 'chat_input /term selftest')
eq(M.state.confirm, '/term selftest')
frame(5.2)
assert(find('bubble', function(r) return r[2] == 'Run /term selftest now?' end))
press['Run##ask_run'] = true
frame(5.3)
eq(actions[#actions], 'chat_run /term selftest')
eq(M.state.confirm, nil)

-- the code block's copy button
mouse.x, mouse.y = at('copy')
mouse.click = true
frame(6)
eq(copied_text, '/term selftest')
frame(6.1)
assert(find('text_at', function(r) return r[2] == 'copied' end), 'the button says so')

-- Copy in the header: the last answer as written
press['Copy##ask_copy'] = true
frame(7)
eq(copied_text, answer.text)

-- a follow-up chip asks it; right-click asks in a new thread linked back here
local fup = answer.followups[1]
frame(8)
mouse.x, mouse.y = at(fup)
mouse.click = true
frame(8.1)
eq(spawned[#spawned][#spawned[#spawned]], fup, 'the chip asked')
assert(table.concat(spawned[#spawned], ' '):find('--thread R1', 1, true), 'in this thread')
M.on_line(#spawned, line({ type = 'done', answer = 'Sure. The Praetorium is a dungeon.' }))
M.on_exit(#spawned, 0, false)
frame(9)
local chip2 = M.state.messages[#M.state.messages].followups[1]
mouse.x, mouse.y = at(chip2)
mouse.right = true
frame(9.1)
assert(table.concat(spawned[#spawned], ' '):find('--new-thread', 1, true), 'right-click: a new thread')
M.on_line(#spawned, line({ type = 'thread', id = 'R2', title = chip2 }))
eq(M.state.parents.R2.id, 'R1', 'the new thread remembers where it came from')
M.on_exit(#spawned, 0, false)
frame(10)
assert(find('link', function(r) return r[2]:find('^from: where do I start%?') end), 'a link back in the header')
-- remembered across a reload
package.loaded.ask = nil
M = require('ask')
CONFIG.ask = M
M.command('')
eq(M.state.parents.R2 and M.state.parents.R2.title, 'where do I start?')
M.on_exit(#spawned, 0, false)

-- an error while drawing an answer rich: that answer goes plain, the child still closes
M.command('new break it')
M.on_line(#spawned, line({ type = 'done', answer = 'A **bold** answer.' }))
M.on_exit(#spawned, 0, false)
text_fail = true
frame(11)
text_fail = false
local broken = M.state.messages[#M.state.messages]
assert(broken.rich_error and broken.rich_error:find('text_at broke', 1, true), 'the error is kept')
assert(find('bubble', function(r) return r[3] == 'assistant' and r[2]:find('A bold answer.', 1, true) end), 'plain instead')
eq(count('end_child'), 1, 'the child region still closes')
assert(M.state.status:find('shown plain', 1, true))
frame(12)
assert(find('bubble', function(r) return r[3] == 'assistant' end), 'and stays plain')

-- a ui without the rich primitives (an older core): the plain bubbles of before
ui.measure = nil
M.command('new plain')
M.on_line(#spawned, line({ type = 'done', answer = 'Plain **answer** at https://example.org/p.' }))
M.on_exit(#spawned, 0, false)
frame(13)
assert(find('bubble', function(r) return r[2] == 'Plain answer at https://example.org/p.' end))
assert(find('link', function(r) return r[3] == 'https://example.org/p' end))

os.remove(SCRATCH .. '/ask-state.lua')
print('test_ask_rich.lua OK')
