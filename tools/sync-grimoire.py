#!/usr/bin/env python3
"""Refresh the owned Grimoire source snapshot without adding another plugin entry."""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path, help='XivSpell source checkout')
    args = parser.parse_args()
    source = args.source.resolve() / 'plugin'
    target = ROOT / 'shim/GhosttyDalamud/PhoneModules/Imported'
    manifest = json.loads((target / 'SOURCES.json').read_text())
    manifest['files'] = [item for item in manifest['files'] if not item['output'].startswith('Grimoire/')]
    paths = sorted(source.glob('*.cs'))
    if not paths or not (source / 'Plugin.cs').is_file():
        raise SystemExit('Expected a XivSpell source checkout')
    for path in paths:
        original = path.read_text()
        text = original
        if path.name == 'Plugin.cs':
            text = text.replace('public sealed partial class Plugin : IDalamudPlugin', 'internal sealed partial class Plugin : IDisposable')
            text = text.replace('pi.GetPluginConfig() as Config ?? new Config()', 'GhosttyDalamud.PhoneModules.ModuleConfiguration.Load<Config>(pi, "Grimoire")')
            text = text.replace('pi.SavePluginConfig(config)', 'GhosttyDalamud.PhoneModules.ModuleConfiguration.Save(pi, "Grimoire", config)')
            text = re.sub(r'pi\.UiBuilder\.Open(?:Main|Config)Ui [+-]= [A-Za-z]+;', '', text)
            text = re.sub(r'^\s*if \(hudStartup\?\.IsCompletedSuccessfully == true\) KamiToolKit\.KamiToolKitLibrary\.Dispose\(\);\n', '', text, flags=re.M)
            text = re.sub(r'^\s*else if \(hudStartup != null\) _ = hudStartup\.ContinueWith\(.*\);\n', '', text, flags=re.M)
            text = text.replace('else if (args == "cards") visible = !visible;', 'else if (args == "cards") visible = !visible;\n            else if (args == "book") visible = true;')
            if re.search(r'class\s+Plugin\s*:\s*I(?:Async)?DalamudPlugin\b', text) or 'KamiToolKitLibrary.Dispose' in text:
                raise SystemExit('Review the updated Grimoire entry point before importing')
        if path.name == 'CommandBar.cs':
            text = text.replace('hudStartup ??= KamiToolKitLibrary.InitializeAsync(pi, "XivSpell");', 'hudStartup ??= GhosttyDalamud.NativeWindows.StartupTask;')
        text = text.replace('public sealed partial class Plugin', 'internal sealed partial class Plugin')
        (target / 'Grimoire' / path.name).write_text(text)
        manifest['files'].append({'source': 'xivspell/plugin/' + path.name, 'output': 'Grimoire/' + path.name,
                                  'sourceSha256': hashlib.sha256(original.encode()).hexdigest()})
    (target / 'SOURCES.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Updated {len(paths)} embedded Grimoire source files')


if __name__ == '__main__':
    main()
