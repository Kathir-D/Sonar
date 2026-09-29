# Releasing Sonar

Everything that has to be true before `git tag v0.1.0`, and what the tag does. Written for
Sonar 0.1.0, the first release; later releases only need step 1 and the tag.

The short version: **the code is ready, and the release is blocked on credentials that live in
your Apple Developer account, not in the repository.** A tag without them produces an ad-hoc,
un-notarized build that Gatekeeper refuses to open on every other Mac, and a cask that cannot
install. So do not tag until step 1 is done.

**Sonar has no in-app updater.** There is no update feed, no EdDSA signing key and no appcast.
Updates come from `brew upgrade --cask sonar` or the releases page, which is what
[About](Sonar/Preferences/AboutPreferencesView.swift) tells the user. That decision is why this
runbook is four secrets long instead of five, and why the release pipeline is short enough to
read in one sitting.

---

## What is already verified

| | Status |
| --- | --- |
| Engine test suite | 272 tests, green. No hardware, no permission, no audio needed |
| App build | `xcodebuild` clean, no new warnings |
| End-to-end behaviour | `scripts/autopause-smoke.sh`: pause in **485 ms**, resume in **498 ms**, Instant preset, against a real tone through the real output device |
| Release pipeline | `build-app.sh` → `package-release.sh` → `sign-release.sh`, dry-run end to end; 10 CI steps, no feed to sign |
| `CFBundleVersion` | An increasing integer, not a git hash (this silently broke before) |
| Cask, workflow | Cask checksum filled in by the release run; notary credentials created on the runner; a tag with a missing secret fails instead of shipping ad-hoc |
| Documentation | README, and [HOW-AUTOPAUSE-WORKS.md](HOW-AUTOPAUSE-WORKS.md) for the engine |

## What is NOT verified, and cannot be from here

This machine has **no signing identity** and the repository has **no secrets**. Developer ID
signing and notarization therefore have never been executed — only the code path around them.
They are the last two steps below and they are all credentials.

---

## 1. The Apple Developer account (one-time, ~20 min)

Needed for a build anyone else can open. A free personal team is not enough: notarization
requires a paid membership.

1. Enrol at <https://developer.apple.com/programs/> if you have not already.
2. Create a **Developer ID Application** certificate. Easiest is Xcode:
   **Xcode › Settings › Accounts › [your Apple ID] › Manage Certificates › + › Developer ID
   Application**, then double-click the created certificate to add it to your keychain.
   Verify with:

   ```sh
   security find-identity -v -p codesigning
   # expect exactly one line ending "(Developer ID Application: ...)"
   ```

3. Create an **app-specific password** for notarization: <https://appleid.apple.com> › Sign-In
   and Security › App-Specific Passwords. Apple will show it once.
4. Find your **Team ID** at <https://developer.apple.com/account>.

## 2. Put the credentials in GitHub secrets (once)

```sh
gh secret set APPLE_DEVELOPER_ID                  # e.g. "Developer ID Application: Name (TEAM)"
gh secret set APPLE_ID                            # your Apple ID email
gh secret set APPLE_TEAM_ID                       # 10 chars, from step 1.4
gh secret set APPLE_APP_SPECIFIC_PASSWORD         # from step 1.3
```

There is no fifth secret. Nothing about an update feed needs signing.

## 3. Check the release will be signed

```sh
git log --oneline -1                  # note the commit
grep -c REPLACE_WITH_RELEASE_SHA256 Casks/sonar.rb   # 1 is expected: the run fills it in
cat VERSION                           # 0.1.0
```

The placeholder in the cask is filled in by the release run itself, so it is correct to leave it.

## 4. Dry-run the whole thing, without publishing

Tag pushes publish. To rehearse without publishing, dispatch the workflow manually — it packages
and signs but the publish step is skipped for anything that is not a tag:

```sh
gh workflow run release.yml
gh run watch
```

Check the log for:

- `BUILD SUCCEEDED`
- `notarytool submit ... status: Accepted` — the line that actually matters
- `spctl -a -vv` passing
- the `cask-checksum` step filling in `Casks/sonar.rb` and finding no placeholder left

## 5. Sanity-check the numbers once more

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/AutoPauseEngine

sh scripts/autopause-smoke.sh --allow-playback
```

Expect **~0.5 s** to pause and resume. Anything above 2 s means detection is not actually
measuring loudness; the smoke test says so rather than passing quietly. **Audio is a shared global
resource: never run this while anything else is playing sound on the machine.**

## 6. Ship it

```sh
git tag -a v0.1.0 -m "Sonar 0.1.0"
git push origin v0.1.0
gh run watch
```

The workflow builds with your Developer ID, notarizes, staples, and uploads the zip, the checksums
and the cask with its real checksum filled in.

## 7. Verify the release as a user would

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

## 8. Announce, if you want to

The cask installs with:

```sh
brew install --cask sonar
```

which needs a `homebrew-tap` repository — the cask is written here, but Homebrew resolves
`brew install --cask` from a tap. Publishing a tap is a separate repository and is not part of this
release. Until it exists, point people at the GitHub release zip.

---

## If something fails

| Symptom | Cause | Fix |
| --- | --- | --- |
| `no keychain profile: sonar-notary` | The workflow is older than the commit that creates it | Confirm `notary-credentials` is in `.github/workflows/release.yml` before `notarize` |
| `Invalid Signature` from notarytool | Signed with a different identity than the one uploaded, or the zip was rebuilt after signing | `sign-release.sh` signs then zips; do not re-zip by hand afterwards |
| `spctl` rejects the app | Not stapled, or notarized but not the stapled copy uploaded | The stapled app is what is zipped; upload *that* zip |
| Users see "damaged and can't be opened" | Ad-hoc build, so no notarization happened — check `APPLE_DEVELOPER_ID` was set | Set the secret and re-tag |
| `Refusing to publish vX.Y.Z` | One of the four Apple secrets is missing | `gh secret list`; the guard names the ones it cannot see |
| The tag published an ad-hoc build | The guard was added after that release | Bump `VERSION` and cut a new tag |

## After the release

- `Casks/sonar.rb` in the release assets has the real checksum in it. Copy it into your tap.
- The audit in [AUTOPAUSE-ENGINE-AUDIT.md](AUTOPAUSE-ENGINE-AUDIT.md) and the triage in
  [RELEASE-TRIAGE.md](RELEASE-TRIAGE.md) list what is still open. The known limitations in the
  README's Auto-Pause section are the user-visible ones.
- The tap is verified on macOS 27 and one machine. Treat 0.1.0 as the release that finds out about
  everyone else's.
- When there is a second release, this is the point to reconsider an in-app updater. Homebrew
  covers cask installs only, and by then you will know how many people that leaves behind.
