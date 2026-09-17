# Release readiness

This is an independent experimental developer preview. Official Ghostty affiliation
and official Dalamud-list acceptance are not claimed.

## Evidence required

Record the tested commit, game build, Dalamud build, OS, architecture and results.
Host-only tests must not be described as in-game tests.

- Clean Linux build and host suite with empty dependency caches.
- Native Windows install, default terminal, large input, failure cleanup and reload.
- Wine agent connection, token discovery, optional controller HID and shutdown.
- Read-only installation with writable user cache, concurrent clients, Unicode paths.
- macOS agent compilation/protocol tests before claiming macOS support.

## Distribution review

Validate package contents and dependency licenses. Confirm the project's own license
with the maintainer rather than silently selecting one. Review native/game-facing
functionality against current Dalamud submission requirements. Keep experimental
shadow/HID features clearly labeled and opt-in where applicable.

Keep the repository private until current files, all branch histories, generated
binaries/PDBs, workflow records and any screenshots have been reviewed for private
information. Rewriting Git history does not purge external clones or GitHub-managed
cached pull-request objects. Preserve other contributors' attribution.

CI defines reproducible checks; its presence is not evidence of a passing run.
