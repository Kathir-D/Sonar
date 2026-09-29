#!/bin/sh
# Generate the Sparkle 2 appcast for Sonar and commit it to Sparkle/appcast.xml.
#
# Usage:
#   scripts/generate-appcast.sh [version] [zip-url] [zip-path]
#
# Defaults:
#   version   contents of ./VERSION
#   zip-url   https://github.com/Kathir-D/Sonar/releases/download/v<version>/Sonar-<version>.zip
#   zip-path  dist/<version>/Sonar-<version>.zip
#
# Env:
#   SIGN_UPDATE          explicit path to Sparkle's sign_update binary
#   SPARKLE_PRIVATE_KEY  EdDSA private key; when set it is used instead of the
#                        login keychain (this is how CI signs, via a repo secret)
#   SONAR_SIGN_TIMEOUT   seconds to allow sign_update before giving up (180)
#
# Sparkle/appcast.xml is the SINGLE source of truth for the feed. This script
# is its only writer, and the release workflow publishes that one file as the
# `appcast.xml` release asset that SUFeedURL resolves to. There is deliberately
# no second copy under dist/: two files would drift, and only the published one
# matters to users.
#
# The script refuses to write anything it cannot sign, so a feed that lacks a
# real sparkle:edSignature can never reach a release.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(tr -d ' \n' < "$ROOT/VERSION")}"
[ -n "$VERSION" ] || { echo "No version: pass one or write ./VERSION" >&2; exit 1; }

ZIP_URL="${2:-https://github.com/Kathir-D/Sonar/releases/download/v$VERSION/Sonar-$VERSION.zip}"
ZIP="${3:-$ROOT/dist/$VERSION/Sonar-$VERSION.zip}"
APPCAST="$ROOT/Sparkle/appcast.xml"
# Signing reads the EdDSA key from the keychain unless SPARKLE_PRIVATE_KEY is
# set. A keychain item written by generate_keys is ACL-protected, so an
# unattended run blocks on a confirmation dialog instead of failing.
MINUTES="${SONAR_SIGN_TIMEOUT:-180}"

die() { echo "generate-appcast: $*" >&2; exit 1; }
note() { echo "generate-appcast: $*" >&2; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

[ -f "$ZIP" ] || die "no zip at $ZIP
  This script signs and describes the FINAL artifact, so run it after
  scripts/package-release.sh, and after scripts/sign-release.sh --release
  when notarizing. sign-release.sh re-zips the app at least twice (once to
  submit, once after stapling), so a feed generated before it has run
  describes bytes the user will never download."

LENGTH="$(stat -f %z "$ZIP")"
[ "$LENGTH" -gt 0 ] || die "$ZIP is empty"

# Read the real build metadata out of the artifact, not out of dist/Sonar.app,
# so the feed can only ever describe the bytes that are actually being shipped.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
unzip -p "$ZIP" "Sonar.app/Contents/Info.plist" > "$TMP/Info.plist" 2>/dev/null \
    || die "cannot read Sonar.app/Contents/Info.plist out of $ZIP"

plist() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$TMP/Info.plist" 2>/dev/null || true
}

BUILD_NUMBER="$(plist CFBundleVersion)"
SHORT_VERSION="$(plist CFBundleShortVersionString)"
MIN_SYSTEM="$(plist LSMinimumSystemVersion)"
PUBLIC_ED_KEY="$(plist SUPublicEDKey)"

[ -n "$BUILD_NUMBER" ] || die "the zip has no CFBundleVersion"
[ -n "$SHORT_VERSION" ] || die "the zip has no CFBundleShortVersionString"
[ -n "$MIN_SYSTEM" ] || die "the zip has no LSMinimumSystemVersion, so the feed cannot state an honest minimumSystemVersion"

[ "$SHORT_VERSION" = "$VERSION" ] || die "VERSION is $VERSION but the zip ships $SHORT_VERSION
  The tag, ./VERSION and the built app have to agree before a feed is written."

[ -n "$PUBLIC_ED_KEY" ] || die "the zip has no SUPublicEDKey, so Sparkle would reject every update"

# SUFeedURL serves this very file from releases/latest/download, so the item's
# own URL has to be version-pinned. A latest/download item URL would let a later
# release silently repoint this one at different bytes.
case "$ZIP_URL" in
    *'/download/v'*) ;;
    *) die "zip-url is '$ZIP_URL'
  The feed itself is served from releases/latest/download, but the enclosure URL
  must be pinned to the release that carries these exact bytes:
    https://github.com/Kathir-D/Sonar/releases/download/v$VERSION/Sonar-$VERSION.zip"
        ;;
esac

# ---------------------------------------------------------------------------
# sparkle:version has to be a monotonically increasing integer.
#
# Sparkle compares CFBundleVersion between the installed app and each feed
# item to decide what is newer. scripts/build-app.sh used to stamp
# `git rev-parse --short HEAD` here, which is neither an integer nor monotonic
# (the 0.1.0 zip in this repo carries fba7b8f), so a correct feed still would
# never offer an update. Refuse to encode a build number that cannot work.
# ---------------------------------------------------------------------------

case "$BUILD_NUMBER" in
    ''|*[!0-9]*)
        die "CFBundleVersion is '$BUILD_NUMBER', which is not a plain integer
  Sparkle orders feed items by this value, so it must increase monotonically.
  Fix scripts/build-app.sh to stamp an integer (e.g. git rev-list --count HEAD)."
        ;;
esac

HEAD_SHORT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || true)"
if [ -n "$HEAD_SHORT" ] && [ "$BUILD_NUMBER" = "$HEAD_SHORT" ]; then
    die "CFBundleVersion is '$BUILD_NUMBER', which is this commit's short git hash
  That is the old scripts/build-app.sh behaviour. A hash cannot order updates,
  so no feed can make Sparkle offer this build. Stamp an increasing integer."
fi

# Refuse to go backwards against a version already in the feed, so a re-run for
# the same release is fine but a rebuild that lowered the counter is not.
PREV_MAX="$(sed -n 's|.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*|\1|p' \
    "$APPCAST" 2>/dev/null | sort -n | tail -1)"
PREV_MAX="${PREV_MAX:-0}"
if [ "$BUILD_NUMBER" -lt "$PREV_MAX" ]; then
    die "CFBundleVersion $BUILD_NUMBER is lower than $PREV_MAX, already published in $APPCAST
  Sparkle would never offer this build to users on $PREV_MAX. Bump the build counter."
fi

# ---------------------------------------------------------------------------
# Locate sign_update
# ---------------------------------------------------------------------------

find_sign_update() {
    if [ -n "${SIGN_UPDATE:-}" ]; then
        printf '%s\n' "$SIGN_UPDATE"
        return
    fi
    command -v sign_update 2>/dev/null && return
    for candidate in \
        "$ROOT/dist/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" \
        "$ROOT/dist/DerivedData/SourcePackages/checkouts/Sparkle/bin/sign_update" \
        "$HOME/Library/Caches/org.swift.swiftpm/artifacts/sparkle/bin/sign_update"
    do
        [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return; }
    done
    for candidate in "$HOME"/Library/Caches/org.swift.swiftpm/artifacts/*/bin/sign_update; do
        [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return; }
    done
    return 1
}

SIGN_UPDATE_BIN="$(find_sign_update || true)"

[ -n "$SIGN_UPDATE_BIN" ] && [ -x "$SIGN_UPDATE_BIN" ] || die "cannot find Sparkle's sign_update
  sign_update ships inside the Sparkle package but is not on PATH here. Try one of:
    export SIGN_UPDATE=\"\$ROOT/dist/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update\"
    xcodebuild -resolvePackageDependencies   # to populate dist/DerivedData
  Generate one with Sparkle's generate_keys if the app has never been signed."

# ---------------------------------------------------------------------------
# Sign, under a timeout.
#
# sign_update reads the private key from the login keychain by default, and a
# keychain item created by generate_keys is ACL-protected: an unattended
# process (CI, a script, an agent) blocks forever on the confirmation dialog
# instead of failing. Never let that look like a slow build.
# ---------------------------------------------------------------------------

run_with_timeout() {
    _seconds="$1"; shift
    # stdin is explicitly /dev/null: an asynchronous command would otherwise be
    # given /dev/null by the shell anyway, and a keychain prompt must never be
    # able to read from a pipe. Keys are passed by file, not by stdin.
    "$@" > "$TMP/out" 2> "$TMP/err" < /dev/null &
    _pid=$!
    _waited=0
    while kill -0 "$_pid" 2>/dev/null; do
        if [ "$_waited" -ge "$_seconds" ]; then
            kill -9 "$_pid" 2>/dev/null || true
            echo "TIMEOUT"
            return 124
        fi
        sleep 1
        _waited=$((_waited + 1))
    done
    wait "$_pid" 2>/dev/null || return 1
    cat "$TMP/out"
    return 0
}

KEY_FILE=""
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    # Hand the key over as a file. A pipe cannot be used: sign_update reads the
    # key with readLine(), and a backgrounded command's stdin is /dev/null.
    (umask 077 && printf '%s' "$SPARKLE_PRIVATE_KEY" > "$TMP/ed25519.key")
    KEY_FILE="$TMP/ed25519.key"
fi

sign() {
    if [ -n "$KEY_FILE" ]; then
        run_with_timeout "$MINUTES" "$SIGN_UPDATE_BIN" -p -f "$KEY_FILE" "$ZIP"
    else
        run_with_timeout "$MINUTES" "$SIGN_UPDATE_BIN" -p "$ZIP"
    fi
}

KEY_SOURCE="login keychain (account ed25519)"
[ -n "${SPARKLE_PRIVATE_KEY:-}" ] && KEY_SOURCE="SPARKLE_PRIVATE_KEY"

note "signing $ZIP ($LENGTH bytes) with $SIGN_UPDATE_BIN"
note "  private key from: $KEY_SOURCE"

set +e
SIGNATURE="$(sign)"
SIGN_STATUS=$?
set -e

sign_diagnostics() {
    # sign_update's own errors are print()s, i.e. stdout, not stderr.
    sed 's/^/    /' "$TMP/out" 2>/dev/null
    sed 's/^/    /' "$TMP/err" 2>/dev/null
}

if [ "$SIGN_STATUS" = "124" ]; then
    sign_diagnostics
    die "sign_update blocked for over $MINUTES seconds and was killed
  The EdDSA private key is in the keychain but its ACL needs an interactive
  confirmation that never arrived. Either allow the signing binary once by hand
  (Keychain Access > the 'Private key for signing Sparkle updates' item > Access),
  or sign without a keychain:
    export SPARKLE_PRIVATE_KEY=\"\$(cat ed25519-private-key)\"
    scripts/generate-appcast.sh $VERSION"
fi

if [ "$SIGN_STATUS" != "0" ]; then
    sign_diagnostics
    die "sign_update failed (exit $SIGN_STATUS)
  No feed was written. Sparkle refuses an update whose enclosure carries no
  valid signature, so publishing an unsigned feed would offer users a download
  that is then rejected. Fix signing, then re-run."
fi

SIGNATURE="$(printf '%s' "$SIGNATURE" | tr -d ' \t\r\n')"

# An ed25519 signature is 64 bytes, base64 = 88 characters. Anything else means
# sign_update printed something that is not a signature (an error string, a
# prompt, empty output) and would otherwise be pasted straight into the feed.
case "$SIGNATURE" in
    ''|*[!A-Za-z0-9+/=]*)
        die "sign_update did not return a base64 signature (got ${#SIGNATURE} chars)
  Refusing to write it into the feed. Raw output was:
$(printf '%s' "$SIGNATURE" | head -c 200 | sed 's/^/    /')"
        ;;
esac
[ "${#SIGNATURE}" -eq 88 ] || die "signature is ${#SIGNATURE} chars, expected 88 for an ed25519 signature
  Refusing to write it into the feed."

# Verify our own work before the feed can point at it. sign_update --verify is
# silent on success and prints "Error: ..." on failure, so the exit status is
# the signal, not the output.
if [ -n "$KEY_FILE" ]; then
    set +e
    run_with_timeout "$MINUTES" "$SIGN_UPDATE_BIN" --verify -f "$KEY_FILE" "$ZIP" "$SIGNATURE" \
        > "$TMP/verify" 2>&1
    VERIFY_STATUS=$?
    set -e
else
    set +e
    run_with_timeout "$MINUTES" "$SIGN_UPDATE_BIN" --verify "$ZIP" "$SIGNATURE" \
        > "$TMP/verify" 2>&1
    VERIFY_STATUS=$?
    set -e
fi
[ "$VERIFY_STATUS" = "0" ] || die "the signature just produced does not verify:
$(sed 's/^/    /' "$TMP/verify" 2>/dev/null)
  Nothing was written. The public key in the app and the private key used to
  sign do not match, so Sparkle would reject the update."
note "  signature verified over all $LENGTH bytes"

# Prove the signing key is the one the shipped app advertises. generate_keys
# --lookup derives the public key from the keychain item, which is the real
# maintainer path. It cannot read a key file, so under SPARKLE_PRIVATE_KEY the
# operator has to confirm it by hand; both values are printed either way.
GENERATE_KEYS="$(dirname "$SIGN_UPDATE_BIN")/generate_keys"
if [ -z "${SPARKLE_PRIVATE_KEY:-}" ] && [ -x "$GENERATE_KEYS" ]; then
    set +e
    LOOKUP="$(run_with_timeout 30 "$GENERATE_KEYS" --lookup 2>/dev/null | tr -d ' \t\r\n')"
    set -e
    if [ -n "$LOOKUP" ]; then
        [ "$LOOKUP" = "$PUBLIC_ED_KEY" ] || die "the keychain's public key does not match the app
    keychain: $LOOKUP
    app     : $PUBLIC_ED_KEY
  Signing with this key would produce a feed the shipped app rejects. Nothing
  was written. Either fix SUPublicEDKey in Sonar/Info.plist or sign with the
  matching private key."
        note "  signing key matches SUPublicEDKey in the app"
    fi
fi
note "  SUPublicEDKey shipped in the app: $PUBLIC_ED_KEY"

# ---------------------------------------------------------------------------
# Write the feed
#
# A fixed single-item template. Re-running for the same version overwrites the
# item in place, so a re-release can never append a second 0.1.0 entry, and
# there is no merge step that could get that wrong. Only the current release
# is kept; Sparkle only ever offers the newest item anyway.
# ---------------------------------------------------------------------------

PUB_DATE="$(LC_ALL=C date -u +'%a, %d %b %Y %H:%M:%S +0000')"

cat > "$APPCAST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<!-- GENERATED by scripts/generate-appcast.sh — edit that script, not this file.
     Published as the 'appcast.xml' asset of the latest GitHub release, which is
     what SUFeedURL in Sonar/Info.plist points at. -->
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Sonar</title>
    <link>https://github.com/Kathir-D/Sonar</link>
    <description>Updates for Sonar, the menu-bar Spotify player with hybrid auto-pause.</description>
    <language>en</language>
    <item>
      <title>Sonar $SHORT_VERSION</title>
      <description><![CDATA[
        <h2>Sonar $SHORT_VERSION</h2>
        <p>Sonar puts the current Spotify track in your macOS menu bar, with a click-to-open
        playback panel, and steps out of the way when something else starts making noise:
        it fades the music down, pauses it, and fades it back in once the room goes quiet.</p>
        <h3>Now playing</h3>
        <ul>
          <li>Artist and title in the menu bar, with app icon, playing and liked indicators.</li>
          <li>Click the menu-bar item for artwork, play/pause, next, previous, like, and a
              scrubbable playback position.</li>
          <li>Global keyboard shortcuts for play/pause, next, previous, like and unlike.</li>
          <li>Compact two-row or single-row layout, with a configurable maximum width.</li>
        </ul>
        <h3>Auto-Pause</h3>
        <ul>
          <li>Hybrid detection: a Core Audio tap measures real loudness, and an
              <code>IsRunningOutput</code> process poll catches anything the tap misses.</li>
          <li>Two presets, or your own. <strong>Fade</strong> eases the music down and back up;
              <strong>Instant</strong> cuts it out and back in the moment. Anything you tune
              yourself shows as <strong>Custom</strong>.</li>
          <li>Configurable trigger delay, resume delay, fade length and loudness threshold,
              behind <em>Advanced settings</em>.</li>
          <li>Per-app rules: <em>All apps</em> or <em>Only these apps</em>, with a live
              &ldquo;heard in the last 3 minutes&rdquo; finder.</li>
          <li>Correct ownership: Sonar resumes only if it paused that same Spotify process.
              A manual pause, volume change, player restart or quit hands playback back.</li>
        </ul>
        <h3>Permissions</h3>
        <p>Auto-Pause needs two permissions and will not switch on without both. Preferences &rsaquo;
        Auto-Pause shows each one with its live state.</p>
        <ul>
          <li><strong>Screen &amp; System Audio Recording</strong> &mdash; owns the Core Audio tap, so
              Sonar can measure how loud other apps are. Without it, detection falls back to
              process polling, which cannot tell silence from sound.</li>
          <li><strong>Automation</strong> (Apple Events) for <code>com.spotify.client</code>
              &mdash; every Spotify action is an Apple Event. It is also how the menu bar reads the
              current track.</li>
        </ul>
        <h3>Requirements</h3>
        <ul>
          <li>macOS $MIN_SYSTEM or later.</li>
          <li>The Spotify desktop app for macOS. Premium is not required.</li>
        </ul>
        <p>This is the first release of Sonar. Sonar is a fork of
        <a href="https://github.com/kmikiy/SpotMenu">SpotMenu</a> by @kmikiy (MIT); the menu-bar
        UI, preference panes and Spotify controller are its work, kept as-is. The Auto-Pause
        engine is new code on top of that base. Please report anything that misbehaves at
        <a href="https://github.com/Kathir-D/Sonar/issues">github.com/Kathir-D/Sonar/issues</a>.</p>
      ]]></description>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$SHORT_VERSION</sparkle:shortVersionString>
      <enclosure
        url="$ZIP_URL"
        length="$LENGTH"
        type="application/octet-stream"
        sparkle:edSignature="$SIGNATURE" />
    </item>
  </channel>
</rss>
EOF

# ---------------------------------------------------------------------------
# Refuse to leave a feed that would misbehave in the app
# ---------------------------------------------------------------------------

xmllint --noout "$APPCAST" 2>/dev/null || die "wrote $APPCAST but it does not parse as XML"

ITEM_COUNT="$(grep -c '<item>' "$APPCAST" || true)"
[ "$ITEM_COUNT" = "1" ] || die "wrote $APPCAST with $ITEM_COUNT items, expected exactly 1"

grep -q 'sparkle:edSignature="[A-Za-z0-9+/=]\{88\}"' "$APPCAST" \
    || die "wrote $APPCAST without a well-formed sparkle:edSignature"

note "wrote $APPCAST"
note "  Sonar $SHORT_VERSION, sparkle:version $BUILD_NUMBER, $LENGTH bytes"
note "  $ZIP_URL"
note "  publish it as the 'appcast.xml' asset of the release, and only after this succeeded"
