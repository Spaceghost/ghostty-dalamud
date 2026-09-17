-- The feature vote: a web page where players pick what gets built next.
--
-- The plugin never goes online for it. The catalogue version and how many
-- ideas each version added are shipped here, matching the page's
-- version.json when this build was made; the settings window compares them
-- with the version the player last opened (saved in settings.lua) and says
-- how many ideas are new. Opening the page hands the link to the system
-- browser (ghostty.open_url) and marks this catalogue as seen.

local V = {}

V.url = 'https://spacegho.st/mods/ffxiv/term/vote/'
V.catalogue_version = 2
-- ideas added by each catalogue version (version.json "added")
V.ideas_by_version = { [1] = 51, [2] = 30 }

-- the settings.lua key holding the catalogue version last opened
V.KEY = 'vote.seen_version'

local function log(msg)
  if ghostty and ghostty.log then ghostty.log(msg) end
end

-- Catalogue version last opened, from settings values (0: never).
function V.seen(values)
  local v = tonumber(values and values[V.KEY])
  if not v or v ~= v or v < 0 then return 0 end
  return math.floor(v)
end

-- Ideas added after catalogue version `seen`, up to the shipped one.
function V.ideas_since(seen)
  local n = 0
  for v = (tonumber(seen) or 0) + 1, V.catalogue_version do
    n = n + (V.ideas_by_version[v] or 0)
  end
  return n
end

function V.unseen(values)
  return V.ideas_since(V.seen(values))
end

-- The line under the button.
function V.status_text(values)
  local seen, n = V.seen(values), V.unseen(values)
  if seen == 0 then return n .. ' ideas waiting for your vote' end
  if n == 0 then return 'No new ideas since you last looked' end
  return n .. (n == 1 and ' new idea' or ' new ideas') .. ' since you last looked'
end

-- Open the page in the system browser and remember this catalogue as seen.
-- `settings` is lua/settings.lua (values + save). True when the browser was
-- asked to open it; otherwise the link is logged and nothing is marked seen.
function V.open(settings)
  local open = ghostty and ghostty.open_url
  if not open then
    log('vote: this plugin build cannot open links; visit ' .. V.url)
    return false
  end
  local ok, why = open(V.url)
  if not ok then
    log('vote: could not open ' .. V.url .. (why and (' (' .. tostring(why) .. ')') or ''))
    return false
  end
  settings.values[V.KEY] = V.catalogue_version
  settings.save()
  return true
end

-- The "Vote on features" section of the settings window.
function V.draw(ui, settings)
  ui.wrapped('Vote on features', 0.92, 0.86, 0.72)
  ui.wrapped('Pick what gets built next. The button opens the vote page in your browser; the plugin itself never goes online.')
  local n = V.unseen(settings.values)
  if n > 0 then
    ui.wrapped(V.status_text(settings.values), 0.42, 0.80, 0.62)
  else
    ui.wrapped(V.status_text(settings.values), 0.72, 0.74, 0.78)
  end
  if ui.button('Open the vote page##vote') then V.open(settings) end
  ui.wrapped(V.url, 0.55, 0.70, 0.98)
end

return V
