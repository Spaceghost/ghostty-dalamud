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

## Loading-screen camera verification

The panel camera cancels its saved zoom on the between-areas scene flag. The
shared managed camera setter now rejects writes for both BetweenAreas and
BetweenAreas51, covering panel easing and Lakitu. Lakitu discards its saved
view without restoring it when loading starts or the player disappears, and
discards stale restoration state on a territory change. Ordinary camera
teardown still restores the view while the scene remains available.

The managed Release build passes with zero warnings/errors
(`/var/home/jack/xivmods/xiv-lantern-build/native/ghostty-loading-camera-shim-build.log`).
Full native host Nelua C generation passes (`build/loading-camera-nelua-check.log`);
this verifies the updated native source, not a rebuilt Windows native DLL.
Before release, rebuild/package the native core and verify a teleport/zone change
while panel zoom and Lakitu are active: no camera writes or zoom animation during
loading, and no restoration of the previous scene's camera on arrival. In-game
verification remains open. No game-chat commands were entered for these checks.

Windows-targeted full host C generation also passes
(`build/loading-camera-windows-nelua-check.log`). An isolated MinGW compile succeeded, but linking failed against the existing
Zig-built Windows Ghostty/Lua archives (NTDLL imports and
`__intrinsic_setjmpex`); no DLL was produced. Output was reserved
as `xiv-lantern-build/native/ghostty-loading-camera-core.dll` and log
`build/loading-camera-windows-build.log`. This is a camera candidate with optional
iroh disabled, not a release package or an installed replacement. Generated C
emits three noreturn warnings; native runtime/game behavior is not
yet verified. Preserve the existing distributed native DLL until the candidate
and required release configuration are checked.

Production camera regression `tests/test_loading_camera.c` passes in the capped
compositor builder (`build/loading-camera-regression.log`). It executes freshly
generated host C: between-areas cancels panel camera state without reading or
writing the camera; the next ordinary frame does not restore that saved zoom;
Lakitu's transition discard clears steering/restoration without writing; ordinary
Lakitu teardown still restores. Repeat through
`tools/test-loading-camera-container.sh` to regenerate before testing. This is
a native function test, not a game test or a managed condition-adapter test.

A fresh capped builder `ghostty-loading-camera-build` now has the pinned Zig
0.16.0. SELinux prevented reading its bind mounts; inputs were copied into its
private `/build` directory without changing host labels. The isolated Zig link succeeded there, logged in
`build/loading-camera-zig-build.log`. The copied DLL is an x64 PE with the
required gu_init/gu_init_ex/gu_frame/gu_version/gu_shutdown exports and no extra
GCC/C++ runtime imports (`build/loading-camera-pe-inspection.txt`). Native SHA256:
`5773b1bcca9f8088ff3b7b21d81ba59f9d355d10202c5267dc3b077627f0747c`.
`build/loading-camera-candidate/camera-test-artifacts.zip` holds that DLL, the
built managed shim and evidence with payload/source hashes. It is a test-artifact
bundle, not an installable plugin package; loader/Lua/themes are not included.
Do not install or publish this optional-iroh-disabled camera candidate as a
verified release. Native runtime/game checks remain open.
