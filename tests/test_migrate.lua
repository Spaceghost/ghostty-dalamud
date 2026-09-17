-- lua/migrate.lua against scratch directories (run by tests/test_migrate.nelua,
-- which provides ghostty.mkdir / ghostty.listdir / ghostty.make_private and
-- file_mode(path) -> '644').
local ROOT, SCRATCH = ...
local M = dofile(ROOT .. '/lua/migrate.lua')

local function write(path, data)
  local f = assert(io.open(path, 'wb'))
  f:write(data)
  f:close()
end

local function read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local data = f:read('a')
  f:close()
  return data
end

local function mkdirs(...)
  for _, d in ipairs({ ... }) do assert(ghostty.mkdir(d), 'mkdir ' .. d) end
end

-- every file below `dir`: relative path -> contents
local function snapshot(dir, prefix, out)
  out = out or {}
  for _, name in ipairs(ghostty.listdir(dir) or {}) do
    local p = dir .. '/' .. name
    if ghostty.listdir(p) then snapshot(p, (prefix or '') .. name .. '/', out)
    else out[(prefix or '') .. name] = read(p) end
  end
  return out
end

local base = SCRATCH .. '/migrate'
local install = base .. '/install'
local root = base .. '/pluginConfigs'
local legacy = root .. '/Umbra/ghostty'
local config = root .. '/GhosttyDalamud'
mkdirs(base, install, install .. '/lua', root, root .. '/Umbra', legacy, legacy .. '/lua', config)

-- what this build ships
write(install .. '/lua/init.lua', 'shipped init')
write(install .. '/lua/keymap.lua', 'shipped keymap')
write(install .. '/lua/world.lua', 'shipped world')
write(install .. '/lua/changelog.lua', 'shipped changelog')

-- the Umbra-hosted install
write(legacy .. '/ghostty_umbra.dll', 'MZ old core')
write(legacy .. '/settings.lua', 'return { ["dropdown.height"] = 0.6 }')
write(legacy .. '/world-state.lua', 'return { old = true }')
write(legacy .. '/animation-reset-done', 'done')
write(legacy .. '/notes.txt', 'not ours')
write(legacy .. '/lua/init.lua', "local bell = require('bell') -- shipped init, with agent.token")  -- edited: becomes an override
write(legacy .. '/lua/keymap.lua', 'shipped keymap')                -- unchanged: nothing to carry
write(legacy .. '/lua/world.lua', 'old world')                      -- stale module: set aside
write(legacy .. '/lua/changelog.lua', 'shipped changelog')          -- unchanged
write(legacy .. '/lua/bell.lua', 'return "a module of my own"')    -- not shipped: loadable override
-- already in the new home
write(config .. '/world-state.lua', 'return { newer = true }')

local before = snapshot(legacy)
local logs = {}
local opts = {
  install = install, config = config, configs_root = root,
  getenv = function() return nil end,
  log = function(m) logs[#logs + 1] = m end,
}
local r = M.run(opts)
assert(r.status == 'migrated', r.status)
assert(#r.failed == 0, table.concat(r.failed, ', '))

assert(read(config .. '/settings.lua') == before['settings.lua'], 'settings copied')
assert(read(config .. '/animation-reset-done') == 'done', 'marker copied')
assert(read(config .. '/world-state.lua') == 'return { newer = true }', 'a file already present is never overwritten')
assert(read(config .. '/lua/init.lua') == before['lua/init.lua'], 'edited init.lua becomes an override')
assert(file_mode(legacy .. '/lua/init.lua') ~= '600' and file_mode(config .. '/lua/init.lua') == '600', 'copies are owner-only')
assert(file_mode(config .. '/settings.lua') == '600' and file_mode(config .. '/lua/bell.lua') == '600')
assert(read(config .. '/lua/keymap.lua') == nil, 'unchanged modules are not copied')
assert(read(config .. '/legacy-lua/world.lua') == 'old world', 'stale module set aside')
assert(read(config .. '/lua/world.lua') == nil, 'set-aside modules are not on package.path')
assert(read(config .. '/lua/bell.lua') == before['lua/bell.lua'] and read(config .. '/legacy-lua/bell.lua') == nil,
  'a module the build does not ship shadows nothing and stays loadable')
-- the override init.lua finds it through the config directory, as in game
local saved_path, saved_bell = package.path, package.loaded.bell
package.path = config .. '/lua/?.lua;' .. install .. '/lua/?.lua'
package.loaded.bell = nil
assert(load(read(config .. '/lua/init.lua')))()
assert(package.loaded.bell == 'a module of my own', 'override init.lua loads its own modules')
package.path, package.loaded.bell = saved_path, saved_bell
assert(read(config .. '/legacy-lua/changelog.lua') == nil, 'identical modules are not set aside')
assert(r.renamed, 'old core renamed')
assert(read(legacy .. '/ghostty_umbra.dll') == nil and read(legacy .. '/ghostty_umbra.dll.migrated') == 'MZ old core')

-- the legacy tree is otherwise byte for byte what it was
local after = snapshot(legacy)
before['ghostty_umbra.dll.migrated'], before['ghostty_umbra.dll'] = before['ghostty_umbra.dll'], nil
for k, v in pairs(before) do assert(after[k] == v, 'legacy file changed: ' .. k) end
for k in pairs(after) do assert(before[k] ~= nil, 'legacy file added: ' .. k) end

for k in pairs(snapshot(config)) do assert(not k:match('%.tmp$'), 'temp file left behind: ' .. k) end
local marker = read(config .. '/' .. M.MARKER)
assert(marker and marker:find(legacy, 1, true), 'marker names the source')
assert(#logs == 1 and logs[1]:find('migrated from', 1, true), 'one summary line')
for _, m in ipairs(logs) do assert(not m:find('with agent', 1, true), 'file contents are never logged') end

-- a copy that cannot be made owner-only is never written, and the run is retried
local config3 = base .. '/config3'
local r4 = M.run({
  install = install, config = config3, configs_root = root, getenv = opts.getenv, log = opts.log,
  make_private = function() return nil end,
})
assert(r4.status == 'migrated' and #r4.failed > 0, 'failed copies are reported')
assert(read(config3 .. '/lua/init.lua') == nil and read(config3 .. '/lua/init.lua.tmp') == nil, 'no world-readable token left behind')
assert(read(config3 .. '/' .. M.MARKER) == nil, 'no marker after a failed copy')

-- idempotent: the marker stops a second run, even when the old files change
write(legacy .. '/settings.lua', 'changed afterwards')
local r2 = M.run(opts)
assert(r2.status == 'done-before', r2.status)
assert(read(config .. '/settings.lua') == before['settings.lua'])

-- UMBRA_GHOSTTY_HOME wins over configs_root; a home without our files is no legacy
local empty = base .. '/empty'
local config2 = base .. '/config2'
mkdirs(empty)
local r3 = M.run({
  install = install, config = config2, configs_root = root, log = opts.log,
  getenv = function(k) return k == 'UMBRA_GHOSTTY_HOME' and empty or nil end,
})
assert(r3.status == 'no-legacy', r3.status)
assert(read(config2 .. '/' .. M.MARKER) == nil, 'nothing to migrate leaves no marker')
assert(M.run({ install = install, config = config2, configs_root = '', getenv = opts.getenv }).status == 'no-legacy')
assert(M.legacy_dir({ getenv = function() return 'C:\\games\\ghostty' end, configs_root = root }) == 'C:\\games\\ghostty')

print('migrate OK')
