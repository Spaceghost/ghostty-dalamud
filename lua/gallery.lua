-- The screenshot gallery: share a screenshot of Ghostty in the game with one click.
--
-- Take a normal screenshot with the game's screenshot key while a terminal is
-- on screen (or was, in the last minute). The plugin sees the new file in the
-- game's screenshot folder and shows a small prompt, "Share to the Ghostty
-- gallery?"; Share uploads that one image to the gallery on spacegho.st, where
-- it waits for the site owner's review before anyone can see it. Nothing is
-- ever uploaded without that click. /term share offers your latest screenshot
-- at any time; the About tab in Settings has the same button.
--
-- The gallery takes uploads from signed-in accounts only. The first Share
-- links the plugin to your account: the prompt shows a short code and your
-- browser opens the page that asks for it; once you approve there, the upload
-- goes on by itself. The link is kept in settings.lua (gallery.token), is never
-- logged and never part of an address; /term share unlink forgets it.
--
-- The core calls, every frame: tick(now, shown) -> true while the prompt is
-- drawn, then draw() inside the prompt window; on_upload(id, status, text)
-- when a request finished; command(args) for /term share. Uploading needs
-- ghostty.http_post (the plugin's shim does the HTTPS POSTs); without it the
-- gallery page opens in the browser instead, where the file can be picked.

local G = {}

G.page = 'https://spacegho.st/mods/ffxiv/term/gallery/'
G.upload_url = G.page .. 'api/upload'

-- Signing in (the site's device link): a code from code_url, approved in the
-- browser, then token_url answers with the token the upload carries.
G.link_api = 'https://spacegho.st/mods/ffxiv/term/vote/api/'
G.code_url = G.link_api .. 'device/code'
G.token_url = G.link_api .. 'device/token'
G.revoke_url = G.link_api .. 'token/revoke'
G.client_id = 'ghostty'
G.scope = 'gallery:upload'
G.token = nil -- saved as gallery.token once linked; never logged, never in a URL

-- Settings (lua/settings.lua saves them as gallery.prompt and gallery.credit).
G.prompt = true   -- offer new screenshots taken while a terminal is on screen
G.credit = false  -- credit the shot to your character ("Name@World")

-- Extra folders to watch besides the game's own screenshot folder, e.g.
--   gallery.folders = { [[C:\Users\me\Pictures\FFXIV]] }
G.folders = {}

G.max_bytes = 8 * 1024 * 1024 -- what the gallery accepts
G.poll_seconds = 2            -- how often the folders are listed while watching
G.recent_seconds = 60         -- a terminal on screen this recently still counts
G.offer_seconds = 90          -- the prompt tidies itself away after this long
G.result_seconds = 10         -- how long "Shared!" stays up

local TYPES = { png = 'image/png', jpg = 'image/jpeg', jpeg = 'image/jpeg' }

local state = {
  known = {},       -- dir -> { name -> order first seen (0: there before we looked) }
  seq = 0,
  last_scan = -1e9,
  last_shown = -1e9,
  now = 0,
  offer = nil,      -- { path, name, problem, at }
  busy = nil,       -- { id, path, name, at, relinked }
  link = nil,       -- signing in: { path, relinked, id, device_code, user_code, uri, page, interval, next_at, deadline }
  result = nil,     -- { ok, text, until_at }
  bmp_logged = false,
}
G._state = state -- tests

local function log(msg)
  if ghostty and ghostty.log then ghostty.log('gallery: ' .. msg) end
end

local function game_string(name)
  local f = ghostty and ghostty.game_string
  if not f then return nil end
  local ok, v = pcall(f, name)
  if ok and type(v) == 'string' and v ~= '' then return v end
  return nil
end

-- A Windows known folder (or its POSIX stand-in) as UTF-8, from the core:
-- Lua's own os.getenv hands back the active code page's bytes, which mangles a
-- user name it cannot spell. Nil on an older core without the function.
local function known_folder(which)
  local f = ghostty and ghostty.known_folder
  if not f then return nil end
  local ok, v = pcall(f, which)
  if ok and type(v) == 'string' and v ~= '' then return v end
  return nil
end

-- Paths ----------------------------------------------------------------------

local function sep_of(dir) return dir:find('\\', 1, true) and '\\' or '/' end
local function trim_dir(dir) return (dir:gsub('[\\/]+$', '')) end
function G.join(dir, name) return trim_dir(dir) .. sep_of(dir) .. name end
function G.basename(path) return path:match('([^\\/]+)$') or path end

-- image/png, image/jpeg, or nil and why not
function G.type_of(name)
  local ext = (name:match('%.([%w]+)$') or ''):lower()
  if TYPES[ext] then return TYPES[ext] end
  if ext == 'bmp' then return nil, 'bmp' end
  return nil
end

-- The folders to watch: the game's screenshot folder setting, else the
-- screenshots folder in the game's user folder (FFXIV.cfg lives there), else
-- the usual Documents path; then CONFIG.gallery.folders.
function G.dirs()
  local out, seen = {}, {}
  local function add(d)
    if type(d) ~= 'string' or d == '' then return end
    d = trim_dir(d)
    if not seen[d:lower()] then seen[d:lower()] = true out[#out + 1] = d end
  end
  local setting = game_string('screenshot_dir')
  if setting then
    add(setting)
  else
    local user = game_string('user_path')
    if user then
      add(G.join(user, 'screenshots'))
    else
      local tail = '\\My Games\\FINAL FANTASY XIV - A Realm Reborn\\screenshots'
      local docs = known_folder('documents') -- the shell knows a moved Documents
      if docs then
        add(docs .. tail)
      else
        local home = known_folder('profile') or os.getenv('USERPROFILE')
        if home and home ~= '' then add(home .. '\\Documents' .. tail) end
      end
    end
  end
  for _, d in ipairs(type(G.folders) == 'table' and G.folders or {}) do add(d) end
  return out
end

-- A sortable time from the file name, when it has one: the game names shots
-- like ffxiv_09192026_203512_123.png (month, day, year); others put the year
-- first. Nil when the name carries no date.
function G.name_key(name)
  local mo, d, y, h, mi, s, ms = name:match('(%d%d)(%d%d)(%d%d%d%d)_(%d%d)(%d%d)(%d%d)_?(%d*)')
  if mo and tonumber(mo) >= 1 and tonumber(mo) <= 12 and tonumber(y) >= 2000 then
    return y .. mo .. d .. h .. mi .. s .. string.format('%03d', tonumber(ms ~= '' and ms or '0') or 0)
  end
  y, mo, d, h, mi, s = name:match('(%d%d%d%d)[-_]?(%d%d)[-_]?(%d%d)[ _T-]?(%d%d)[-_.]?(%d%d)[-_.]?(%d%d)')
  if y and tonumber(y) >= 2000 then return y .. mo .. d .. h .. mi .. s .. '000' end
  return nil
end

-- The core answers this one (a wide stat on Windows, so a non-ASCII path still
-- has a size); io.open is the fallback for an older core, where fopen is ANSI.
local function file_size(path)
  local f = ghostty and ghostty.file_size
  if f then
    local ok, n = pcall(f, path)
    if ok then return type(n) == 'number' and n or nil end
  end
  local h = io.open(path, 'rb')
  if not h then return nil end
  local n = h:seek('end')
  h:close()
  return n
end

-- Why a file cannot be shared, or nil.
local function problem_of(path)
  local t, why = G.type_of(path)
  if not t then
    if why == 'bmp' then return 'BMP screenshots cannot be shared; pick PNG or JPG in the game\'s System Configuration.' end
    return 'Only PNG and JPEG screenshots can be shared.'
  end
  local n = file_size(path)
  if not n then return 'The screenshot could not be read.' end
  if n > G.max_bytes then return string.format('%.1f MB is over the gallery\'s 8 MB; JPG screenshots are much smaller.', n / 1048576) end
  return nil
end

-- Watching -------------------------------------------------------------------

-- Newest first: the date in the name, else the order seen, else the name.
local function sort_key(name, order)
  local k = G.name_key(name)
  return (k and ('1' .. k) or '0') .. string.format('%09d', order) .. name
end

-- List every watched folder. Files already there when a folder is first listed
-- (or when watching resumes after a pause) are only remembered; a new image
-- becomes the offer. Returns the newest new image path, if any. Per folder
-- only names are kept, and a name already known costs one table lookup, so a
-- folder of thousands of shots stays cheap to list every couple of seconds.
function G.scan(silent)
  local list = ghostty and ghostty.listdir
  if not list then return nil end
  local newest, newest_key
  for _, dir in ipairs(G.dirs()) do
    local names = list(dir)
    if names then
      local known = state.known[dir]
      local first = known == nil
      if first then known = {} state.known[dir] = known end
      for _, name in ipairs(names) do
        if known[name] == nil then
          local t, why = G.type_of(name)
          if not (t or why == 'bmp') then
            known[name] = false -- not an image: never looked at again
          elseif first or silent then
            known[name] = 0
          else
            state.seq = state.seq + 1
            known[name] = state.seq
            if t then
              local key = sort_key(name, state.seq)
              if not newest_key or key > newest_key then newest, newest_key = G.join(dir, name), key end
            elseif not state.bmp_logged then
              state.bmp_logged = true
              log('your screenshots are BMP files, which the gallery cannot take; choose PNG or JPG in the game\'s System Configuration')
            end
          end
        end
      end
    end
  end
  return newest
end

-- The most recent screenshot in the watched folders.
function G.latest()
  G.scan(true)
  local best, best_key
  for _, dir in ipairs(G.dirs()) do
    for name, order in pairs(state.known[dir] or {}) do
      if order and G.type_of(name) then
        local key = sort_key(name, order)
        if not best_key or key > best_key then best, best_key = G.join(dir, name), key end
      end
    end
  end
  return best
end

function G.offer(path, now)
  state.offer = { path = path, name = G.basename(path), problem = problem_of(path), at = now or state.now }
  state.result = nil
end

-- Per frame from the core. `shown`: a terminal (dropdown, window or world
-- screen) is on screen. True while the prompt should be drawn.
function G.tick(now, shown)
  state.now = now
  if shown then state.last_shown = now end
  if state.offer and now - state.offer.at > G.offer_seconds then state.offer = nil end
  if state.result and now > state.result.until_at then state.result = nil end
  G.poll_link(now)
  if G.prompt and now - state.last_shown <= G.recent_seconds and now - state.last_scan >= G.poll_seconds then
    -- after a pause (no terminal for a while) whatever arrived meanwhile is not offered
    local resumed = now - state.last_scan > G.recent_seconds + G.poll_seconds
    state.last_scan = now
    local path = G.scan(resumed)
    -- a shot too large to share still shows, with why (once per shot); BMP only logs
    if path and not state.busy and not state.link then G.offer(path, now) end
  end
  return G.visible()
end

function G.visible()
  return state.offer ~= nil or state.busy ~= nil or state.link ~= nil or state.result ~= nil
end

-- Settings -------------------------------------------------------------------

local function save(key, value)
  G[key] = value
  local ok, S = pcall(require, 'settings')
  if ok and type(S) == 'table' and S.values and S.save then
    S.values['gallery.' .. key] = value
    S.save()
  end
end

function G.set_prompt(on) save('prompt', on and true or false) end
function G.set_credit(on) save('credit', on and true or false) end

-- Sharing --------------------------------------------------------------------

local function urlencode(s)
  return (s:gsub('[^%w%-_%.~]', function(c) return string.format('%%%02X', c:byte()) end))
end

local function finish(ok, text)
  state.busy = nil
  state.link = nil
  state.offer = nil
  state.result = { ok = ok, text = text, until_at = state.now + G.result_seconds * (ok and 1 or 2) }
  log(text)
end

function G.open_page()
  local open = ghostty and ghostty.open_url
  if open and open(G.page) then return true end
  log('open ' .. G.page .. ' in your browser')
  return false
end

local function has_token() return type(G.token) == 'string' and G.token ~= '' end

-- The answer's JSON as a table ({} when it is not JSON, or was cut short).
local function decode(text)
  local ok, json = pcall(require, 'json')
  if ok and type(text) == 'string' and text:sub(1, 1) == '{' then
    local v = json.decode(text)
    if type(v) == 'table' then return v end
  end
  return {}
end

local function encode(t)
  local ok, json = pcall(require, 'json')
  if not ok then return nil end
  local done, s = pcall(json.encode, t)
  return done and type(s) == 'string' and s or nil
end

-- The upload itself, signed with the link's token.
local function upload(path, relinked)
  local url = G.upload_url
  local player = G.credit and game_string('player')
  if player then url = url .. '?credit=' .. urlencode(player:gsub('@', ' @ ')) end
  local id, why = ghostty.http_post(url, 'Authorization: Bearer ' .. G.token, G.type_of(path), path)
  if not id then finish(false, 'Could not start the upload: ' .. tostring(why)) return false end
  state.busy = { id = id, path = path, name = G.basename(path), at = state.now, relinked = relinked }
  state.offer = nil
  state.link = nil
  return true
end

-- Sign in, then upload `path`: ask the site for a code. The answer (on_upload)
-- shows it and opens the browser; tick polls until the player approved.
local function link(path, relinked)
  local body = encode({ client_id = G.client_id, scope = G.scope })
  local id, why
  if body then id, why = ghostty.http_post(G.code_url, nil, 'application/json', nil, body) end
  if not id then finish(false, 'Could not start signing in: ' .. tostring(why or 'lua/json.lua is missing')) return false end
  state.link = { path = path, relinked = relinked, id = id, at = state.now }
  state.busy = nil
  state.offer = nil
  return true
end

-- Upload `path` now, signing in first when there is no link yet. True once
-- something is on its way; the answers arrive in on_upload.
function G.share(path)
  if state.busy or state.link then return false end
  local problem = problem_of(path)
  if problem then finish(false, problem) return false end
  if not (ghostty and ghostty.http_post) then
    G.open_page()
    finish(false, 'This plugin build cannot upload by itself; the gallery page opened, pick ' .. G.basename(path) .. ' there.')
    return false
  end
  if has_token() then return upload(path, false) end
  return link(path, false)
end

-- While signing in: ask whether the player approved yet, every `interval`
-- seconds, until the code runs out. One request at a time.
function G.poll_link(now)
  local l = state.link
  if not l or l.id or not l.device_code then return end
  if now > l.deadline then finish(false, 'The link code ran out before it was approved. Share again for a new one.') return end
  if now < l.next_at then return end
  local body = encode({ client_id = G.client_id, device_code = l.device_code })
  local id = body and ghostty and ghostty.http_post and ghostty.http_post(G.token_url, nil, 'application/json', nil, body)
  if id then l.id = id end
  l.next_at = now + l.interval -- also when it could not be sent: try again then
end

-- The site's answer to the code request.
local function on_code(l, status, v)
  if status ~= 200 then
    if status == 0 then finish(false, 'Could not reach the gallery to sign in. Try again later.') return end
    finish(false, v.message or ('Signing in answered ' .. tostring(status) .. '.'))
    return
  end
  if type(v.device_code) ~= 'string' or type(v.user_code) ~= 'string' then
    finish(false, 'Signing in gave an answer this plugin cannot read; update the plugin.')
    return
  end
  l.device_code, l.user_code = v.device_code, v.user_code
  l.uri = type(v.verification_uri_complete) == 'string' and v.verification_uri_complete or v.verification_uri
  l.page = type(v.verification_uri) == 'string' and v.verification_uri or l.uri
  l.interval = math.max(tonumber(v.interval) or 5, 1)
  l.deadline = state.now + (tonumber(v.expires_in) or 900)
  l.next_at = state.now + l.interval
  local open = ghostty and ghostty.open_url
  l.opened = type(l.uri) == 'string' and open ~= nil and open(l.uri) == true
  log('Link Ghostty to your account: code ' .. l.user_code .. (l.opened and ' (your browser opened)' or (' at ' .. tostring(l.page))))
end

-- The site's answer to one poll.
local function on_token(l, status, v)
  if status == 200 and type(v.access_token) == 'string' and v.access_token ~= '' then
    save('token', v.access_token)
    log('linked to your account')
    upload(l.path, l.relinked)
    return
  end
  local err = v.error
  if err == 'access_denied' or err == 'expired_token' or err == 'invalid_grant' or err == 'invalid_client' then
    finish(false, v.message or (err == 'access_denied' and 'The link was refused.' or 'The link code ran out. Share again for a new one.'))
  elseif status == 200 then
    finish(false, 'Signing in gave an answer this plugin cannot read; update the plugin.')
  elseif err == 'slow_down' or status == 429 then
    l.interval = l.interval + 5
    l.next_at = state.now + l.interval
  end
  -- authorization_pending, no answer, a server error: the next poll asks again
end

-- /term share unlink: forget the link here and tell the site to end it.
function G.unlink()
  if not has_token() then return false end
  local token = G.token
  save('token', nil)
  if ghostty and ghostty.http_post then ghostty.http_post(G.revoke_url, 'Authorization: Bearer ' .. token, 'application/json', nil, '{}') end
  return true
end

local RELINK = { invalid_token = true, token_revoked = true, token_expired = true, sign_in_required = true }

-- The shim's answer: HTTP status (0 no answer, -1 the file could not be
-- read) and the start of the response body. Answers while signing in are
-- never logged: they carry the link.
function G.on_upload(id, status, text)
  local l = state.link
  if l and l.id == id then
    l.id = nil
    if l.device_code then on_token(l, status, decode(text)) else on_code(l, status, decode(text)) end
    return
  end
  if not state.busy or state.busy.id ~= id then return end
  local v = decode(text)
  local message = type(v.message) == 'string' and v.message or nil
  if status == 401 and (RELINK[v.error] or v.error == nil) then
    -- the link is no longer good: forget it, sign in again and send the shot once more, once
    local b = state.busy
    save('token', nil)
    if b.relinked then finish(false, message or 'The gallery did not accept the new link. Try again later.') return end
    log(message or 'the link to your account is no longer good; signing in again')
    link(b.path, true)
    return
  end
  if status == 403 then
    -- banned, or a link without the gallery's permission: say so, never retry by itself
    if v.error == 'insufficient_scope' then save('token', nil) end
    finish(false, message or 'The gallery refused this upload (403).')
    return
  end
  if status == 200 or status == 201 then
    finish(true, message or 'Shared! It shows in the gallery once it is reviewed.')
  elseif status == 0 then
    finish(false, 'Could not reach the gallery (' .. tostring(text) .. '). Try again later.')
  elseif status == -1 then
    finish(false, 'Could not read the screenshot (' .. tostring(text) .. ').')
  else
    finish(false, message or ('The gallery answered ' .. tostring(status) .. '.'))
  end
end

-- The prompt ---------------------------------------------------------------------

function G.draw()
  local ui = ghostty and ghostty.ui
  if not ui then return end
  if state.busy then
    ui.wrapped('Sharing your screenshot...', 0.92, 0.86, 0.72)
    ui.wrapped(state.busy.name, 0.62, 0.66, 0.74)
    return
  end
  local l = state.link
  if l then
    if not l.user_code then
      ui.wrapped('Signing in to the gallery...', 0.92, 0.86, 0.72)
    else
      ui.wrapped('Link Ghostty to your account: code ' .. l.user_code, 0.92, 0.86, 0.72)
      ui.wrapped((l.opened and 'Your browser opened the page; ' or ('Open ' .. tostring(l.page) .. ' and enter the code; ')) ..
        'sign in there and approve Ghostty. The screenshot is shared as soon as you do.', 0.62, 0.66, 0.74)
      if ui.button('Open the page again##gallery_link_open') then
        local open = ghostty and ghostty.open_url
        if not (open and type(l.uri) == 'string' and open(l.uri)) then log('open ' .. tostring(l.page) .. ' in your browser') end
      end
      ui.same_line()
    end
    if ui.button('Cancel##gallery_link_cancel') then finish(false, 'Not linked; nothing was shared.') end
    return
  end
  if state.result then
    local r = state.result
    if r.ok then ui.wrapped(r.text, 0.42, 0.80, 0.62) else ui.wrapped(r.text, 0.94, 0.62, 0.52) end
    if r.ok then
      if ui.button('Open the gallery##gallery_open') then G.open_page() end
      ui.same_line()
    end
    if ui.button('Close##gallery_close') then state.result = nil end
    return
  end
  local o = state.offer
  if not o then return end
  ui.wrapped('Share to the Ghostty gallery?', 0.92, 0.86, 0.72)
  ui.wrapped(o.name, 0.62, 0.66, 0.74)
  if o.problem then
    ui.wrapped(o.problem, 0.94, 0.62, 0.52)
    if ui.button('Close##gallery_close') then state.offer = nil end
    return
  end
  local player = game_string('player')
  if player then
    local changed, v = ui.checkbox('Credit it to ' .. player .. '##gallery_credit', G.credit)
    if changed then G.set_credit(v) end
  end
  ui.wrapped('Uploads this image to spacegho.st; it is shown publicly in the gallery after review.', 0.62, 0.66, 0.74)
  if ui.button('Share##gallery_share') then G.share(o.path) return end
  ui.same_line()
  if ui.button('Not now##gallery_later') then state.offer = nil return end
  ui.same_line()
  if ui.button('Don\'t ask again##gallery_never') then
    state.offer = nil
    G.set_prompt(false)
    log('no more prompts; /term share still offers your latest screenshot, and Settings, Gallery turns them back on')
  end
end

-- The About tab's section (lua/changelog.lua).
function G.draw_about(ui)
  ui.wrapped('Share a screenshot', 0.92, 0.86, 0.72)
  ui.wrapped('Take a screenshot with the game\'s screenshot key while a terminal is on screen and the plugin asks whether to share it to the gallery. Nothing is uploaded until you click Share, and the site owner reviews every shot before it is shown.')
  ui.wrapped('The game\'s own screenshot key photographs the scene before the plugin draws, so a terminal is not in it; /term shot (the shutter button in the dropdown) takes one that has the terminals in it and offers it here at once.', 0.62, 0.66, 0.74)
  if ui.button('Share my latest screenshot##gallery_latest') then G.command('') end
  ui.same_line()
  if ui.button('Open the gallery##gallery_page') then G.open_page() end
  ui.wrapped(G.page, 0.55, 0.70, 0.98)
end

-- /term share [on|off|gallery|unlink|<path>] -> a line for the chat.
function G.command(args)
  args = (args or ''):match('^%s*(.-)%s*$')
  local word = args:lower()
  if word == 'on' or word == 'off' then
    G.set_prompt(word == 'on')
    return word == 'on' and 'gallery: new screenshots taken with a terminal on screen will offer to be shared'
      or 'gallery: no more prompts; /term share still offers your latest screenshot'
  elseif word == 'gallery' or word == 'page' or word == 'open' then
    G.open_page()
    return 'gallery: ' .. G.page
  elseif word == 'unlink' or word == 'signout' then
    return G.unlink() and 'gallery: the link to your account is forgotten; the next Share asks for a new one'
      or 'gallery: not linked to an account'
  end
  local path = args ~= '' and args or G.latest()
  if not path then
    local dirs = G.dirs()
    return 'gallery: no screenshots found' .. (#dirs > 0 and (' in ' .. table.concat(dirs, ', ')) or '') ..
      '; take one with the game\'s screenshot key first'
  end
  G.offer(path, state.now)
  return 'gallery: share ' .. G.basename(path) .. '? The prompt is on screen.'
end

return G
