# Ghostty packaging and publication

This is a private candidate-preparation branch, not a public release or an
accepted mainline plugin. Start with [TRY_IT.md](TRY_IT.md) to build and stage a
candidate for personal use. Follow [D17_READINESS.md](D17_READINESS.md) for every
remaining official-submission gate.

`tools/build-release.sh` performs a real restore/build on a provisioned Linux
host. An existing tracked lock is restored in locked mode. A first restore can
generate the lock, but it must be reviewed/committed and the resulting source
rebuilt before submission. The script runs Python tests, NativeCache file-lifecycle
checks and the existing native/agent tests before exposing the candidate under
`build/release/`. Actual in-game verification remains separate.

The ZIP allowlist excludes personal configuration, PDBs, host assemblies, the
agent, optional Umbra widget and development hot-reload loader. `NativeCache`
recognizes loader-free releases and does not try to copy a nonexistent loader.
The normal developer build can still use its isolated per-instance native cache.

## Distribution paths

A private Actions artifact or local build can be manually installed through Dev
Plugin Locations. An authenticated Actions artifact is **not** a URL suitable for
a custom Dalamud repository. Do not tell users to add a feed that does not exist.

After privacy, license and testing gates are complete, a custom repository needs
an anonymously accessible HTTPS `repo.json` and versioned plugin ZIP. Generate
that JSON with `tools/release.py repo`; its default is testing-exclusive. Check a
real unauthenticated download and compare its SHA-256 with the local package
report before announcing it. The URL validator alone does not prove availability.

For official distribution, Plogon builds a publicly cloneable source commit
specified in D17's `testing/live/GhosttyDalamud/manifest.toml`. We must prove a
supported source-build path for the native toolchain, not just supply a locally
built DLL or assume ordinary dotnet build compiles Nelua/Zig. No upstream PR,
public release, website deployment or visibility change is automatic.

## CI and evidence

The candidate workflow offers the usual hosted runner and an explicitly selected
self-hosted Linux x64 runner on manual dispatch. A self-hosted runner must actually
be registered/online for this repository; selecting its label does not create or
connect one. PR events never select self-hosted execution automatically.

Private artifacts contain the candidate ZIP, package report and generated lock.
Keep in-game logs/screenshots local until reviewed for character names, usernames,
paths, shell output, tokens and other personal data. Testing records start unset;
this tooling does not check human-review boxes on anyone's behalf.
