-- lua/gallery.lua (run by tests/test_gallery.nelua, which provides the core's
-- ghostty table with the real listdir): watching the screenshot folder, the
-- prompt only after a terminal was on screen, the upload and its answers,
-- credit, "don't ask again" through settings.lua, /term share, signing in
-- through the site's device link, and a plugin without ghostty.http_post.
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
local posts = {} -- the sign-in's requests: { id, url, headers, type, body }
local function http_post(url, headers, ctype, path, body)
  next_id = next_id + 1
  local r = { id = next_id, url = url, headers = headers, path = path, type = ctype, body = body }
  if path then uploads[#uploads + 1] = r else posts[#posts + 1] = r end
  return next_id
end
ghostty.http_post = http_post
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
  G.token = 'gvt_linked' -- already linked (signing in: below)
  G.tick(10, true)
  local p = write('ffxiv_09192026_120000_000.jpg', 'JPEGDATA')
  assert(G.tick(12.5, true))
  frame({ 'Share##gallery_share' })
  assert(#uploads == 1 and uploads[1].path == p and uploads[1].type == 'image/jpeg')
  assert(uploads[1].headers == 'Authorization: Bearer gvt_linked' and #posts == 0, 'signed, no sign-in needed')
  assert(uploads[1].url == G.upload_url, 'no credit unless asked')
  assert(frame():find('Sharing your screenshot', 1, true) and G.tick(13, true), 'busy shows')
  G.on_upload(999, 201, '{}')
  assert(G._state.busy, 'an answer for another upload is ignored')
  G.on_upload(uploads[1].id, 201, '{"ok":true,"id":"abc","status":"pending","message":"Thanks! It shows in the gallery once it is reviewed."}')
  assert(G._state.result.ok and G._state.result.text:find('once it is reviewed', 1, true), 'the server message')
  frame({ 'Open the gallery##gallery_open' })
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

-- Signing in: a code in the prompt, the browser, polling, then the upload ------------------------
do
  local G, S = fresh()
  local CODE = '{"device_code":"dc_SECRET","user_code":"BCDF-GHJK","verification_uri":"https://spacegho.st/mods/ffxiv/term/vote/link",' ..
    '"verification_uri_complete":"https://spacegho.st/mods/ffxiv/term/vote/link?code=BCDF-GHJK","expires_in":900,"interval":5,"client_name":"Ghostty","scope":"gallery:upload"}'
  local TOKEN = '{"access_token":"gvt_SECRET","token_type":"Bearer","expires_in":15552000,"scope":"gallery:upload","token_id":"t1"}'
  local function pending() return '{"ok":false,"error":"authorization_pending","message":"Waiting for approval."}' end
  local function no_secrets(where)
    for _, m in ipairs(logged) do assert(not m:find('SECRET', 1, true), where .. ': a secret in the log: ' .. m) end
    for _, u in ipairs(opened) do assert(not u:find('SECRET', 1, true), where .. ': a secret in a link') end
    for _, r in ipairs(posts) do assert(not r.url:find('SECRET', 1, true), where .. ': a secret in an address') end
    for _, r in ipairs(uploads) do assert(not r.url:find('SECRET', 1, true), where .. ': a secret in an address') end
  end
  assert(G.token == nil and S.values['gallery.token'] == nil, 'not linked yet')
  local n_up, n_post = #uploads, #posts
  G.tick(1000, false)
  G.command('')
  local shot = G._state.offer.path
  frame({ 'Share##gallery_share' })
  assert(#uploads == n_up and #posts == n_post + 1, 'no link: a code is asked for first, nothing uploads')
  local req = posts[#posts]
  assert(req.url == G.code_url and req.type == 'application/json' and req.headers == nil)
  assert(req.body:find('"client_id":"ghostty"', 1, true) and req.body:find('"scope":"gallery:upload"', 1, true), req.body)
  assert(frame():find('Signing in to the gallery', 1, true) and G.tick(1000.5, false), 'the prompt stays up')
  G.on_upload(req.id, 200, CODE)
  assert(frame():find('Link Ghostty to your account: code BCDF-GHJK', 1, true), frame())
  assert(logged_with('Link Ghostty to your account: code BCDF-GHJK'), 'and in the log')
  assert(opened[#opened] == 'https://spacegho.st/mods/ffxiv/term/vote/link?code=BCDF-GHJK', 'the browser opens the page')

  -- polls every `interval` seconds, one at a time
  G.tick(1003, false)
  assert(#posts == n_post + 1, 'not before the interval')
  G.tick(1005.6, false)
  assert(#posts == n_post + 2 and posts[#posts].url == G.token_url, 'first poll')
  assert(posts[#posts].body:find('"device_code":"dc_SECRET"', 1, true) and posts[#posts].headers == nil, 'the code travels in the body')
  G.tick(1020, false)
  assert(#posts == n_post + 2, 'no second poll while one is out')
  G.on_upload(posts[#posts].id, 400, pending())
  G.tick(1009, false)
  assert(#posts == n_post + 2, 'pending: waits the interval again')
  G.tick(1011, false)
  assert(#posts == n_post + 3)
  G.on_upload(posts[#posts].id, 400, '{"ok":false,"error":"slow_down","message":"Slow down."}')
  G.tick(1017, false)
  assert(#posts == n_post + 3, 'slow_down: five seconds more')
  G.tick(1021.5, false)
  assert(#posts == n_post + 4)
  G.on_upload(posts[#posts].id, 0, 'No such host is known.')
  assert(G._state.link, 'no answer: keeps trying')
  G.tick(1032, false)
  assert(#posts == n_post + 5)

  -- approved: the token is kept and the waiting screenshot goes up with it
  G.on_upload(posts[#posts].id, 200, TOKEN)
  assert(G.token == 'gvt_SECRET' and S.values['gallery.token'] == 'gvt_SECRET', 'kept in settings.lua')
  assert(#uploads == n_up + 1 and uploads[#uploads].path == shot, 'the pending upload goes on')
  assert(uploads[#uploads].headers == 'Authorization: Bearer gvt_SECRET' and uploads[#uploads].url:sub(1, #G.upload_url) == G.upload_url)
  assert(not G._state.link and frame():find('Sharing your screenshot', 1, true))
  G.on_upload(uploads[#uploads].id, 201, '{"ok":true,"message":"Thanks!"}')
  assert(G._state.result.ok)
  no_secrets('linking')
  local G2 = fresh()
  assert(G2.token == 'gvt_SECRET', 'the link comes back on the next load')
  S = require('settings')
  S.reset()
  assert(S.values['gallery.token'] == 'gvt_SECRET', 'back to defaults keeps the link')

  -- 401: the link is forgotten, signed in again once, the upload retried once
  G = G2
  G.tick(2000, false)
  G.command(shot)
  frame({ 'Share##gallery_share' })
  n_post = #posts
  G.on_upload(uploads[#uploads].id, 401, '{"ok":false,"error":"token_revoked","message":"This link was revoked."}')
  assert(G.token == nil and S.values['gallery.token'] == nil, 'forgotten')
  assert(#posts == n_post + 1 and posts[#posts].url == G.code_url and G._state.link, 'signing in again')
  G.on_upload(posts[#posts].id, 200, CODE)
  G.tick(2006, false)
  G.on_upload(posts[#posts].id, 200, TOKEN)
  n_up = #uploads
  assert(uploads[n_up].path == shot and uploads[n_up].headers == 'Authorization: Bearer gvt_SECRET', 'retried with the new link')
  n_post = #posts
  G.on_upload(uploads[n_up].id, 401, '{"ok":false,"error":"invalid_token","message":"That link is not valid."}')
  assert(#posts == n_post and not G._state.link and not G._state.busy, 'a second 401: no loop')
  assert(not G._state.result.ok and G._state.result.text == 'That link is not valid.' and G.token == nil)

  -- 403: the server's words, no retry; a ban keeps the link, a missing scope drops it
  G.token = 'gvt_SECRET'
  G.command(shot)
  frame({ 'Share##gallery_share' })
  n_post, n_up = #posts, #uploads
  G.on_upload(uploads[n_up].id, 403, '{"ok":false,"error":"account_banned","message":"This account cannot upload."}')
  assert(G._state.result.text == 'This account cannot upload.' and #posts == n_post and #uploads == n_up and G.token == 'gvt_SECRET')
  G.command(shot)
  frame({ 'Share##gallery_share' })
  n_up = #uploads
  G.on_upload(uploads[n_up].id, 403, '{"ok":false,"error":"insufficient_scope","message":"This link cannot upload to the gallery."}')
  assert(G._state.result.text == 'This link cannot upload to the gallery.' and #posts == n_post and #uploads == n_up and G.token == nil)

  -- refused, run out, a refusal to give a code, Cancel: said, nothing uploads
  local ends = {
    { 400, '{"ok":false,"error":"access_denied","message":"You said no."}', 'You said no.' },
    { 400, '{"ok":false,"error":"expired_token","message":"That code ran out."}', 'That code ran out.' },
    { 400, '{"ok":false,"error":"invalid_grant"}', 'ran out' },
  }
  local at = 3000
  for _, e in ipairs(ends) do
    at = at + 100
    G.tick(at, false)
    G.command(shot)
    frame({ 'Share##gallery_share' })
    G.on_upload(posts[#posts].id, 200, CODE)
    G.tick(at + 6, false)
    n_up, n_post = #uploads, #posts
    G.on_upload(posts[#posts].id, e[1], e[2])
    assert(not G._state.link and not G._state.result.ok and G._state.result.text:find(e[3], 1, true), e[3])
    G.tick(at + 20, false)
    assert(#uploads == n_up and #posts == n_post, 'stopped')
  end
  G.tick(4000, false)
  G.command(shot)
  frame({ 'Share##gallery_share' })
  G.on_upload(posts[#posts].id, 429, '{"ok":false,"error":"slow_down","message":"Too many link codes; try again in an hour."}')
  assert(G._state.result.text == 'Too many link codes; try again in an hour.' and not G._state.link)
  G.tick(5000, false)
  G.command(shot)
  frame({ 'Share##gallery_share' })
  G.on_upload(posts[#posts].id, 200, CODE)
  n_post = #posts
  G.tick(5000 + 901, false)
  assert(not G._state.link and G._state.result.text:find('ran out', 1, true) and #posts == n_post, 'expires_in ends the polling')
  G.tick(6000, false)
  G.command(shot)
  frame({ 'Share##gallery_share' })
  G.on_upload(posts[#posts].id, 200, CODE)
  frame({ 'Cancel##gallery_link_cancel' })
  assert(not G._state.link and G._state.result.text:find('Not linked', 1, true))

  -- /term share unlink: forgotten here, ended there (the token only in the header)
  assert(G.command('unlink'):find('not linked', 1, true))
  G.token = 'gvt_SECRET'
  assert(G.command('unlink'):find('forgotten', 1, true) and G.token == nil)
  assert(posts[#posts].url == G.revoke_url and posts[#posts].headers == 'Authorization: Bearer gvt_SECRET')
  no_secrets('the rest')
  print('link OK')
end

-- A shim without http_post: the page opens instead ------------------------------------------------
do
  local G = fresh()
  ghostty.http_post = nil
  G.command('')
  frame({ 'Share##gallery_share' })
  assert(opened[#opened] == G.page and G._state.result and not G._state.result.ok)
  assert(G._state.result.text:find('cannot upload by itself', 1, true))
  ghostty.http_post = http_post
  print('without http_post OK')
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
