-- Unicode paths from Lua (run by tests/test_winpath.nelua, which registers the
-- core's ghostty table): mkdir, listdir and file_size on a folder whose name is
-- not ASCII, ghostty.known_folder, and lua/gallery.lua's screenshot folder
-- precedence when the Windows profile path has non-ASCII characters in it.
local ROOT, SCRATCH = ...
package.path = ROOT .. '/lua/?.lua;' .. package.path

local NAME = 'J\xC3\xBCrgen-\xE3\x83\x97\xE3\x83\xAC\xE3\x82\xA4' -- Jürgen-プレイ, as UTF-8 bytes

-- mkdir / listdir / file_size keep the bytes -----------------------------------
local base = SCRATCH .. '/winpath'
local dir = base .. '/' .. NAME
assert(ghostty.mkdir(base) and ghostty.mkdir(dir), 'mkdir ' .. dir)
assert(ghostty.mkdir(dir), 'mkdir again on a folder that is already there')

local seen = {}
for _, n in ipairs(ghostty.listdir(base) or {}) do seen[n] = true end
assert(seen[NAME], 'listdir gives the non-ASCII name back byte for byte')

local shot = dir .. '/ffxiv_09192026_203512_123.png'
local f = assert(io.open(shot, 'wb'), 'write ' .. shot)
f:write('PNGDATA')
f:close()
assert(ghostty.file_size(shot) == 7, 'file_size through a non-ASCII folder')
assert(ghostty.file_size(shot .. '.missing') == nil, 'no size for a file that is not there')
assert(ghostty.file_size(dir) == nil, 'a folder has no size to read')

-- known_folder ----------------------------------------------------------------
local home = ghostty.known_folder('profile')
assert(type(home) == 'string' and home ~= '', 'the profile folder')
assert(ghostty.known_folder('documents') == home .. '/Documents', 'documents under it (POSIX)')
assert(ghostty.known_folder('pictures') == home .. '/Pictures', 'pictures under it (POSIX)')
assert(ghostty.known_folder('nonsense') == nil, 'only the three folders')

-- lua/gallery.lua: the folder precedence, with a non-ASCII profile -------------
local TAIL = '\\My Games\\FINAL FANTASY XIV - A Realm Reborn\\screenshots'
local PROFILE = 'C:\\Users\\' .. NAME
local G = require('gallery')
local strings, folders = {}, {}
ghostty.game_string = function(name) return strings[name] end
ghostty.known_folder = function(which)
  if which == 'profile' then return PROFILE end
  return folders[which]
end
G.folders = {}

local d = G.dirs()
assert(#d == 1 and d[1] == PROFILE .. '\\Documents' .. TAIL, 'last resort: the profile folder, ' .. d[1])
folders.documents = 'D:\\' .. NAME .. '\\Documents'
d = G.dirs()
assert(#d == 1 and d[1] == folders.documents .. TAIL, 'a moved Documents wins over the profile, ' .. d[1])
strings.user_path = PROFILE .. '\\Documents\\My Games\\FINAL FANTASY XIV - A Realm Reborn'
d = G.dirs()
assert(#d == 1 and d[1] == strings.user_path .. '\\screenshots', 'the game user folder wins, ' .. d[1])
strings.screenshot_dir = 'E:\\' .. NAME .. '\\shots'
d = G.dirs()
assert(#d == 1 and d[1] == strings.screenshot_dir, 'the game setting wins over everything, ' .. d[1])

-- an older core has neither function: the folder falls back to USERPROFILE
-- (unset on the host, so no last-resort folder) and file_size to io.open
ghostty.known_folder, ghostty.file_size = nil, nil
strings.screenshot_dir, strings.user_path = nil, nil
local up = os.getenv('USERPROFILE')
d = G.dirs()
assert(#d == ((up and up ~= '') and 1 or 0), 'without known_folder: USERPROFILE')
print('winpath OK')
