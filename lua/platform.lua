-- Defaults that depend on where the game runs: the agent's token file and the
-- terminal profiles. lua/init.lua takes them from here; a copy of init.lua in
-- the config directory can keep them or write its own tables.
--
-- ghostty.platform() says where the core runs:
--   'windows'  native Windows (XIVLauncher on Windows)
--   'wine'     the Windows build under Wine or Proton (XIVLauncher.Core on Linux)
--   'linux', 'macos', 'posix'  a host build (the tests)
local M = {}

function M.name()
  if type(ghostty) == 'table' and type(ghostty.platform) == 'function' then return ghostty.platform() end
  return 'unknown'
end

-- The ghostty-agent connection and profiles for `platform`. `getenv` reads
-- environment variables (os.getenv; the tests pass their own).
--
-- Native Windows: ghostty-agent.exe runs on the same machine and its token is
-- in %APPDATA%\ghostty-agent\token. Its shells outlive the game. While no
-- agent answers, the agent profiles open their `fallback`, a local ConPTY
-- shell inside the game process that closes with the game.
--
-- Everywhere else (Wine/Proton on Linux, and host builds): the Linux/macOS
-- ghostty-agent with its token in ~/.config/ghostty-agent/token, plus ConPTY
-- profiles, exactly as before this module existed.
function M.defaults(platform, getenv)
  getenv = getenv or os.getenv
  if platform == 'windows' then
    local appdata = getenv('APPDATA')
    if not appdata or appdata == '' then appdata = (getenv('USERPROFILE') or '') .. '\\AppData\\Roaming' end
    return {
      agent = {
        host = '127.0.0.1',
        port = 7777,
        token = '',
        token_file = appdata .. '\\ghostty-agent\\token',
      },
      profiles = {
        { name = 'powershell', transport = 'agent', command = { 'powershell.exe', '-NoLogo' }, fallback = 'powershell (local)' },
        { name = 'cmd',        transport = 'agent', command = { 'cmd.exe' },                   fallback = 'cmd (local)' },
        { name = 'powershell (local)', transport = 'conpty', command = { 'powershell.exe', '-NoLogo' } },
        { name = 'cmd (local)',        transport = 'conpty', command = { 'cmd.exe' } },
        -- PowerShell 7, when installed:
        -- { name = 'pwsh', transport = 'agent', command = { 'pwsh.exe', '-NoLogo' }, fallback = 'powershell (local)' },
        -- ssh is a command like any other:
        -- { name = 'ssh', transport = 'agent', command = { 'ssh.exe', 'user@example-host' } },
      },
    }
  end
  local home = getenv('HOME') or getenv('USERPROFILE') or ''
  return {
    agent = {
      host = '127.0.0.1',
      port = 7777,
      token = '',
      token_file = home .. '/.config/ghostty-agent/token',
    },
    profiles = {
      -- /bin/sh is the one shell a POSIX agent host is guaranteed to have, so
      -- it is what opens on first run; bash is the next profile for anyone who
      -- wants a login shell.
      { name = 'shell',      transport = 'agent',  command = { '/bin/sh' } },
      { name = 'bash',       transport = 'agent',  command = { '/bin/bash', '-l' } },
      { name = 'tmux',       transport = 'agent',  command = { 'tmux', 'new-session', '-A', '-s', 'ghostty' } },
      { name = 'powershell', transport = 'conpty', command = { 'pwsh.exe', '-NoLogo' } },
      { name = 'cmd',        transport = 'conpty', command = { 'cmd.exe' } },
      -- ssh is a command like any other, through either transport:
      -- { name = 'ssh',       transport = 'agent',  command = { 'ssh', '-t', 'user@example-host' } },
      -- { name = 'ssh (win)', transport = 'conpty', command = { 'ssh.exe', 'user@example-host' } },
    },
  }
end

return M
