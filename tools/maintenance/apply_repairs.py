#!/usr/bin/env python3
"""Apply reviewed release-readiness repairs to the inspected source tree."""
from pathlib import Path

ROOT = Path.cwd()


def patch(path, old, new, count=1):
    p = ROOT / path
    text = p.read_text()
    found = text.count(old)
    if found != count:
        raise RuntimeError(f'{path}: expected {count} patch anchors, found {found}')
    p.write_text(text.replace(old, new))


def write(path, text, executable=False):
    p = ROOT / path
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)
    if executable:
        p.chmod(0o755)


write('tools/build-common.sh', r'''#!/usr/bin/env bash
# Shared build helpers. Callers provide ROOT; this file does not change cwd.
CC="${CC:-gcc}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1)}"
case "$JOBS" in ''|*[!0-9]*|0) JOBS=1 ;; esac
require_linux_build_host() {
  [[ "$(uname -s)" == Linux ]] || {
    echo 'The full plugin build currently requires Linux. macOS agent support is experimental; use tools/build-agent.sh.' >&2
    return 2
  }
}
build_nelua() {
  # nelua is a tracked executable launcher, not evidence of a built compiler.
  command -v "$CC" >/dev/null || { echo "C compiler not found: $CC" >&2; return 127; }
  make -C "$ROOT/vendor/nelua-lang" -j"$JOBS" CC="$CC"
  [[ -x "$ROOT/vendor/nelua-lang/nelua-lua" ]] || {
    echo 'Nelua build did not produce nelua-lua.' >&2; return 1;
  }
}
''', True)
patch('tools/build.sh', 'cd "$ROOT"\n', 'cd "$ROOT"\nsource "$ROOT/tools/build-common.sh"\nrequire_linux_build_host\n')
patch('tools/build.sh', '  [[ -x "$NELUA" ]] || make -C vendor/nelua-lang -j"$(nproc)" >/dev/null', '  build_nelua')
patch('tools/build.sh', '--cc gcc', '--cc "$CC"')
patch('tools/build.sh', ';; esac; cc -O2', ';; esac; "$CC" -O2')
patch('tools/build.sh', 'DD="${DALAMUD_LIB_PATH:-$HOME/.cache/dalamud-dev}"', 'DD="${DALAMUD_LIB_PATH:-$ROOT/vendor/dalamud}"')
patch('tools/build.sh', 'INC="-I$ROOT/vendor/ghostty/include -I$ROOT/vendor/gc-cimgui -I$ROOT/vendor/lua/src"', 'INC="-I\\\"$ROOT/vendor/ghostty/include\\\" -I\\\"$ROOT/vendor/gc-cimgui\\\" -I\\\"$ROOT/vendor/lua/src\\\""')
patch('tools/build.sh', '-L$ROOT/build/win/lib -L$ROOT/build/lua-win', '-L\\"$ROOT/build/win/lib\\" -L\\"$ROOT/build/lua-win\\"', 2)
patch('tools/build.sh', 'if [[ "$("$ZIG" version)" != "$ZIG_VERSION" ]]; then echo "warning: zig $("$ZIG" version) found, toolchain.env pins $ZIG_VERSION"; fi', 'if [[ "$("$ZIG" version)" != "$ZIG_VERSION" ]]; then echo "error: this build requires Zig $ZIG_VERSION; set ZIG to the matching binary" >&2; exit 2; fi')
patch('tools/build.sh', 'echo "== ghostty-agent (host)"', '[[ -x "$ROOT/vendor/nelua-lang/nelua-lua" ]] || { echo "Nelua is not built; rerun without SKIP_DEPS=1" >&2; exit 1; }\necho "== ghostty-agent (host)"')

patch('toolchain.env', 'DALAMUD_DISTRIB_URL=https://goatcorp.github.io/dalamud-distrib/latest.zip', '''# Immutable reference bundle; the Git blob digest is checked before extraction.
DALAMUD_DISTRIB_COMMIT=46833da369fb1fec8942fe2a108e866b69cf6ce3
DALAMUD_DISTRIB_URL=https://raw.githubusercontent.com/goatcorp/dalamud-distrib/46833da369fb1fec8942fe2a108e866b69cf6ce3/latest.zip
DALAMUD_DISTRIB_BLOB_SHA1=f8c81f20cb85b20c551a1d19a834430156863fa9''')
p = ROOT / 'tools/fetch-vendor.sh'
s = p.read_text()
anchor = '# Dalamud reference assemblies (for compiling the C# shim only).'
assert s.count(anchor) == 1
s = s[:s.index(anchor)] + '''# Reference assemblies are pinned independently of the installed game runtime.
if [[ -n "${DALAMUD_LIB_PATH:-}" ]]; then
  [[ -f "$DALAMUD_LIB_PATH/Dalamud.dll" ]] || { echo "DALAMUD_LIB_PATH lacks Dalamud.dll" >&2; exit 1; }
  echo "using explicit, unverified reference override: $DALAMUD_LIB_PATH"
else
  python3 "$ROOT/tools/fetch-dalamud.py" "$DALAMUD_DISTRIB_URL" "$DALAMUD_DISTRIB_BLOB_SHA1" "$ROOT/vendor/dalamud"
fi
'''
p.write_text(s)
write('tools/fetch-dalamud.py', r'''#!/usr/bin/env python3
"""Fetch and verify the pinned Dalamud reference bundle, not a mutable cache."""
from __future__ import annotations
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
import tempfile
import urllib.request
import zipfile


def digest(path: Path) -> str:
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def cached(target: Path, expected: str) -> bool:
    try:
        data = json.loads((target / '.bundle.json').read_text())
        files = data['files']
        actual = {str(p.relative_to(target)) for p in target.rglob('*') if p.is_file() and p.name != '.bundle.json'}
        return data['git_blob_sha1'] == expected and 'Dalamud.dll' in files and actual == set(files) and all(digest(target / p) == h for p, h in files.items())
    except (OSError, ValueError, KeyError, TypeError):
        return False


def install(url: str, expected: str, target: Path) -> None:
    if not url.startswith('https://raw.githubusercontent.com/goatcorp/dalamud-distrib/'):
        raise ValueError('Expected the official immutable Dalamud distribution URL')
    if cached(target, expected):
        print('Dalamud reference bundle: verified cached files')
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        raise RuntimeError('Reference cache is unverified or modified. Move vendor/dalamud aside, then fetch again.')
    with tempfile.TemporaryDirectory(prefix='.dalamud-fetch-', dir=target.parent) as tmp:
        root = Path(tmp)
        archive = root / 'bundle.zip'
        with urllib.request.urlopen(url, timeout=120) as response, archive.open('wb') as out:
            shutil.copyfileobj(response, out)
        h = hashlib.sha1(f'blob {archive.stat().st_size}\0'.encode())
        with archive.open('rb') as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b''):
                h.update(chunk)
        if h.hexdigest() != expected:
            raise RuntimeError('Reference bundle differs from its pinned Git blob; refusing extraction')
        stage = root / 'stage'
        stage.mkdir()
        with zipfile.ZipFile(archive) as z:
            for entry in z.infolist():
                path = PurePosixPath(entry.filename)
                mode = (entry.external_attr >> 16) & 0xffff
                if path.is_absolute() or '..' in path.parts or '\\' in entry.filename or ':' in entry.filename or stat.S_ISLNK(mode):
                    raise RuntimeError('Unsafe reference archive path')
            z.extractall(stage)
        if not (stage / 'Dalamud.dll').is_file():
            raise RuntimeError('Reference bundle has no root Dalamud.dll')
        files = {str(p.relative_to(stage)): digest(p) for p in stage.rglob('*') if p.is_file()}
        (stage / '.bundle.json').write_text(json.dumps({'git_blob_sha1': expected, 'archive_sha256': digest(archive), 'files': files}, sort_keys=True))
        stage.rename(target)
    print('Dalamud reference bundle: verified and installed')

if __name__ == '__main__':
    if len(sys.argv) != 4:
        raise SystemExit('usage: fetch-dalamud.py URL GIT_BLOB_SHA1 DIRECTORY')
    install(sys.argv[1], sys.argv[2], Path(sys.argv[3]))
''', True)

platform = '''## if ccinfo.is_windows then
local function policy_GetModuleHandleA(name: cstring): pointer <cimport 'GetModuleHandleA', cinclude '<windows.h>', nodecl> end
local function policy_GetProcAddress(mod: pointer, name: cstring): pointer <cimport 'GetProcAddress', cinclude '<windows.h>', nodecl> end
## end

local function policy_platform(): cstring
  ## if ccinfo.is_windows then
    local ntdll = policy_GetModuleHandleA('ntdll.dll')
    if ntdll ~= nilptr and policy_GetProcAddress(ntdll, 'wine_get_version') ~= nilptr then return 'wine' end
    return 'windows'
  ## else
    return 'posix'
  ## end
end

'''
patch('core/policy.nelua', 'global Profile = @record{', platform + 'global Profile = @record{')
patch('core/policy.nelua', '  luaL_openlibs(L)\n', "  luaL_openlibs(L)\n  lua_pushstring(L, policy_platform()) lua_setglobal(L, 'GHOSTTY_PLATFORM')\n")
patch('lua/init.lua', 'local config = {', "local native_windows = rawget(_G, 'GHOSTTY_PLATFORM') == 'windows'\n\nlocal config = {")
patch('lua/init.lua', "command = { '/bin/bash', '-l' }", "command = { '/bin/sh' }")
patch('lua/init.lua', "command = { 'pwsh.exe', '-NoLogo' }", "command = { 'powershell.exe', '-NoLogo' }")
patch('lua/init.lua', '  default_profile = 1,', '  -- Native Windows has cmd.exe; Wine requires the separately started agent.\n  default_profile = native_windows and 4 or 1,')
patch('tests/test_policy.nelua', "assert(policy.profiles[0].argv[0] == '/bin/bash')", "assert(policy.profiles[0].argv[0] == '/bin/sh')")
patch('agent/agent.nelua', "## cinclude '<pty.h>'", "## if ccinfo.is_linux then\n## cinclude '<pty.h>'\n## else\n## cinclude '<util.h>' -- Darwin forkpty/openpty declarations\n## end")
write('tools/build-agent.sh', r'''#!/usr/bin/env bash
# Standalone agent build. Darwin support is experimental until tested there.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
case "$(uname -s)" in Linux|Darwin) ;; *) echo 'The agent requires Linux or macOS.' >&2; exit 2 ;; esac
CC="${CC:-cc}"
source "$ROOT/tools/build-common.sh"
build_nelua
mkdir -p build/dist build/nelua-cache
"$ROOT/vendor/nelua-lang/nelua" --cc "$CC" -P nogc --cache-dir build/nelua-cache -L . -o build/dist/ghostty-agent -b agent/agent.nelua
''', True)

patch('shim/GhosttyDalamud/Native.cs', '    public byte* ConfigsRoot;\n', '    public byte* ConfigsRoot;\n    public byte* NativeCacheDir;\n')
patch('core/app/boot.nelua', "  configs_root: cstring,  -- Dalamud's pluginConfigs; the legacy Umbra home lives below it\n", "  configs_root: cstring,  -- Dalamud's pluginConfigs; the legacy Umbra home lives below it\n  native_cache_dir: cstring, -- optional, owned by the shim; used by the loader\n")
patch('core/loader.nelua', '  configs_root: cstring,\n', '  configs_root: cstring,\n  native_cache_dir: cstring,\n')
patch('core/loader.nelua', '  configs_root: string, has_configs_root: boolean,\n', '  configs_root: string, has_configs_root: boolean,\n  cache_dir: string, has_cache_dir: boolean,\n')
patch('core/loader.nelua', "sb:writef('%sghostty_core.live-%d.dll', loader.dir, n)", "sb:writef('%sghostty_core.live-%d.dll', loader.cache_dir, n)")
patch('core/loader.nelua', '      configs_root = arg_cstr(loader.configs_root, loader.has_configs_root),\n', '      configs_root = arg_cstr(loader.configs_root, loader.has_configs_root),\n      native_cache_dir = arg_cstr(loader.cache_dir, loader.has_cache_dir),\n')
patch('core/loader.nelua', '  loader.core_path = loader.dir .. CORE_FILE\n', '''  loader.core_path = loader.dir .. CORE_FILE
  if #loader.cache_dir == 0 then
    loader.cache_dir = loader.dir:copy() -- compatibility with older embedded hosts
  else
    local last = loader.cache_dir:byte(#loader.cache_dir)
    if last ~= 47 and last ~= 92 then
      local p = loader.cache_dir .. '/'
      loader.cache_dir:destroy()
      loader.cache_dir = p
    end
  end
''')
patch('core/loader.nelua', "  unload_core('shutdown')\n", "  if not unload_core('shutdown') then return end\n  delete_old_copies()\n")
patch('core/loader.nelua', '  loader.configs_root:destroy()\n', '  loader.configs_root:destroy()\n  loader.cache_dir:destroy()\n')
patch('core/loader.nelua', '  if inf.configs_root ~= nilptr then loader.configs_root, loader.has_configs_root = string.copy(inf.configs_root), true end\n', '  if inf.configs_root ~= nilptr then loader.configs_root, loader.has_configs_root = string.copy(inf.configs_root), true end\n  if inf.native_cache_dir ~= nilptr then loader.cache_dir, loader.has_cache_dir = string.copy(inf.native_cache_dir), true end\n')
patch('core/loader.nelua', '-- ghostty_core.live-<n>.dll, next to this file. When ghostty_core.dll changes', "-- ghostty_core.live-<n>.dll, in the shim's writable cache. When ghostty_core.dll changes")

p = ROOT / 'shim/GhosttyDalamud/Plugin.cs'
s = p.read_text()
start = s.index('    public Plugin()\n')
s = s[:start] + r'''    private readonly string nativeCacheDir = Path.Combine(
        Pi.ConfigDirectory.FullName, "native-cache",
        $"{System.Environment.ProcessId}-{System.Guid.NewGuid():N}");
    private bool nativeLoaded;
    private bool hostCreated;
    private bool walkHooked;
    private bool subscribed;
    private bool disposed;

    public Plugin()
    {
        Directory.CreateDirectory(nativeCacheDir);
        nint installDir = 0, configDir = 0, configsRoot = 0, cacheDir = 0;
        try
        {
            string install = Pi.AssemblyLocation.DirectoryName!;
            Native.Load(Path.Combine(install, "ghostty_core.dll"));
            nativeLoaded = true;
            HostApi.Create();
            hostCreated = true;
            installDir = Marshal.StringToCoTaskMemUTF8(install);
            configDir = Marshal.StringToCoTaskMemUTF8(Pi.ConfigDirectory.FullName);
            configsRoot = Marshal.StringToCoTaskMemUTF8(Pi.ConfigDirectory.Parent!.FullName);
            cacheDir = Marshal.StringToCoTaskMemUTF8(nativeCacheDir);
            var info = new GuInitInfo {
                Size = (nuint)sizeof(GuInitInfo),
                HostKind = Native.HostKindDalamud,
                InstallDir = (byte*)installDir,
                ConfigDir = (byte*)configDir,
                ConfigsRoot = (byte*)configsRoot,
                NativeCacheDir = (byte*)cacheDir,
            };
            if (Native.InitEx(HostApi.Api, &info) == 1)
                throw new System.InvalidOperationException("Native core rejected initialization arguments.");
            walkHooked = true;
            HostApi.HookWalkInput();
            Pi.UiBuilder.Draw += OnDraw;
            Pi.UiBuilder.OpenMainUi += OnOpenMain;
            Pi.UiBuilder.OpenConfigUi += OnOpenConfig;
            Pi.ActivePluginsChanged += OnPluginsChanged;
            subscribed = true;
        }
        catch
        {
            Dispose();
            throw;
        }
        finally
        {
            Marshal.FreeCoTaskMem(installDir);
            Marshal.FreeCoTaskMem(configDir);
            Marshal.FreeCoTaskMem(configsRoot);
            Marshal.FreeCoTaskMem(cacheDir);
        }
    }

    private static void OnDraw() => Native.Frame();
    private static void OnOpenMain() => Native.Post(GuEvent.OpenMain, 0, 0, 0, 0, string.Empty);
    private static void OnOpenConfig() => Native.Post(GuEvent.OpenConfig, 0, 0, 0, 0, string.Empty);
    private static void OnPluginsChanged(IActivePluginsChangedEventArgs args) => Native.Post(GuEvent.PluginsChanged, 0, 0, 0, 0, string.Empty);

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        if (subscribed)
        {
            Pi.UiBuilder.Draw -= OnDraw;
            Pi.UiBuilder.OpenMainUi -= OnOpenMain;
            Pi.UiBuilder.OpenConfigUi -= OnOpenConfig;
            Pi.ActivePluginsChanged -= OnPluginsChanged;
        }
        if (walkHooked) HostApi.UnhookWalkInput();
        if (nativeLoaded)
        {
            Native.Shutdown();
            Native.Unload();
        }
        if (hostCreated) HostApi.Free();
        try { Directory.Delete(nativeCacheDir, recursive: true); }
        catch (IOException) { /* A mapped DLL may remain until the game exits. */ }
        catch (System.UnauthorizedAccessException) { /* Do not fail plugin disposal. */ }
    }
}
'''
p.write_text(s)
patch('tests/test_loader.nelua', 'configs_root: cstring }', 'configs_root: cstring, native_cache_dir: cstring }')
patch('tests/test_loader.nelua', "  sb:write(test_dir, '/', name)", "  if name:find('ghostty_core.live-', 1, true) == 1 then\n    sb:write(config_dir, '/native-cache/', name)\n  else\n    sb:write(test_dir, '/', name)\n  end")
patch('tests/test_loader.nelua', '  local inst, conf = install_dir:copy(), config_dir:copy()', "  local inst, conf = install_dir:copy(), config_dir:copy()\n  local cache = config_dir .. '/native-cache'")
patch('tests/test_loader.nelua', "configs_root = '' }", "configs_root = '', native_cache_dir = (@cstring)(cache.data) }")
patch('tests/test_loader.nelua', '  inst:destroy() conf:destroy()', '  inst:destroy() conf:destroy() cache:destroy()')
patch('tests/run.sh', 'mkdir -p build/loader-test build/test-scratch/loader', 'mkdir -p build/loader-test build/test-scratch/loader/native-cache')

p = ROOT / 'README.md'
s = p.read_text()
s = s.replace('# Ghostty for Dalamud\n', '''# Ghostty for Dalamud

> **Experimental developer preview.** Not an official Ghostty or Dalamud project,
> and not represented as accepted into the official plugin list. Linux host tests
> do not establish native Windows, Wine, macOS, or in-game compatibility.
> See [release readiness](docs/RELEASE_READINESS.md) before distributing builds.
''', 1)
s = s.replace('~/.cache/dalamud-dev', 'vendor/dalamud')
s = s.replace("(filled by `fetch-vendor.sh` from goatcorp's dalamud-distrib)", '(verified against the immutable bundle in `toolchain.env`)')
s = s.replace("command = { '/bin/bash', '-l' }", "command = { '/bin/sh' }")
s += '''
## First-run defaults and development support

On native Windows, the shipped default uses ConPTY with `cmd.exe`; Wine and
POSIX host tests use the agent profile. Wine is detected through its native
runtime marker, not guessed from a home-directory path. Existing user overrides
are preserved and may still select the old profile. Windows PowerShell uses
`powershell.exe`; PowerShell 7 (`pwsh.exe`) and `tmux` are optional choices, not
installation requirements. The POSIX default uses `/bin/sh`, not an assumed Bash
installation.

The agent is a separate process: start it and configure its token before using
an agent profile. A remote agent needs its own address and a protected connection,
such as an SSH forward. The stream is not encrypted. Never reuse the test token.

The complete plugin build and host test scripts currently target Linux. The
standalone macOS agent path is experimental: run `tools/build-agent.sh` after
fetching dependencies, and do not describe it as validated until tested on macOS.
The dev installer prints a Wine path; native Windows users copy the complete
plugin folder and select the DLL in Dalamud's dev-plugin settings.

The plugin stores live core copies in its writable per-instance configuration
cache, not beside a read-only installation. The source DLL remains the watched
file for hot reload. Older custom embeddings without the appended cache field
retain their historical behavior and must supply a writable installation.

The pinned reference bundle is separate from the game runtime. Set
`DALAMUD_LIB_PATH` only for an intentional local override; that override is not
covered by the bundle's content verification. A changed or unverified cache is
rejected, not silently accepted.
'''
p.write_text(s)
write('docs/RELEASE_READINESS.md', '''# Release readiness

This repository is an experimental developer preview. It is not an official
Ghostty project and official Dalamud-list acceptance has not been established.

## Implemented safeguards

- Build Nelua from its Makefile; the executable launcher alone is not a build.
- Select a native Windows terminal without requiring a POSIX agent or PowerShell 7.
- Read the runtime platform before loading default Lua policy; distinguish Wine.
- Use a per-instance writable cache for live core copies in the current shim.
- Pin and verify the Dalamud reference bundle; reject a stale or modified cache.
- Preserve user configuration and third-party attribution during maintenance.

## Evidence still required before a release

Record the exact commit, game build, Dalamud build, OS, architecture and results.
A host-only test pass must not be relabeled an in-game pass.

- Clean Linux build and host suite with an empty dependency cache.
- Native Windows: install, default cmd terminal, large input, unload and reload.
- Wine: token discovery, agent connection, controller handling, reload and shutdown.
- Read-only installation and writable configuration directories; concurrent clients.
- Non-ASCII user paths, missing optional commands, and controlled connection failures.
- macOS agent compilation and protocol tests before claiming macOS support.
- Review the native/game-facing functionality against the plugin-list requirements.

Controller HID, shadows and other game-facing experiments remain unverified until
run against their target environment. No generated source change proves runtime
compatibility by itself.
''')
write('.githooks/pre-commit', '''#!/bin/sh
# Install with: git config --local core.hooksPath .githooks
set -eu
for kind in GIT_AUTHOR_IDENT GIT_COMMITTER_IDENT; do
  [ "$(git var "$kind" | sed 's/>.*/>/')" = 'Spaceghost <251370+Spaceghost@users.noreply.github.com>' ] || {
    echo 'Use the repository pseudonymous author and committer identity before committing.' >&2
    exit 1
  }
done
''', True)
write('tools/configure-identity.sh', '''#!/bin/sh
# Set identity for this repository only; never modify global Git configuration.
set -eu
git config --local user.name Spaceghost
git config --local user.email 251370+Spaceghost@users.noreply.github.com
git config --local core.hooksPath .githooks
printf '%s\\n' 'Repository identity and local pre-commit hook configured.'
''', True)
write('tests/test_defaults.lua', '''-- Pure policy test: no game, agent, or optional shell installation required.
for _, name in ipairs({'keymap', 'world', 'animation', 'bell', 'showcase'}) do
  package.preload[name] = function() return {} end
end
package.preload.settings = function() return { apply = function(c) return c end } end
for _, platform in ipairs({'windows', 'wine', 'posix'}) do
  GHOSTTY_PLATFORM = platform
  local c = dofile('lua/init.lua')
  assert(c.profiles[c.default_profile].transport == (platform == 'windows' and 'conpty' or 'agent'))
  assert(c.profiles[1].command[1] == '/bin/sh')
  assert(c.profiles[4].command[1] == 'cmd.exe')
  assert(c.agent.token == '')
end
print('platform default policy OK')
''')
print('Applied source, build, configuration, cache and documentation repairs.')
