-- lua/gallery.lua (run by tests/test_gallery.nelua, which provides the core's
-- ghostty table with the real listdir): watching the screenshot folder, the
-- prompt only after a terminal was on screen, the upload and its answers,
-- credit, "don't ask again" through settings.lua, /term share, and a plugin
-- without ghostty.http_upload.
local ROOT, SCRATCH = ...
local dir = SCRATCH .. '/gallery'
local shots = dir .. '/screenshots'
assert(ghostty.mkdir(dir) and ghostty.mkdir(shots), 'mkdir ' .. shots)
GHOSTTY_PLUGIN_DIR = dir
package.path = ROOT .. '/lua/?.lua;' .. package.path
os.remove(dir .. '/settings.lua')
for _, name in ipairs(ghostty.listdir(shots) or {}) do os.remove(shots .. '/' .. name) end

local logged = {}
ghostty.log = function(msg) logged[#logged + 1] = msg end
local function logged_with(text)
  for _, m in ipairs(logged) do if m:find(text, 1, true) then return true end end
  return false
end

local function write(name, bytes)
  local f = assert(io.open(shots .. '/' .. name, 'wb'))
  f:write(bytes or 'PNGDATA')
  f:close()
  return shots .. '/' .. name
end

local strings = { screenshot_dir = shots, player = 'Wyn Ghostty@Gilgamesh' }
ghostty.game_string = function(name) return strings[name] end
local uploads, opened = {}, {}
local next_id = 0
ghostty.http_upload = function(url, path, ctype)
  next_id = next_id + 1
  uploads[#uploads + 1] = { id = next_id, url = url, path = path, type = ctype }
  return next_id
end
ghostty.open_url = function(url) opened[#opened + 1] = url return true end

-- a scripted ghostty.ui: `press` names the button labels to click this frame
local press, drawn = {}, {}
ghostty.ui = {
  wrapped = function(t) drawn[#drawn + 1] = t end,
  text = function(t) drawn[#drawn + 1] = t end,
  button = function(label) drawn[#drawn + 1] = '[' .. label .. ']' return press[label] == true end,
  checkbox = function(label, v) drawn[#drawn + 1] = '[x] ' .. label if press[label] then return true, not v end return false, v end,
  same_line = function() end,
  spacing = function() end,
  separator = function() end,
}
local function frame(clicks)
  press, drawn = {}, {}
  for _, c in ipairs(clicks or {}) do press[c] = true end
  require('gallery').draw()
  return table.concat(drawn, '\n')
end

local function fresh()
  for _, m in ipairs({ 'gallery', 'settings', 'vote', 'changelog' }) do package.loaded[m] = nil end
  local S = require('settings')
  local config = S.apply({ gallery = require('gallery') })
  return require('gallery'), S, config
end

-- Paths, types and names ----------------------------------------------------------------
do
  local G = fresh()
  assert(G.page == 'https://spacegho.st/mods/ffxiv/term/gallery/' and G.upload_url == G.page .. 'api/upload')
  assert(G.type_of('a.PNG') == 'image/png' and G.type_of('b.jpg') == 'image/jpeg' and G.type_of('c.JPEG') == 'image/jpeg')
  local t, why = G.type_of('d.bmp')
  assert(t == nil and why == 'bmp' and G.type_of('e.txt') == nil and G.type_of('png') == nil)
  assert(G.join([[C:\Users\me\shots\]], 'a.png') == [[C:\Users\me\shots\a.png]] and G.join('/tmp/x/', 'a.png') == '/tmp/x/a.png')
  assert(G.basename([[C:\a\b\ffxiv_1.png]]) == 'ffxiv_1.png' and G.basename('/a/b.jpg') == 'b.jpg')
  assert(G.name_key('ffxiv_09192026_203512_123.png') == '20260919203512123', 'the game names shots month-day-year')
  assert(G.name_key('ffxiv_12312025_235959_999.png') < G.name_key('ffxiv_01012026_000000_000.png'), 'across a new year')
  assert(G.name_key('ffxiv_dx11 2026-09-19 20-35-12.png') == '20260919203512000' and G.name_key('shot.png') == nil)

  -- the folder: the game's setting, else the user folder's screenshots, else Documents, plus extras
  strings.screenshot_dir = nil
  strings.user_path = [[C:\Users\me\Documents\My Games\FINAL FANTASY XIV - A Realm Reborn]]
  G.folders = { '/extra/', [[C:\Users\me\Documents\My Games\FINAL FANTASY XIV - A Realm Reborn\screenshots]] }
  local d = G.dirs()
  assert(#d == 2 and d[1] == [[C:\Users\me\Documents\My Games\FINAL FANTASY XIV - A Realm Reborn\screenshots]] and d[2] == '/extra', table.concat(d, ' | '))
  strings.user_path = nil
  G.folders = {}
  strings.screenshot_dir = shots
  assert(#G.dirs() == 1 and G.dirs()[1] == shots)
  print('paths OK')
end

-- The prompt: only new images, only with a terminal on screen (or just before) ------------
do
  local G = fresh()
  write('ffxiv_09182026_100000_000.png') -- already there: never offered
  assert(G.tick(100, false) == false and #G.dirs() == 1, 'no terminal on screen: nothing')
  write('ffxiv_09192026_100000_000.png') -- taken with no terminal around
  assert(G.tick(101, true) == false, 'first look: whatever is there is only remembered')
  assert(G.tick(102, true) == false, 'polls every couple of seconds')
  local p = write('ffxiv_09192026_100500_000.png')
  assert(G.tick(103.5, false) == true, 'new shot, terminal on screen a moment ago: offered')
  assert(G._state.offer.path == p and not G._state.offer.problem)
  local out = frame()
  assert(out:find('Share to the Ghostty gallery?', 1, true) and out:find('ffxiv_09192026_100500_000.png', 1, true))
  assert(out:find('shown publicly in the gallery after review', 1, true), 'consent line')
  assert(out:find('Credit it to Wyn Ghostty@Gilgamesh', 1, true), 'credit offered with the character')
  assert(#uploads == 0, 'nothing uploads without a click')
  frame({ 'Not now##gallery_later' })
  assert(G.tick(104, false) == false and #uploads == 0, 'not now: gone, nothing sent')

  -- a pause without any terminal: shots meanwhile are not offered when one shows again
  write('ffxiv_09192026_110000_000.png')
  assert(G.tick(300, false) == false, 'no terminal for minutes: not even looked')
  assert(G.tick(301, true) == false, 'terminal back: the shot from meanwhile is only remembered')
  print('prompt OK')
end

-- Share: upload, credit, answers ---------------------------------------------------------
do
  local G, S = fresh()
  G.tick(10, true)
  local p = write('ffxiv_09192026_120000_000.jpg', 'JPEGDATA')
  assert(G.tick(12.5, true))
  frame({ 'Share##gallery_share' })
  assert(#uploads == 1 and uploads[1].path == p and uploads[1].type == 'image/jpeg')
  assert(uploads[1].url == G.upload_url, 'no credit unless asked')
  assert(frame():find('Sharing your screenshot', 1, true) and G.tick(13, true), 'busy shows')
  G.on_upload(999, 201, '{}')
  assert(G._state.busy, 'an answer for another upload is ignored')
  G.on_upload(uploads[1].id, 201, '{"ok":true,"id":"abc","status":"pending","message":"Thanks! It shows in the gallery once it is reviewed."}')
  assert(G._state.result.ok and G._state.result.text:find('once it is reviewed', 1, true), 'the server message')
  local out = frame({ 'Open the gallery##gallery_open' })
  assert(opened[#opened] == G.page, 'open the gallery from the result')
  assert(G.tick(14, true) and not G.tick(40, true), 'the result goes away by itself')

  -- credit: ticked in the prompt, saved, sent as Name @ World
  G.command('')
  frame({ 'Credit it to Wyn Ghostty@Gilgamesh##gallery_credit' })
  assert(G.credit == true and S.values['gallery.credit'] == true)
  frame({ 'Share##gallery_share' })
  assert(uploads[2].url == G.upload_url .. '?credit=Wyn%20Ghostty%20%40%20Gilgamesh', uploads[2].url)
  G.on_upload(uploads[2].id, 200, '{"ok":true,"duplicate":true,"message":"This screenshot was already shared. Thank you!"}')
  assert(G._state.result.ok and G._state.result.text:find('already shared', 1, true))

  -- failures say why
  local answers = {
    { 429, '{"ok":false,"error":"rate_limited","message":"That is a lot of screenshots at once; try again later."}', 'a lot of screenshots' },
    { 0, 'No such host is known.', 'Could not reach the gallery' },
    { -1, 'The process cannot access the file', 'Could not read the screenshot' },
    { 502, '<html>bad gateway</html>', 'answered 502' },
  }
  for _, a in ipairs(answers) do
    G.command('')
    frame({ 'Share##gallery_share' })
    G.on_upload(uploads[#uploads].id, a[1], a[2])
    assert(G._state.result and not G._state.result.ok and G._state.result.text:find(a[3], 1, true), a[3])
    frame({ 'Close##gallery_close' })
    assert(not G._state.result)
  end
  print('share OK')
end

-- Too large, BMP, and "don't ask again" -------------------------------------------------------
do
  local G, S = fresh()
  G.tick(10, true)
  write('ffxiv_09192026_130000_000.png', string.rep('x', G.max_bytes + 1))
  assert(G.tick(12.5, true))
  assert(frame():find('over the gallery', 1, true) and not frame():find('[Share##gallery_share]', 1, true), 'too large: said, no Share')
  frame({ 'Close##gallery_close' })
  write('ffxiv_09192026_130100_000.bmp')
  assert(G.tick(15, true) == false and logged_with('BMP'), 'BMP: logged once, no prompt')

  write('ffxiv_09192026_130200_000.png')
  assert(G.tick(17.5, true))
  frame({ 'Don\'t ask again##gallery_never' })
  assert(G.prompt == false and S.values['gallery.prompt'] == false, 'saved off')
  write('ffxiv_09192026_130300_000.png')
  assert(G.tick(20, true) == false, 'no more prompts')

  -- saved settings come back on the next load
  local G2, _, config = fresh()
  assert(config.gallery == G2 and G2.prompt == false and G2.credit == true, 'settings.lua keeps both')
  assert(G2.command('on'):find('will offer', 1, true) and G2.prompt == true)
  print('limits OK')
end

-- /term share -------------------------------------------------------------------------------
do
  local G = fresh()
  local msg = G.command('')
  assert(msg:find('ffxiv_09192026_130300_000.png', 1, true), 'latest by the date in its name (not the BMP): ' .. msg)
  assert(G._state.offer and G.tick(1, false), 'the prompt shows without a terminal on screen')
  assert(G.command('gallery'):find(G.page, 1, true) and opened[#opened] == G.page)
  local other = write('mine.png')
  assert(G.command(other):find('mine.png', 1, true) and G._state.offer.path == other, 'a path of your own')
  assert(G.command('off'):find('no more prompts', 1, true) and G.prompt == false)
  strings.screenshot_dir = dir .. '/empty'
  assert(ghostty.mkdir(dir .. '/empty'))
  local G2 = fresh()
  assert(G2.command(''):find('no screenshots found in ' .. dir .. '/empty', 1, true))
  strings.screenshot_dir = shots
  print('command OK')
end

-- A shim without http_upload: the page opens instead ---------------------------------------------
do
  local G = fresh()
  ghostty.http_upload = nil
  G.command('')
  frame({ 'Share##gallery_share' })
  assert(opened[#opened] == G.page and G._state.result and not G._state.result.ok)
  assert(G._state.result.text:find('cannot upload by itself', 1, true))
  print('without http_upload OK')
end

-- The settings window: the Gallery section, and the About tab's buttons ------------------------
do
  local G, S = fresh()
  local found = {}
  for _, section in ipairs(S.schema) do
    for _, e in ipairs(section[2]) do found[e[1]] = section[1] end
  end
  assert(found['gallery.prompt'] == 'Gallery' and found['gallery.credit'] == 'Gallery')
  local tips = require('tooltips')
  assert(tips.settings['gallery.prompt'] and tips.settings['gallery.credit'] and tips.sections['Gallery'])
  press, drawn = {}, {}
  press['Share my latest screenshot##gallery_latest'] = true
  require('changelog').draw_about(ghostty.ui, S)
  assert(table.concat(drawn, '\n'):find('Share a screenshot', 1, true) and G._state.offer, 'About: share the latest')
  print('settings OK')
end
