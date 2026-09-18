# Ghostty initial testing submission (draft only)

Do not send this upstream until docs/D17_READINESS.md is complete. Replace this
notice with the exact reviewed commit, package hash and actual testing results.

## Purpose and execution model

Ghostty embeds a libghostty-vt terminal in FFXIV. The native core is Nelua, policy
and configuration are Lua, and the managed shim integrates with Dalamud. Shells
run using local Windows ConPTY or a separately configured, token-authenticated
POSIX agent. The agent stream is plaintext and requires loopback or a secure
tunnel. Lua and shell commands execute with the user's privileges, not in a
sandbox. The optional Umbra widget is not a hard dependency of the main ZIP.

## Required review notes

Document the Plogon source-build path, generated NuGet lock and shipped licenses.
Explain Windowing API integration and all remaining movement, camera, animation,
input, clipboard, lighting and shadow functionality, including what was removed
from the actual submitted build. Do not equate a default-off switch with approval.
Attach actual personal test results and reviewed icon/screenshots, not fixture
outputs or promised testing. New submission channel: testing/live only.

## AI usage disclosure

This preparation was implemented by an AI agent from high-level maintainer
direction (Auto for this preparation). Existing project history also includes
AI-coauthored work. No personal in-game testing or meaningful human code review
has been established by this preparation. Describe the actual subsequent human
review and testing here before submission; do not silently relabel the work as
unassisted or remove attribution to conceal AI involvement. The maintainer must
understand and be able to explain the code being submitted.
