# Releasing Sonar

Everything that has to be true before `git tag v0.1.0`, and what the tag does. Written for
Sonar 0.1.0, the first release; later releases only need the two steps in "Ship it".

## You do not need a paid Apple account

Notarization costs $99/year, and Sonar does not have it. The build is therefore **ad-hoc signed
and un-notarized** — and that is a supported state, because of one measured fact:

> Homebrew downloads with `curl`, which does **not** set the `com.apple.quarantine` attribute.
> Gatekeeper only engages on a quarantined file. A curl-fetched, ad-hoc-signed Sonar installs to
> `/Applications` and launches, and its audio tap works.

Verified on this machine: fetched the zip over HTTP, installed it, launched it, and the Core Audio
tap came up (`capture=true`, `rms` tracked) and drove a real duck in 486 ms.

**So `brew install --cask sonar` is the supported install path, and it costs nothing.**

### The one cost, stated plainly

`spctl -a -vv` on the artifact reports `rejected`, because nothing signs it with a Developer ID.
For anyone installing via Homebrew this is invisible. For someone who **downloads the zip in a
browser** — which does set quarantine — macOS may require a one-time manual approval in
**System Settings › Privacy & Security › Open Anyway**.

This has *not* been tested on a clean Mac: this machine has a long approval history for
`com.KathirD.sonar` from a session's worth of local builds, so the prompt could not be provoked
here. Assume a first-time browser download hits it, and say so in the README rather than
discovering it in someone's bug report.

If you ever pay for the membership, skip to [If you later get a Developer account](#if-you-later-get-a-developer-account).
Nothing below needs it.

**Sonar has no in-app updater.** There is no update feed, no EdDSA signing key and no appcast.
Updates come from `brew upgrade --cask sonar` or the releases page, which is what
[About](Sonar/Preferences/AboutPreferencesView.swift) tells the user. That is why the release
pipeline is short enough to read in one sitting: it builds, packages, checksums, and uploads.

---

## What is already verified

| | Status |
| --- | --- |
| Engine test suite | 272 tests, green. No hardware, no permission, no audio needed |
| App build | `xcodebuild` clean, no new warnings |
| End-to-end behaviour | `scripts/autopause-smoke.sh`: pause in **486 ms**, resume in **482 ms**, Instant preset, against a real tone through the real output device |
| A curl-fetched build installs | Fetched over HTTP, unzipped, installed, launched; the Core Audio tap came up and drove a real duck. No quarantine, so no Gatekeeper |
| Release pipeline | `build-app.sh` → `package-release.sh` → `sign-release.sh`, dry-run end to end; 10 CI steps, no feed to sign |
| `CFBundleVersion` | An increasing integer, not a git hash (this silently broke before) |
| Cask, workflow | Cask checksum filled in by the release run; the run states its signing mode either way |
| Documentation | README, and [HOW-AUTOPAUSE-WORKS.md](HOW-AUTOPAUSE-WORKS.md) for the engine |

## What is NOT verified, and cannot be from here

- **A first-time browser download on a clean Mac.** See the note at the top; it could not be
  reproduced here.
- **`brew install --cask sonar` end to end**, because the tap repository does not exist yet
  (step 6). The download half of it is verified.
- `brew audit --cask --strict` — Homebrew's own audit is broken on this machine (a vendored-gem
  incompatibility in Homebrew 7.0.6, unrelated to the cask). Run it once on a working machine.

---

## 1. Before you tag

Nothing to set up. There are no secrets to configure and no certificate to create. Confirm:

```sh
git status --porcelain      # must be empty
cat VERSION                 # the version you are about to tag
```

## 2. Rehearse, without publishing

Tag pushes publish, so rehearse first. The manual dispatch builds, ad-hoc signs, zips and
checksums, then stops — nothing is uploaded because nothing was tagged.

```sh
gh workflow run release.yml
gh run watch
```

In the log you want `BUILD SUCCEEDED`, and one `::warning::` line saying the build is ad-hoc and
un-notarized. That warning is correct, not a failure.

## 3. Sanity-check before shipping

The cask's checksum placeholder is expected and correct — the release run fills it in:

```sh
grep -c REPLACE_WITH_RELEASE_SHA256 Casks/sonar.rb   # 1: correct
cat VERSION                                            # the version you will tag

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift test --package-path Packages/AutoPauseEngine

sh scripts/autopause-smoke.sh --allow-playback
```

Expect **~0.5 s** to pause and resume. Anything above 2 s means detection is not actually
measuring loudness; the smoke test says so rather than passing quietly. **Audio is a shared global
resource: never run this while anything else is playing sound on the machine.**

## 4. Ship it

```sh
git tag -a v0.1.0 -m "Sonar 0.1.0"
git push origin v0.1.0
gh run watch
```

The workflow builds with your Developer ID, notarizes, staples, and uploads the zip, the checksums
and the cask with its real checksum filled in.

## 5. Verify the release as a user would

```sh
gh release view v0.1.0                     # zip + SHA256SUMS + sonar.rb attached
shasum -a 256 -c dist/0.1.0/SHA256SUMS.txt  # if you kept a local copy

# The real test: on a DIFFERENT Mac, or a clean user account on this one.
open dist/0.1.0/Sonar-0.1.0.zip
```

Then, in that order, because each depends on the last:

1. The app opens **without** "Open Anyway" — that is what notarization bought.
2. `xattr -dr com.apple.quarantine` is never needed.
3. Launch it, open Preferences › Auto-Pause, grant both permissions, and confirm the state line
   says it is measuring loudness rather than *Process polling only*.
4. Play something in a browser and confirm Spotify stops, and starts again when you stop.

## 6. Publish the tap

`brew install --cask sonar` only resolves from a tap, which is a **separate, free GitHub
repository** — this is the one thing left to do before anyone can install Sonar by name. It is
about two minutes:

```sh
gh repo create Kathir-D/homebrew-tap --public --description "Homebrew cask for Sonar"
git clone https://github.com/Kathir-D/homebrew-tap ~/homebrew-tap
mkdir -p ~/homebrew-tap/Casks
cp /Users/kathirdev/Documents/projects/Sonar/Casks/sonar.rb ~/homebrew-tap/Casks/sonar.rb
# The cask in the release assets already has the real checksum filled in.
cd ~/homebrew-tap && git add Casks/sonar.rb && git commit -m "Sonar 0.1.0" && git push
```

Then, anywhere:

```sh
brew tap Kathir-D/tap
brew install --cask sonar
```

Verify with `brew list --cask sonar` and confirm `/Applications/Sonar.app` exists. To update later:
`brew upgrade --cask sonar`.

## If you later get a Developer account

Nothing above changes, and nothing above depends on it. Adding a paid membership buys exactly one
thing: the artifact stops being `rejected` by `spctl`, so browser downloads open without a manual
approval step. To take it:

1. Create a **Developer ID Application** certificate in Xcode (Settings › Accounts › Manage
   Certificates). No iCloud sign-in is needed — the Apple ID inside Xcode is enough, and the
   certificate goes to the login keychain, not iCloud Keychain.
2. Add four repository secrets: `APPLE_DEVELOPER_ID`, `APPLE_ID`, `APPLE_TEAM_ID`,
   `APPLE_APP_SPECIFIC_PASSWORD`. `.github/workflows/release.yml` already picks them up and signs,
   notarizes and staples; the `signing-state` step reports which path ran.
3. Re-tag. `sign-release.sh --release` needs `DEVELOPER_ID` and `NOTARY_PROFILE` locally.

---

## If something fails

| Symptom | Cause | Fix |
| --- | --- | --- |
| A user reports "damaged and can't be opened" | They downloaded the zip in a browser, which quarantines it | Have them use `brew install --cask sonar`, or approve once in System Settings › Privacy & Security |
| `brew install --cask sonar` says no such cask | The tap does not exist yet | See [the tap](#6-publish-the-tap) — it is a separate, free GitHub repository |
| `gh release view` shows a placeholder sha | The cask-checksum step did not run | It only runs on tag pushes; a manual dispatch never fills it |

## After the release

- `Casks/sonar.rb` in the release assets has the real checksum in it. Copy it into your tap.
- The audit in [AUTOPAUSE-ENGINE-AUDIT.md](AUTOPAUSE-ENGINE-AUDIT.md) and the triage in
  [RELEASE-TRIAGE.md](RELEASE-TRIAGE.md) list what is still open. The known limitations in the
  README's Auto-Pause section are the user-visible ones.
- The tap is verified on macOS 27 and one machine. Treat 0.1.0 as the release that finds out about
  everyone else's.
- When there is a second release, this is the point to reconsider an in-app updater. Homebrew
  covers cask installs only, and by then you will know how many people that leaves behind.
