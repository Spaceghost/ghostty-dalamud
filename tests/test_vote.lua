-- lua/vote.lua and its place in lua/settings.lua (run by tests/test_vote.nelua,
-- which provides the core's ghostty table): the shipped catalogue, the
-- new-idea count, the settings window's vote section and badge, marking the
-- page seen through a settings.lua save and load, and a plugin without
-- ghostty.open_url.
local ROOT, SCRATCH = ...
local dir = SCRATCH .. '/vote'
assert(ghostty.mkdir(dir), 'mkdir ' .. dir)
GHOSTTY_PLUGIN_DIR = dir
package.path = ROOT .. '/lua/?.lua;' .. package.path

local logged = {}
ghostty.log = function(msg) logged[#logged + 1] = msg end
local function logged_with(text)
  for _, m in ipairs(logged) do
    if m:find(text, 1, true) then return true end
  end
  return false
end

-- settings.lua as a fresh load: modules forgotten, saved values read again
local function fresh()
  for _, m in ipairs({ 'vote', 'settings', 'changelog' }) do package.loaded[m] = nil end
  local S = require('settings')
  S.apply({})
  return S, require('vote')
end

local function exists(path)
  local f = io.open(path, 'rb')
  if f then f:close() end
  return f ~= nil
end

local settings_file = dir .. '/settings.lua'

-- The shipped catalogue --------------------------------------------------------------
do
  local _, V = fresh()
  assert(V.url == 'https://spacegho.st/mods/ffxiv/term/vote/', 'the vote page')
  assert(V.catalogue_version == 2)
  local total = 0
  for v = 1, V.catalogue_version do
    assert((V.ideas_by_version[v] or 0) > 0, 'every catalogue version up to the shipped one has its count')
    total = total + V.ideas_by_version[v]
  end
  assert(total == 81, "version.json's ideas")
  assert(V.ideas_since(0) == 81 and V.ideas_since(1) == 30 and V.ideas_since(2) == 0, 'ideas after a version')
  assert(V.ideas_since(9) == 0, 'a newer catalogue than this build knows: nothing new')
  assert(V.seen({}) == 0 and V.seen(nil) == 0, 'never opened')
  assert(V.seen({ [V.KEY] = 1 }) == 1 and V.seen({ [V.KEY] = '2' }) == 2, 'numbers and numeric strings')
  assert(V.seen({ [V.KEY] = 'junk' }) == 0 and V.seen({ [V.KEY] = -3 }) == 0 and V.seen({ [V.KEY] = 0 / 0 }) == 0, 'unusable values count as never')
  assert(V.status_text({}) == '81 ideas waiting for your vote', V.status_text({}))
  assert(V.status_text({ [V.KEY] = 1 }) == '30 new ideas since you last looked', V.status_text({ [V.KEY] = 1 }))
  assert(V.status_text({ [V.KEY] = 2 }) == 'No new ideas since you last looked')
  V.ideas_by_version[2] = 1
  assert(V.status_text({ [V.KEY] = 1 }) == '1 new idea since you last looked', 'singular')
  print('catalogue OK')
end

-- No ghostty.open_url (a shim from before it): logged, nothing marked ---------------------
do
  local S, V = fresh()
  assert(ghostty.open_url == nil)
  assert(S.badge(), 'unseen ideas: badge on')
  assert(V.open(S) == false, 'cannot open')
  assert(logged_with('cannot open links') and logged_with(V.url), 'says so, with the link')
  assert(S.values[V.KEY] == nil and S.badge() and not exists(settings_file), 'not marked seen, nothing saved')

  -- the host refusing: logged with its reason, still not seen
  ghostty.open_url = function(url) return false, 'no browser' end
  logged = {}
  assert(V.open(S) == false and logged_with('could not open') and logged_with('no browser'))
  assert(S.values[V.KEY] == nil and not exists(settings_file))
  print('without open_url OK')
end

-- Opening the page marks this catalogue seen, through settings.lua --------------------------
local opened = {}
ghostty.open_url = function(url)
  opened[#opened + 1] = url
  return true
end
do
  local S, V = fresh()
  S.values['dropdown.height'] = 0.6
  assert(V.open(S) == true)
  assert(#opened == 1 and opened[1] == V.url, 'the page, once')
  assert(S.values[V.KEY] == V.catalogue_version and not S.badge(), 'seen: badge off')
  assert(exists(settings_file), 'saved')

  local S2, V2 = fresh()
  assert(S2.values[V2.KEY] == 2 and V2.unseen(S2.values) == 0 and not S2.badge(), 'still seen after a reload')
  assert(S2.values['dropdown.height'] == 0.6, 'settings saved alongside')
  assert(V2.status_text(S2.values) == 'No new ideas since you last looked')

  -- Reset all to defaults keeps the marker: it is not a setting
  S2.reset()
  local S3, V3 = fresh()
  assert(S3.values['dropdown.height'] == nil and S3.values[V3.KEY] == 2 and not S3.badge(), 'reset keeps what was seen')
  print('seen persists OK')
end

-- A settings.lua from an older catalogue: only the new ideas count ------------------------
do
  local f = assert(io.open(settings_file, 'w'))
  f:write("return { ['vote.seen_version'] = 1 }\n")
  f:close()
  local S, V = fresh()
  assert(V.unseen(S.values) == 30 and S.badge(), 'catalogue 2 is new')
  assert(V.status_text(S.values) == '30 new ideas since you last looked')
  print('older catalogue OK')
end

-- The settings window: About tab label, the section, the button ----------------------------
do
  local S, V = fresh()
  local tabs, texts, press = {}, {}, nil
  local ui = {
    tabs = function() return true end,
    tab = function(label) tabs[#tabs + 1] = label return true end,
    end_tab = function() end, end_tabs = function() end,
    header = function() return false end,
    text = function(s) texts[#texts + 1] = s end,
    wrapped = function(s) texts[#texts + 1] = s end,
    spacing = function() end, separator = function() end, same_line = function() end,
    button = function(label) return label == press end,
  }
  ghostty.ui = ui
  local function shown(s)
    for _, t in ipairs(texts) do
      if t == s then return true end
    end
    return false
  end
  logged = {}
  S.draw()
  assert(tabs[1] == 'Settings' and tabs[3] == 'About (new)###about', 'About wears "new" while there are unseen ideas: ' .. tostring(tabs[3]))
  assert(shown('Vote on features') and shown('30 new ideas since you last looked') and shown(V.url), 'the section')
  assert(#opened == 1, 'nothing opens without a click')

  tabs, texts, press = {}, {}, 'Open the vote page##vote'
  S.draw()
  assert(#opened == 2 and opened[2] == V.url, 'the button opens the page')
  press = nil
  tabs, texts = {}, {}
  S.draw()
  assert(tabs[3] == 'About###about' and shown('No new ideas since you last looked'), 'seen on the next frame')
  assert(not logged_with('settings:'), 'no tab failed: ' .. table.concat(logged, ' / '))
  print('window OK')
end
