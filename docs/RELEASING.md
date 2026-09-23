# Releasing Ghostty

One command cuts a release, and it is the same command in every one of these mods.

```sh
tools/release.sh test            # the next testing build, from master as it is
tools/release.sh stable X.Y.Z    # the stable release X.Y.Z
```

Add `-n` for a dry run: every check, the plan, and the release notes, with nothing
changed. `tools/release.sh verify vX.Y.Z` checks a published release again.

It needs `git`, `python3` and an authenticated `gh`. Nothing else is done by hand.

## What it does

1. Refuses unless the working tree is clean, on `master`, level with `origin/master`,
   and CI is green for that commit (it waits while CI is still running).
2. Works out the version. A tag is `vX.Y.Z` (stable) or `vX.Y.Z-test.N` (testing).
   Dalamud compares the four-part `AssemblyVersion`, so the fourth number counts builds
   of X.Y.Z: test N is `X.Y.Z.N`, and the stable release is one past the last test
   (`X.Y.Z.0` when there was none). Every build is newer than the one before it, and a
   tester on `X.Y.Z-test.N` is offered the stable `X.Y.Z`.
3. Writes that version everywhere it lives (the manifest, the csproj and `core/buildinfo.nelua`), and for a stable release turns the
   changelog's unreleased section into `X.Y.Z` with today's date. Entries keep their
   status: **BETA** stays BETA until it has been seen working in game, and entries that
   are still being built stay in the unreleased section.
4. Commits `Release <tag>`, tags it, and pushes `master` and the tag together.
5. Waits for the [Release workflow](../.github/workflows/release.yml), then checks the
   result: the release exists on the right channel, `latest.zip`, the versioned zip, the
   pluginmaster JSON and `SHA256SUMS` are attached, the downloads match their checksums,
   and <https://spacegho.st/mods/ffxiv/plugins.json> shows the new version with every
   link answering. The listing is cached for some minutes, so this last step waits.

If the workflow fails, fix it on `master` and re-run that workflow; the tag stays put.

## The testing channel fills itself

Every commit that lands on `master` becomes a testing build once CI is green on it, with
nobody running anything. [Testing channel](../.github/workflows/testing-channel.yml)
follows each successful CI run of a push to `master` and runs
`tools/releasekit.py auto-test --sha <that commit> --push`, which

1. does nothing when that commit is already in the newest build (the CI run of a
   `Release` commit, or a run that finished after a newer one), or when nothing but
   release commits landed since;
2. otherwise counts on from the tags (`vX.Y.Z-test.N+1`, or the next patch's `test.1`
   after a stable release), writes that version into the version files, commits
   `Release <tag>` **on top of** the green commit, tags it and pushes the tag only;
3. and then calls the Release workflow for that tag, which checks, builds, publishes and
   moves the floating `testing` release onto it exactly as for a tag pushed by hand.

So `master` is never written to by a bot: no commit to start CI again, nothing for branch
protection to refuse. `master`'s manifest keeps the version it had; the tags carry the
builds, and `tools/release.sh` counts from the tags too. `check-tag` accepts a test tag
on such a commit only when its parent is on `master`, its subject is `Release <tag>` and
it changes nothing but the version files. A stable tag must still be on `master` itself.

Runs are serialized (one `testing-channel` concurrency group, never cancelled), so builds
are published in the order CI finished, oldest first; a merge that arrives while one is
publishing waits, and a newer one replaces it in the queue and ships both. Set the
repository variable `TESTING_CHANNEL_AUTO` to `false` to pause it.

The token is the workflow's own (`contents: write`), handed to git for the one push
through the environment. If a tag ruleset ever protects `v*`, give the GitHub Actions
app a bypass for it, or the push is refused and the run says so.

`tools/release.sh test` still works for a build between merges, and stable releases stay
manual: `tools/release.sh stable X.Y.Z`.

## What a release looks like

The title is `Ghostty vX.Y.Z`, or `Ghostty vX.Y.Z-test.N (testing)`. The notes are
generated from the changelog (`lua/changelog.lua`, the one players read in game): the banner, an honest line about what has not
been verified in game, the entries grouped as *New*, *Fixed* and *In this build, not yet
verified in game*, how to install, the checksums, and links to the site and the
changelog. Under *Merged* come the changes per channel, from `master`'s first-parent history
(`tools/releasekit.py changes <tag>`; `Release` commits left out, a squash's `(#N)` kept as
its link): a testing build lists what landed since the previous test build and since the
last stable release, a stable release what landed since the stable one before it. A
testing build with no changelog entries yet still ships, and its notes say so. The same
entries, shortened, go into the listing for Dalamud's installer, and for a testing build
the subjects merged since the previous build follow them.

## Channels

* **Stable** is the newest full release. The listing serves
  `releases/latest/download/latest.zip`, a URL that never changes.
* **Testing** is one floating prerelease called `testing`, which always carries the
  newest test build, at `releases/download/testing/latest.zip`. Players opt in with
  *Get plugin testing builds*. A testing build never touches a stable release's files.

## What the workflow will not do

It runs only in this repository (never a fork), only on GitHub-hosted runners, with
actions pinned by commit and a token that can write releases and nothing else. It
refuses a tag that is not on `master`, and a tag that does not name the version in the
manifest. Zips are packed with sorted names and fixed timestamps, so the same build
packs to the same bytes.

## What a release does not prove

That the plugin works in the game. The workflow builds and tests without the game;
only playing it verifies it, and the changelog's statuses say which is which.
