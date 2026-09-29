# Releasing Sonar

Everything that has to be true before `git tag v0.1.0`, and what the tag does. Written for
Sonar 0.1.0, the first release; later releases only need steps 1 and 8.

The short version: **the code is ready, and the release is blocked on credentials that live in
your Apple Developer account, not in the repository.** A tag without them produces an ad-hoc,
un-notarized build that Gatekeeper refuses to open on every other Mac, and a cask that cannot
install. So do not tag until step 1 is done.

---

## What is already verified

| | Status |
| --- | --- |
| Engine test suite | 272 tests, green. No hardware, no permission, no audio needed |
| App build | `xcodebuild` clean, no new warnings |
| End-to-end behaviour | `scripts/autopause-smoke.sh`: pause in **485 ms**, resume in **498 ms**, Instant preset, against a real tone through the real output device |
| Release pipeline | `build-app.sh` → `package-release.sh` → `sign-release.sh` → `generate-appcast.sh`, dry-run end to end with a throwaway signing key |
| `CFBundleVersion` | An increasing integer, not a git hash — Sparkle can compare it (this silently broke before) |
| Cask, feed, workflow | Cask checksum filled in by the release run; appcast published after notarization; notary credentials created on the runner |
| Documentation | README, and [HOW-AUTOPAUSE-WORKS.md](HOW-AUTOPAUSE-WORKS.md) for the engine |

## What is NOT verified, and cannot be from here

This machine has **no signing identity** and the repository has **no secrets**. Developer ID
signing, notarization and a signed Sparkle feed therefore have never been executed — only the
code path around them. They are the last three steps below and they are all credentials.

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

## 3. The Sparkle signing key (once)

Auto-update is signed with an EdDSA key whose **public** half is already compiled into the app
(`SUPublicEDKey` in `Sonar/Info.plist`), so this key must be the matching **private** half or every
update will be rejected. It lives in your login keychain and is deliberately not in the repository.

The keychain copy cannot be read non-interactively — it was created with an ACL that asks for
confirmation. Either export it once, here, in a terminal you are sitting at:

```sh
security find-generic-password -s "https://sparkle-project.org" -a ed25519 -w
# click "Always Allow" when the keychain asks
```

then

```sh
gh secret set SPARKLE_EDDSA_PRIVATE_KEY < /path/to/the/key
```

**Do not paste that key into a chat, a commit, or an issue.** It is the only thing standing between
an attacker and a malicious update for every user.

## 4. Check the release will be signed

```sh
git log --oneline -1                  # note the commit
grep -c REPLACE_WITH_RELEASE_SHA256 Casks/sonar.rb   # 1 is expected: the run fills it in
cat VERSION                           # 0.1.0
```

The placeholder in the cask is filled in by the release run itself, so it is correct to leave it.

## 5. Dry-run the whole thing, without publishing

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
- the appcast step either succeeding or being skipped for want of `SPARKLE_EDDSA_PRIVATE_KEY`

## 6. Sanity-check the numbers once more

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/AutoPauseEngine

sh scripts/autopause-smoke.sh --allow-playback
```

Expect **~0.5 s** to pause and resume. Anything above 2 s means detection is not actually
measuring loudness; the smoke test says so rather than passing quietly. **Audio is a shared global
resource: never run this while anything else is playing sound on the machine.**

## 7. Ship it

```sh
git tag -a v0.1.0 -m "Sonar 0.1.0"
git push origin v0.1.0
gh run watch
```

The workflow builds with your Developer ID, notarizes, staples, publishes the appcast and the
checksums, and uploads the cask with its real checksum filled in.

## 8. Verify the release as a user would

```sh
gh release view v0.1.0                     # zip + SHA256SUMS + appcast attached
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

## 9. Announce, if you want to

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
| Sparkle offers an update and then fails | The feed was signed with a key that is not the app's `SUPublicEDKey` | Re-export the private key from the same keychain item |
| Update never offered | `CFBundleVersion` did not increase | It is the commit count locally and the CI run number on a tag; check `Print :CFBundleVersion` in the built app |

## After the release

- `Sparkle/appcast.xml` in the repository is the feed that was published. Review it, and commit any
  change made by hand — the generator is the only writer.
- The audit in [AUTOPAUSE-ENGINE-AUDIT.md](AUTOPAUSE-ENGINE-AUDIT.md) and the triage in
  [RELEASE-TRIAGE.md](RELEASE-TRIAGE.md) list what is still open. The known limitations in the
  README's Auto-Pause section are the user-visible ones.
- The tap is verified on macOS 27 and one machine. Treat 0.1.0 as the release that finds out about
  everyone else's.
