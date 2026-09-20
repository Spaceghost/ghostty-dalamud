-- luacheck configuration for lua/ (the plugin's policy layer) and tests/*.lua.
--   luacheck lua tests            (tools/ci/run.sh lint, docs/QUALITY.md)
--
-- The core runs these files in a Lua 5.4 state of its own and injects the
-- globals below; everything else that is read without being defined is a
-- typo, which is exactly what this catches.
std = 'lua54'

globals = {
  'CONFIG',               -- core/policy.nelua, the configuration table lua/init.lua returns
  'GHOSTTY_PLUGIN_DIR',   -- where the plugin was loaded from
  'GHOSTTY_INSTALL_DIR',  -- the directory the plugin was installed into
  'GHOSTTY_CONFIG_DIR',   -- this plugin's configuration directory
  'GHOSTTY_CONFIGS_ROOT', -- Dalamud's pluginConfigs directory (lua/migrate.lua)
  'ghostty',              -- core/world.nelua, the host API table (read, and replaced by the tests' fakes)
}

max_line_length = false  -- the tables of colours and key names read better wide

-- Unused loop and callback arguments are part of a signature the core calls;
-- an unused local, though, is a mistake.
unused_args = false
self = false

files['tests/'] = {
  -- the tests stand in for the core and build the fakes these names hold;
  -- file_mode comes from tests/test_migrate.nelua's Lua harness
  globals = { 'ghostty', 'CONFIG', 'GHOSTTY_PLUGIN_DIR', 'file_mode' },
  -- a local reused across several calls, and a loop variable shadowing an
  -- outer one, read fine in a test; an unused or undefined name never does
  ignore = { '311', '312', '411', '412', '421' },
}

exclude_files = { 'vendor', 'build', '.claude' }
