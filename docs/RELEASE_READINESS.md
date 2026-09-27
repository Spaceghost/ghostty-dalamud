# Release readiness

This is an independent plugin. Official Ghostty affiliation and official
Dalamud-list acceptance are not claimed. A stable tag identifies the release
channel, not blanket in-game or cross-platform verification; the changelog
distinguishes features seen in game from those still awaiting verification.

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

The repository is public. Continue reviewing current files, branch histories,
generated binaries/PDBs, workflow records and screenshots for private information
before wider distribution. Rewriting Git history does not purge external clones or
GitHub-managed cached pull-request objects. Preserve other contributors' attribution.

CI defines reproducible checks; its presence is not evidence of a passing run.
