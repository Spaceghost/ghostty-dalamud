-- One-time move from the Umbra-hosted layout into the GhosttyDalamud config
-- directory.
--
-- Before: ghostty_umbra.dll, lua/ and the state files lived in
-- pluginConfigs/Umbra/ghostty (or $UMBRA_GHOSTTY_HOME). Now the plugin ships
-- its own lua/ beside the DLL and keeps state in pluginConfigs/GhosttyDalamud.
--
-- Runs before init.lua on every load of the standalone plugin (always the
-- shipped copy of this file) and does nothing once migrated-from-umbra.txt
-- exists. It only copies into the new directory and never over a file that
-- is already there. The old directory is left as it was, except that its
-- ghostty_umbra.dll is renamed to ghostty_umbra.dll.migrated so a stale Umbra
-- shim cannot load a second core. To undo: rename it back.

local M = {}

M.MARKER = 'migrated-from-umbra.txt'
-- state the core and lua modules write next to lua/
M.STATE_FILES = { 'settings.lua', 'world-state.lua', 'animation-reset-done' }
-- modules users edit (init.lua carries the agent token): they become overrides
M.USER_MODULES = { ['init.lua'] = true, ['keymap.lua'] = true }

local function read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local data = f:read('a')
  f:close()
  return data
end

local function exists(path)
  local f = io.open(path, 'rb')
  if f then f:close() end
  return f ~= nil
end

-- The whole file into <dst>.tmp, then renamed into place: a crash never
-- leaves half a settings file behind. With make_private the empty temp file is
-- made owner-only before anything is written to it: init.lua may carry the
-- agent token.
local function copy(data, dst, make_private)
  local tmp = dst .. '.tmp'
  os.remove(tmp)
  local f, err = io.open(tmp, 'wb')
  if not f then return nil, err end
  if make_private then
    f:close()
    if not make_private(tmp) then os.remove(tmp) return nil, 'could not make it owner-only' end
    f, err = io.open(tmp, 'wb')
    if not f then os.remove(tmp) return nil, err end
  end
  local ok, werr = f:write(data)
  f:close()
  if not ok then os.remove(tmp) return nil, werr end
  local rok, rerr = os.rename(tmp, dst)
  if not rok then os.remove(tmp) return nil, rerr end
  return true
end

-- Where the Umbra-hosted core kept its home (before the standalone plugin).
function M.legacy_dir(o)
  local env = o.getenv('UMBRA_GHOSTTY_HOME')
  if env and env ~= '' then return env end
  if o.configs_root and o.configs_root ~= '' then return o.configs_root .. '/Umbra/ghostty' end
  return nil
end

-- opts (all optional, for tests): config, install, configs_root, getenv, log,
-- mkdir, listdir, make_private. Returns a report: status = 'migrated' | 'done-before' |
-- 'no-legacy', plus copied, overrides, quarantined, kept (already present),
-- failed, renamed.
function M.run(opts)
  local o = opts or {}
  o.config = o.config or GHOSTTY_CONFIG_DIR
  o.install = o.install or GHOSTTY_INSTALL_DIR
  o.configs_root = o.configs_root or GHOSTTY_CONFIGS_ROOT
  o.getenv = o.getenv or os.getenv
  o.log = o.log or ghostty.log
  o.mkdir = o.mkdir or ghostty.mkdir
  o.listdir = o.listdir or ghostty.listdir
  o.make_private = o.make_private or ghostty.make_private
  local r = { copied = {}, overrides = {}, quarantined = {}, kept = {}, failed = {} }

  if exists(o.config .. '/' .. M.MARKER) then r.status = 'done-before' return r end
  local legacy = M.legacy_dir(o)
  if not legacy or legacy == o.config
    or not (exists(legacy .. '/settings.lua') or exists(legacy .. '/world-state.lua') or exists(legacy .. '/lua/init.lua')) then
    r.status = 'no-legacy'
    return r
  end
  o.mkdir(o.config)

  local function take(src, dst, list, label)
    if exists(dst) then r.kept[#r.kept + 1] = label return end
    local data = read(src)
    local ok, err = false, 'unreadable'
    -- everything taken from the old home is the user's: owner-only
    if data then ok, err = copy(data, dst, o.make_private) end
    if ok then list[#list + 1] = label
    else r.failed[#r.failed + 1] = label .. ' (' .. tostring(err) .. ')' end
  end

  for _, name in ipairs(M.STATE_FILES) do
    if exists(legacy .. '/' .. name) then take(legacy .. '/' .. name, o.config .. '/' .. name, r.copied, name) end
  end

  -- lua modules that differ from what this build ships: init.lua and
  -- keymap.lua become overrides on package.path, as do modules this build does
  -- not ship at all (the user's own, which init.lua may require and which
  -- shadow nothing); an old copy of any other shipped module is kept aside in
  -- legacy-lua/ (not loaded) so it never shadows the newer one
  local names = o.listdir(legacy .. '/lua') or {}
  table.sort(names)
  for _, name in ipairs(names) do
    if name:match('%.lua$') then
      local src = legacy .. '/lua/' .. name
      local data = read(src)
      local shipped = read(o.install .. '/lua/' .. name)
      if data and data ~= shipped then
        if M.USER_MODULES[name] or not shipped then
          o.mkdir(o.config .. '/lua')
          take(src, o.config .. '/lua/' .. name, r.overrides, 'lua/' .. name)
        else
          o.mkdir(o.config .. '/legacy-lua')
          take(src, o.config .. '/legacy-lua/' .. name, r.quarantined, 'legacy-lua/' .. name)
        end
      end
    end
  end

  local dll = legacy .. '/ghostty_umbra.dll'
  if exists(dll) then
    local ok, err = os.rename(dll, dll .. '.migrated')
    r.renamed = ok and true or false
    if not ok then o.log('migrate: could not rename ' .. dll .. ': ' .. tostring(err)) end
  end

  local lines = {
    'Migrated by GhosttyDalamud from ' .. legacy .. ' on ' .. os.date('%Y-%m-%d %H:%M:%S'),
    'copied: ' .. table.concat(r.copied, ', '),
    'overrides: ' .. table.concat(r.overrides, ', '),
    'legacy-lua (not loaded): ' .. table.concat(r.quarantined, ', '),
    'already present, left alone: ' .. table.concat(r.kept, ', '),
    'failed: ' .. table.concat(r.failed, ', '),
    'ghostty_umbra.dll renamed: ' .. tostring(r.renamed or false),
    '',
  }
  -- a failed copy is retried on the next load instead of being marked done
  if #r.failed == 0 then copy(table.concat(lines, '\n'), o.config .. '/' .. M.MARKER) end

  o.log('migrated from ' .. legacy .. ': ' .. #r.copied .. ' state file(s), ' .. #r.overrides .. ' override(s)'
    .. (#r.quarantined > 0 and (', ' .. #r.quarantined .. ' old module(s) kept in legacy-lua/') or '')
    .. (#r.failed > 0 and (', FAILED: ' .. table.concat(r.failed, ', ')) or ''))
  r.status = 'migrated'
  return r
end

return M
