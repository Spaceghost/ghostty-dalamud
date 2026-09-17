-- Compile core/shaders/*.hlsl into the DXBC the core embeds at build time.
--
-- Not part of tools/build.sh: the .dxbc files are committed, so a normal build
-- needs no shader compiler. Run this after editing a shader:
--   vendor/nelua-lang/nelua-lua tools/build-shaders.lua
-- It uses vkd3d-compiler from a disposable Fedora container (podman), pinned
-- so the bytes only change when the source does. Nothing is installed on the host.
local IMAGE = 'registry.fedoraproject.org/fedora:44'
local PACKAGE = 'vkd3d-compiler-1.17-2.fc44'

local SHADERS = {
  { src = 'panel_depth.hlsl', out = 'panel_depth.dxbc', profile = 'ps_5_0' },
}

local root = (arg[0]:match('^(.*)/tools/[^/]*$') or '.')
local dir = root .. '/core/shaders'

-- stdout only: when the pinned package cannot be installed, dnf's stderr says why
local cmds = { 'dnf -y -q install ' .. PACKAGE .. ' >/dev/null' }
for _, s in ipairs(SHADERS) do
  cmds[#cmds + 1] = string.format('vkd3d-compiler -x hlsl -b dxbc-tpf -p %s -o /w/%s /w/%s', s.profile, s.out, s.src)
end
local cmd = string.format("podman run --rm -v '%s':/w:Z %s sh -ec '%s'", dir, IMAGE, table.concat(cmds, ' && '))
print(cmd)
local ok = os.execute(cmd)
if not ok then
  io.stderr:write('shader build failed\n')
  os.exit(1)
end
for _, s in ipairs(SHADERS) do
  local f = assert(io.open(dir .. '/' .. s.out, 'rb'))
  local data = f:read('a')
  f:close()
  assert(data:sub(1, 4) == 'DXBC', s.out .. ': not DXBC')
  print(string.format('%s: %d bytes', s.out, #data))
end
