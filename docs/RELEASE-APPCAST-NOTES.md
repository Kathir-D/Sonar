# Release: the Sparkle appcast for Sonar 0.1.0

Owner: `agent-appcast`. Scope: `Sparkle/appcast.xml`, `scripts/generate-appcast.sh`,
`Sonar/App/UpdaterManager.swift`, this file.

Read this before cutting `v0.1.0`. Everything here is about making the Sparkle
feed correct, publishable, and invisible to a user who has never released this
app before.

---

## 1. The signing situation on this machine

`sign_update` **is** available, but the private key **cannot be read
unattended**, so nothing here can produce a publishable signature.

```console
$ command -v sign_update
                                    # not on PATH

$ ls -l dist/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/
-rwxr-xr-x  2113088  generate_appcast
-rwxr-xr-x  1328512  generate_keys
-rwxr-xr-x  1360544  sign_update    # universal x86_64 + arm64, runs fine

$ sign_update --help
USAGE: sign-update [--account <account>] [--verify] \
         [--ed-key-file <private-key-file>] [-p] <update-path> [<verify-signature>]
```

The key is in the login keychain, and its `icmt` comment confirms it is the key
the app advertises in `SUPublicEDKey`:

```console
$ security find-generic-password -s "Sparkle" -a "ed25519"
security: SecKeychainSearchCopyNext: The specified item could not be found

$ security find-generic-password -s "https://sparkle-project.org" -a "ed25519"
keychain: "/Users/kathirdev/Library/Keychains/login.keychain-db"
class: "genp"
attributes:
    0x00000007 <blob>="Private key for signing Sparkle updates"
    "acct"<blob>="ed25519"
    "desc"<blob>="private key"
    "icmt"<blob>=... "Public key (SUPublicEDKey value) for this key is:\012\012l8XHojmyhmJREzYTiQSTqepogx5KlO4P9S06gsqk+GQ="
    "svce"<blob>="https://sparkle-project.org"
```

Note the service is `https://sparkle-project.org`, **not** `Sparkle`.

Reading the secret blocks forever:

```console
$ security find-generic-password -s "https://sparkle-project.org" -a ed25519 -g
                                    # no output; killed at 15s, exit 137

$ sign_update /tmp/sonar-payload
                                    # no output, no stderr; killed at 20s, exit 137
```

This is an ACL prompt, not a locked keychain, and not a slow build:

- the login keychain is unlocked (`show-keychain-info` → `no-timeout`) and
  searches against it return instantly (the first command above proved that);
- an item created with `security add-generic-password -A` in a throwaway
  keychain reads back instantly, so unattended reads work in general;
- only *this* item blocks, because `generate_keys` ACL-protected it.

**Consequence:** `scripts/generate-appcast.sh` will not be able to sign on this
machine, or in CI, without one of:

1. an interactive "Allow" on the keychain item (Keychain Access → *Private key
   for signing Sparkle updates* → Access → *Allow all applications*), or
2. the key as a repo secret, which is what the workflow snippet below assumes.

The script handles both, and refuses to write a feed in either failure case.

### The CI secret

`generate_keys -x` exports the key as the base64 of the **32-byte seed** — that
file's contents are exactly what the secret should be:

```sh
generate_keys -x -f ed25519-private-key     # writes base64 32-byte seed
```

```console
$ base64 -d < ed25519-private-key | wc -c
     32
```

Add it as a repository secret named `SPARKLE_EDDSA_PRIVATE_KEY`. The script
accepts the key three ways, because the formats are easy to mix up:

| Source | `sign_update` invocation |
| --- | --- |
| login keychain (default) | `sign_update -p <zip>` |
| `SPARKLE_PRIVATE_KEY` env | `sign_update -p -f <tmpfile> <zip>` |
| `SIGN_UPDATE` env | path to the binary, if it is not on `PATH` |

A 64-byte key is the *legacy* format and a 32-byte key is the current one;
Sparkle's own error message for a 64-byte key is self-contradictory
(`Imported key must be 64 bytes or 96 bytes ... Instead it is 64 bytes
decoded.`), so trust the byte count, not the message.

---

## 2. Single source of truth: `Sparkle/appcast.xml`

The repo previously had two appcasts — the committed `Sparkle/appcast.xml` and
`dist/$VERSION/appcast.xml` — and nothing kept them in agreement.

**Decision: `Sparkle/appcast.xml` is the only feed, and
`scripts/generate-appcast.sh` is its only writer.** The workflow publishes that
one file as the release's `appcast.xml` asset.

Why, given that `SUFeedURL` is a `releases/latest/download/` asset:

- the published copy is what every installed copy of Sonar fetches, so it is the
  only one with any effect on users;
- the committed copy earns its place by making feed changes reviewable in a PR —
  a `length` or a URL changing is exactly the kind of thing a reviewer should
  catch, and it is invisible in a build artifact;
- a second file under `dist/` could only ever be a stale copy, and the two would
  drift the first time someone edited one of them.

The script writes the file in full from a fixed template, so it is idempotent:
re-running for the same version **overwrites** the item rather than appending.
Verified: three consecutive runs leave exactly one `<item>`.

> The template keeps only the current release. Sparkle only ever offers the
> newest item, so history buys nothing here. If a future release needs it, the
> change is to make the template accumulate items — but then idempotency has to
> be re-established deliberately, so do not do it casually.

---

## 3. What the script now refuses to do

Every one of these was tested against a real `dist/0.1.0/Sonar-0.1.0.zip` and
a real (throwaway) ed25519 key; none of them writes a byte to the feed.

| Guard | Why it exists |
| --- | --- |
| `CFBundleVersion` must be all digits | Sparkle orders feed items by it. `scripts/build-app.sh` stamps `git rev-parse --short HEAD`, and the zip currently in `dist/` carries `fba7b8f`. |
| build number ≠ `git rev-parse --short HEAD` | Catches the hash case specifically, even when the hash happens to be all digits (`4026573`) and slips past the check above. |
| build number ≥ the feed's current `sparkle:version` | Stops a rebuild that lowered the counter from producing a feed nobody would be offered. |
| `VERSION` == the zip's `CFBundleShortVersionString` | The tag, `./VERSION` and the built app have to agree. |
| `sign_update` must be found | It is not on `PATH`; the script searches the Sparkle SPM artifact directory and `~/Library/Caches/org.swift.swiftpm`. |
| signing runs under a timeout | The keychain ACL hang above looks exactly like a slow build. Default 180s, `SONAR_SIGN_TIMEOUT` to override. |
| the key is passed by **file**, never by pipe | POSIX gives an asynchronous command `/dev/null` as stdin, so `sign_update`'s `readLine()` got nothing and the key never arrived. This was a real bug during development. |
| output must be 88 base64 chars | An ed25519 signature is 64 bytes. This rejects an error string, an empty result or a prompt that `sign_update` printed to stdout. |
| `sign_update --verify` must exit 0 | It is **silent on success** and prints `Error: ...` on failure, so the exit status is the only signal. Checking for a success *string* silently rejects every good signature. |
| `generate_keys --lookup` == `SUPublicEDKey` | Proves the signing key is the one the shipped app advertises. Keychain path only, because `generate_keys` cannot read a key file. |
| the enclosure URL must contain `/download/v` | `SUFeedURL` is served from `latest/download`; the *item* must be version-pinned or a later release silently repoints it. |
| output must parse (`xmllint`) and hold exactly one `<item>` | Cheap, and it is the last line before the file is trusted. |

The important one: **it never writes a placeholder signature.** An earlier
version of the script wrote `UNSIGNED-PRIVATE-KEY-REQUIRED` into
`sparkle:edSignature` and exited 2 — after having written the file. Sparkle does
not filter unsigned items out of a feed, so that feed would have offered 0.1.0
to every user, downloaded 2.8 MB, and then rejected it at install time with a
validation error. The script now fails *before* writing.

---

## 4. `sparkle:version` for 0.1.0

**The feed must carry whatever integer the corrected `scripts/build-app.sh`
stamps into `CFBundleVersion` — and for 0.1.0 that should be `1`.**

The script derives it from the artifact (`CFBundleVersion` read out of
`Sonar.app/Contents/Info.plist` *inside the zip*), so the feed cannot drift
from the build no matter what scheme is chosen. The committed feed says `1`
because 0.1.0 is the first release and any monotonically increasing integer
works; if the build-number fix lands on a different scheme, the script will
overwrite this and the file will show the change in the release commit.

Do not let the feed and `CFBundleVersion` disagree. Sparkle's rule is: offer the
feed item only when its `sparkle:version` is greater than the installed app's
`CFBundleVersion`. A git hash breaks that comparison in both directions,
depending on the hash.

---

## 5. Required patch to `.github/workflows/release.yml`

**Owner: the agent holding the workflow.** Two edits, shown as one diff.

The appcast step goes **after** notarization and **before** the release upload.

```diff
       - run: scripts/package-release.sh
       # Notarization runs only when the Developer ID secret exists.
       - name: notarize
         run: |
           if [ -z "${DEVELOPER_ID:-}" ]; then
             echo "No APPLE_DEVELOPER_ID secret — skipping notarization (ad-hoc artifact only)."
             exit 0
           fi
           scripts/sign-release.sh --release
         env:
           DEVELOPER_ID: ${{ secrets.APPLE_DEVELOPER_ID }}
           NOTARY_PROFILE: sonar-notary
+      # Must run AFTER notarization and BEFORE the upload: the feed's length
+      # and EdDSA signature describe the exact bytes of the zip users download,
+      # and sign-release.sh re-zips the app after stapling.
+      #
+      # Fails the job if it cannot sign, so an unsigned feed is never uploaded.
+      # `secrets.*` is allowed in a step-level `if`; `env.*` is not, which is
+      # why the condition is on the secret and not on the environment.
+      - name: appcast
+        if: ${{ secrets.SPARKLE_EDDSA_PRIVATE_KEY != '' }}
+        run: scripts/generate-appcast.sh "${GITHUB_REF_NAME#v}"
+        env:
+          SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_EDDSA_PRIVATE_KEY }}
+          # sign_update is not on PATH; the script finds it in the Sparkle
+          # package that scripts/build-app.sh already resolved into dist/.
+          SIGN_UPDATE: ${{ github.workspace }}/dist/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
       - uses: softprops/action-gh-release@v2
         # Only publish on tag pushes; manual dispatches stop after packaging.
         if: startsWith(github.ref, 'refs/tags/')
         with:
-          files: dist/*/Sonar-*.zip,dist/*/SHA256SUMS.txt
+          files: dist/*/Sonar-*.zip,dist/*/SHA256SUMS.txt,Sparkle/appcast.xml
           generate_release_notes: true
```

If a missing signing secret should not block the release, drop the `if:` and use
`continue-on-error: true` instead — the script still refuses to write a feed it
cannot sign, so the worst case is a release with no appcast rather than a
release with a broken one:

```yaml
- name: appcast
  continue-on-error: true
  run: scripts/generate-appcast.sh "${GITHUB_REF_NAME#v}"
  env:
    SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_EDDSA_PRIVATE_KEY }}
```

### Why after notarization, and what it means for length and sha

`scripts/sign-release.sh --release` writes the zip three times:

| line | what it does | effect on the bytes |
| --- | --- | --- |
| 36 | `package-release.sh` → new zip, Developer ID signed | this is the zip that gets submitted, and the one `SHA256SUMS.txt` is written for |
| 40 | `notarytool submit "$ZIP"` | no change |
| 43 | `stapler staple "$APP"` | the app changes |
| 44 | `ditto -c -k … "$APP" "$ZIP"` | **the zip is rewritten with the stapled app** |
| 45 | `stapler staple "$ZIP"` | may rewrite the zip again |

So the artifact that exists *before* `sign-release.sh` runs is not the artifact
users download. An appcast generated before it would carry a `length` and a
signature for bytes that are never served, and Sparkle would fail both the
download-length check and the signature check.

**Generate the appcast last.** After line 45.

Concretely, about integrity in the feed:

- **There is no sha in a Sparkle 2 appcast.** Sparkle 2 dropped
  `sparkle:dsaPublicKey` and the old DSA/`sha` attributes. A Sparkle 2 feed
  carries `sparkle:edSignature` and `length`, and nothing else. Integrity comes
  from the ed25519 signature over the whole file; `length` is only a
  download-completeness check.
- **`SHA256SUMS.txt` is a separate, human-facing artifact** and is not referenced
  by the feed. It is worth getting right on its own — see the bug below.
- **`length` is recomputed from the final zip** by the script, every run. Do not
  hand-edit it.
- **`sparkle:version` is recomputed from the final zip's `CFBundleVersion`**,
  every run, and checked for monotonicity against the committed feed.

### Bug found in `scripts/sign-release.sh` (not mine to fix)

`SHA256SUMS.txt` is **stale after a release-lane build**. `package-release.sh`
writes it at line 36, and line 44 then rewrites the zip out from under it. The
checksum file describes a zip that no longer exists, and it is uploaded as a
release asset.

The fix belongs after the stapling step, in `sign-release.sh`:

```sh
echo "== refresh checksums =="
(cd "$ROOT/dist/$VERSION" && shasum -a 256 "Sonar-$VERSION.zip" > SHA256SUMS.txt)
```

It does not affect the appcast, which never reads that file.

### The repo copy

CI regenerates `Sparkle/appcast.xml` for the asset but does not commit it. That
is deliberate — the published file has to come from the final notarized zip. For
the change to be reviewable, run the script locally, review the diff, and commit
it **before** tagging:

```sh
scripts/package-release.sh
scripts/generate-appcast.sh 0.1.0
git add Sparkle/appcast.xml && git commit -m 'chore: appcast for 0.1.0'
git tag v0.1.0 && git push --tags
```

CI then produces the same file from the same bytes, differing only in `pubDate`
and, if the local build was not notarized, in `length` and the signature.

---

## 6. What a user sees on a 404 / unreachable / unsigned feed

Audited against the vendored Sparkle 2.8.1 source
(`dist/DerivedData/SourcePackages/checkouts/Sparkle`). `Sonar/App/UpdaterManager.swift`
is the only file involved.

**Nothing happens on launch, before or after the change.** `UpdaterManager.shared`
is reached from exactly one place, `AboutPreferencesView`, which is a SwiftUI
`View` — it is not constructed until Preferences › About is opened. The
`SPUStandardUpdaterController` initializer does no network work: it validates
configuration and `dispatch_async`s the first check to a later runloop turn.
A dead feed cannot delay or block launch.

**A scheduled check that fails shows no UI, even unmodified.** `showUpdaterError`
is reached only from `SPUUIBasedUpdateDriver`, and it is gated on `showErrorToUser`,
which for a scheduled check is `_showedUpdate` — set in `uiDriverDidShowUpdate`,
i.e. only once an update has actually been put on screen:

```objc
// SPUScheduledUpdateDriver.m:104
- (void)abortUpdateWithError:(nullable NSError *)error
{
    [_uiDriver abortUpdateWithError:error showErrorToUser:_showedUpdate];
}

// SPUUserInitiatedUpdateDriver.m:134 — always YES
- (void)abortUpdateWithError:(nullable NSError *)error
{
    ...
    [_uiDriver abortUpdateWithError:error showErrorToUser:YES];
}
```

**A user-initiated check does show an alert, and always did** — which is the one
behaviour worth keeping, since the user asked.

Three real defects were fixed:

1. **Update-permission prompt could not be trusted.** `startUpdateCycle` evaluates
   `shouldPrompt` on the first runloop turn after `startUpdater`, and the old code
   only avoided the prompt because `automaticallyChecksForUpdates = true` wrote
   `SUEnableAutomaticChecks` into user defaults *before* that turn. Correct by
   timing, not by design. Now suppressed by returning `false` from
   `updaterShouldPromptForPermissionToCheck(forUpdates:)` — the supported lever.
   This matters for an `LSUIElement` app, where that prompt is a modal alert with
   no Dock icon and no window to raise it from.

2. **The one permitted alert could open behind another app.** Sparkle activates
   the application in exactly one place:

   ```objc
   // SPUStandardUserDriver.m:127 — the only activation in the framework
   - (void)_activateApplication { [NSApp activate]; }
   // ...and it is only called from showUpdatePermissionRequest:
   ```

   Every other alert goes through `-[NSAlert runModal]` with no activation. Now
   `standardUserDriverWillShowModalAlert` calls `NSApp.activate()`.

3. **Failures were logged nowhere by the app.** `didAbortWithError` and
   `didFinishUpdateCycleFor:error:` now log to the `com.KathirD.sonar` `updater`
   category, so "no update offered" and "the check never ran" are
   distinguishable in Console.

Checked and deliberately *not* changed: `SUEnableInstallerLauncherService` is
`true` while the framework ships `Installer.xpc` and `Downloader.xpc`. Sparkle
looks for `Installer Launcher.xpc` (`INSTALLER_LAUNCHER_NAME = Installer` in
`ConfigCommon.xcconfig`), so the key resolves to `Installer.xpc`, which is
present. The misconfiguration check in `startUpdater:` passes, and its
"Unable to Check For Updates" modal is not triggered.

One residual, and it is a real one: **an unsigned enclosure is not filtered out
of a feed.** `filterAppcast:forMacOSAndAllowedChannels:` and
`filterSupportedAppcast:` only test OS version, channel, phase and skips.
Validation happens at *install* time in `SUUpdateValidator`, after the download.
So a feed whose item lacks `sparkle:edSignature` offers the update, downloads it,
then fails with *"EdDSA signature validation of the update failed. The update
will be rejected."* That is exactly why the committed feed is not to be published
as-is, and why the script will not write one.

---

## 7. Verification performed

```console
$ sh -n scripts/generate-appcast.sh && echo OK
OK

$ xmllint --noout Sparkle/appcast.xml && echo OK
OK

# the git-hash build number in the real zip is rejected
$ sh scripts/generate-appcast.sh
generate-appcast: CFBundleVersion is 'fba7b8f', which is not a plain integer
  Sparkle orders feed items by this value, so it must increase monotonically.
  Fix scripts/build-app.sh to stamp an integer (e.g. git rev-list --count HEAD).

# the keychain ACL hang is caught, and nothing is written
$ SONAR_SIGN_TIMEOUT=6 sh scripts/generate-appcast.sh 0.1.0 "" /tmp/…/Sonar-0.1.0.zip
generate-appcast: sign_update blocked for over 6 seconds and was killed
  …                                          # exit 1, feed byte-identical

# full path, throwaway key, and the signature checked straight out of the XML
$ SPARKLE_PRIVATE_KEY=… sh scripts/generate-appcast.sh 0.1.0 "" /tmp/…/Sonar-0.1.0.zip
generate-appcast:   signature verified over all 2877959 bytes
generate-appcast:   wrote …/Sparkle/appcast.xml
$ sed -n 's|.*sparkle:edSignature="\([^"]*\)".*|\1|p' Sparkle/appcast.xml   # 88 chars
$ sign_update --verify /tmp/…/Sonar-0.1.0.zip "$SIG" -f ed25519-private-key
VERIFY OK (exit 0)

# idempotent
$ for i in 1 2 3; do … ; done
run 1 -> items: 1, sparkle:version lines: 1
run 2 -> items: 1, sparkle:version lines: 1
run 3 -> items: 1, sparkle:version lines: 1
```

`Sonar/App/UpdaterManager.swift` was typechecked against the real
`Sparkle.framework` from `dist/DerivedData/Build/Products/Release`, target
`arm64-apple-macos15.0`, `swiftc -typecheck` → exit 0. That is a typecheck of
this file, not a full app build; the project has not been built since the change.
