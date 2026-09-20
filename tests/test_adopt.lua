-- lua/adopt.lua (run by tests/test_adopt.nelua): names resolved to ImGui
-- windows or the game's chat, pet sizes, the pulled list saved and read back
-- (and not read back with restore off), chat colours.
local ROOT, SCRATCH = ...
local dir = SCRATCH .. '/adopt'
assert(ghostty.mkdir(dir), 'mkdir ' .. dir)
GHOSTTY_PLUGIN_DIR = dir
os.remove(dir .. '/adopted.lua')
package.path = ROOT .. '/lua/?.lua;' .. package.path

local world = require('world')
local adopt = require('adopt')

-- names
local kind, title, plugin, label = adopt.resolve('chat2')
assert(kind == 'imgui' and title == '###chat2' and plugin == 'ChatTwo' and label == 'Chat 2', 'ChatTwo by its short name')
kind, title = adopt.resolve('ChatTwo')
assert(kind == 'imgui' and title == '###chat2', 'names are case-insensitive')
kind, title, plugin, label = adopt.resolve('chat')
assert(kind == 'native' and label == 'Chat', 'the game\'s chat')
assert(adopt.resolve('chatlog') == 'native', 'chatlog too')
kind, title, plugin, label = adopt.resolve('Some Window##x')
assert(kind == 'imgui' and title == 'Some Window##x' and plugin == '' and label == 'Some Window', 'any title as it is')
local k, why = adopt.resolve('')
assert(k == nil and why:find('usage', 1, true), 'empty name refused')

-- sizes: window * scale + chrome, with the pet's own scale and opacity
world.anchors[5] = { kind = 'pet' }
adopt.size(5, 400, 300, 20, 44)
local a = world.anchors[5]
assert(a.width == 400 * adopt.scale + 20 and a.height == 300 * adopt.scale + 44, 'panel = window * scale + chrome')
assert(a.pixels_per_yalm == adopt.pixels_per_yalm and a.opacity == adopt.opacity, 'the pet\'s scale')
adopt.size(5, 100000, 100000, 0, 0)
assert(a.width == 5200 and a.height == 3600, 'clamped')
adopt.size(99, 400, 300, 0, 0) -- no such panel: nothing happens

-- the pulled list
assert(adopt.saved() == '', 'nothing saved yet')
adopt.save('chat2\nchat\nWeird "name"\n')
assert(adopt.saved() == 'chat2\nchat\nWeird "name"', 'read back in order')
adopt.save('')
assert(adopt.saved() == '', 'emptied')
adopt.save('chat2\n')
adopt.restore = false
assert(adopt.saved() == '', 'restore off: nothing comes back')
adopt.restore = true
-- a broken file is ignored
local f = io.open(dir .. '/adopted.lua', 'w') f:write('return {') f:close()
assert(adopt.saved() == '', 'a broken file reads as nothing')

-- chat colours
local key, rgb = adopt.chat_colour(10)
assert(key == 'ColorSay' and rgb == 0xf7f7f7, 'say')
key, rgb = adopt.chat_colour(14)
assert(key == 'ColorParty', 'party')
key, rgb = adopt.chat_colour(200)
assert(key == '' and rgb == 0xdddddd, 'unknown channel: the default')
adopt.chat.use_game_colours = false
key, rgb = adopt.chat_colour(10)
assert(key == '' and rgb == 0xf7f7f7, 'game colours off: built-in only')
print('lua adopt OK')
