# DRAFT — Ghostty initial testing submission

Do not submit this template unchanged. Complete docs/PUBLISHING.md first.

## What the plugin does

A libghostty-vt terminal with a Nelua core and Lua configuration, hosted by a
small Dalamud shim. It supports local Windows ConPTY sessions and a separately
started Linux/macOS PTY agent (macOS requires validation). The optional Umbra
widget is independent. The release archive excludes the native hot-reload
loader, host/game assemblies, user configuration and the agent executable.

## Features requiring explicit approval review

Please review the world-pinned screens, camera/showcase controls, character
animation/speed/rotation functionality, input hooks and experimental shadow
objects. Include the actual constraints and code locations after review.
This template does not assert that these features already comply.

## Build and provenance

- Exact source commit: TODO
- Clean build and native dependency provenance: TODO
- Supported Plogon native build path and generated NuGet lock file: TODO
- Runtime package SHA-256 and retained build/test evidence: TODO
- License and required third-party notices: TODO

## Personal test results

Not yet recorded. Replace with actual results for the exact submitted commit:
Windows and Linux/Wine, API/game versions, clean installation, transport/token
setup, ordinary use, settings, unload/reload, relaunch, read-only installation,
missing dependencies, and Umbra absent/present. Do not infer runtime results
from packaging unit tests or source review.

## AI disclosure

AI-generated implementation was used for this release-preparation change in
response to the maintainer's high-level request, including packaging scripts,
tests and documentation. For that session the applicable disclosure is Auto:
the agent investigated and implemented autonomously; human review and in-game
testing have not been established. The repository also contains prior
AI-coauthored work. The maintainer must accurately describe the full history,
actual human involvement, personal review and testing before submission.
Do not downgrade disclosure or claim testing merely because a tool generated
this template. No icon or marketing artwork was generated in this change.

- [ ] All outstanding gates in docs/PUBLISHING.md are resolved.
- [ ] The maintainer understands and personally tested the submitted code.
- [ ] The source, exact commit and dependencies are public and auditable.
- [ ] The icon is provided and AI involvement is accurately disclosed.
- [ ] Only testing/live/GhosttyDalamud is changed in this D17 PR.
