# D17 submission plan and current gates

Rules checked 2026-09-17. D17 implements DIP17; it does not mean Dalamud API 17.
The official SamplePlugin currently uses Dalamud.NET.Sdk 15.0.0. This native-core
plugin uses D17's documented alternative: Microsoft.NET.Sdk, DalamudLibPath and
DalamudPackager 15.0.0. The plugin's declared API remains 15 until an actual port.

## Deliver in this order

1. **Build and use the private candidate.** Reconcile the packaging branch with
   the privacy/portability fixes, verify loader-free startup, use a fresh install
   directory, and retain the exact package hash and commit. `tools/play.sh` is the
   local entry point. Host checks are not an in-game compatibility claim.
2. **Complete technical/reproducibility review.** Generate and commit the NuGet
   lock via a real restore/build, prove a Plogon source build of Nelua/Zig and the
   C# shim, and migrate ordinary settings/utility windows to Dalamud WindowSystem.
   Do not put an unrelated empty WindowSystem around independently managed native
   windows and call the requirement satisfied. The existing native ImGui windows
   have not yet been migrated by this preparation.
3. **Complete feature and security review.** Audit shell/Lua execution, clipboard,
   token handling, lifecycle and missing-transport behavior. Seek approval-team
   feedback on movement/input hooks, character animation/speed/rotation, camera
   controls/showcase, world lights and shadow objects. Until reviewed, do not
   represent off-by-default features as automatically compliant. A conservative
   submission may need to remove state-changing features from the shipped build;
   preserve development functionality explicitly rather than hide it from review.
4. **Finish public-source and ownership prerequisites.** Scrub identifying source
   and reachable history, account for PR/cached copies, deliberately select the
   project license and required third-party notices, and provide a reviewed
   hand-made `images/icon.png` (square, 64-512 pixels). Optional screenshots must
   be genuine PNG captures no larger than 730x380. Do not publish fabricated game
   screenshots or label an AI-created icon hand-made. Review actual AI involvement
   and personally test the exact candidate; automation cannot attest those facts.
5. **Submit only after the gates pass.** Make the exact reviewed source commit and
   required dependencies anonymously cloneable, then prepare one D17 PR under
   `testing/live/GhosttyDalamud/`, with `manifest.toml` plus `images/icon.png` and
   optional screenshots. Pin the tested full SHA and disclose AI use. Do not use
   `stable`, or submit a PR to the approval team with a non-building private repo.

## Current requirement mapping

| Requirement | State / evidence still needed |
| --- | --- |
| Public source at exact SHA | BLOCKED: repository privacy work is not complete; no visibility change is made here. |
| Packager + correct references | Implemented on this branch; native/managed compilation and real restore remain required. |
| Generated lock file | BLOCKED until real packages.lock.json is generated, reviewed and committed. |
| Plogon source build | BLOCKED. Plogon's entrypoint calls dotnet build with IsPlogonBuild=True and supplied DalamudLibPath. A separate local native build is not proof that upstream can build it. |
| Stable assembly version | Explicit 0.3.0.0, not derived from timestamps or CI run numbers. |
| Complete clean-install ZIP | Explicit allowlist and validator; C# startup reconciled with omitted development loader. Actual artifact testing remains required. |
| Ordinary windows use Windowing API | BLOCKED: native settings/utility window integration remains work. |
| Gameplay policy | BLOCKED pending documented review of state-changing features and any required removal. |
| Icon/screenshots | BLOCKED: hand-made icon missing; screenshots optional and must be actual captures. |
| License/notices | BLOCKED: maintainer license decision and full shipped-dependency notice review. |
| Human ownership and personal tests | BLOCKED until actual review and in-game tests are recorded. |
| AI disclosure | This preparation is Auto-level AI implementation from maintainer direction. That is not a claim that meaningful human review already happened. Keep provenance honest. |
| New-plugin channel | testing/live only. The manifest generator creates a draft, not an approval. |

## Check recorded readiness

```sh
python3 tools/candidate.py preflight --package build/release/GhosttyDalamud.zip --evidence build/release/testing.json
```

This checks local artifact/metadata agreement, evidence binding, clean source,
tracked lock/license/icon, icon header dimensions, and fetched Git identities.
Missing evidence blocks it. It cannot verify the truth of manually entered review
notes, prove anonymous source availability, decode/test every image, certify all
historical copies erased, or grant official approval. Verify those separately.
After passing and personally reviewing the record:

```sh
python3 tools/release.py submission --commit "$(git rev-parse HEAD)" --output build/submission/testing/live/GhosttyDalamud/manifest.toml
mkdir -p build/submission/testing/live/GhosttyDalamud/images
cp images/icon.png build/submission/testing/live/GhosttyDalamud/images/
```

The manifest generator alone is draft-only. Do not confuse successful TOML output
with completion of this checklist. A subsequent history rewrite changes SHAs:
regenerate source records/manifests and re-establish tested-source correspondence.

## Primary references

- D17 rules: https://github.com/goatcorp/DalamudPluginsD17
- Submission: https://dalamud.dev/plugin-publishing/submission/
- Restrictions: https://dalamud.dev/plugin-publishing/restrictions/
- AI policy: https://dalamud.dev/plugin-publishing/ai-policy/
- Sample: https://github.com/goatcorp/SamplePlugin/blob/master/SamplePlugin/SamplePlugin.csproj
- Upstream build entrypoint: https://github.com/goatcorp/Plogon/blob/master/Plogon/static/entrypoint.sh
