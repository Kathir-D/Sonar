#!/bin/sh
# Signing + notarization lanes.
# Usage:
#   scripts/sign-release.sh              # ad-hoc lane (local dev): verify only
#   DEVELOPER_ID="Developer ID Application: Name (TEAM)" \
#   NOTARY_PROFILE="sonar-notary" scripts/sign-release.sh --release
#
# Release lane signs dist/Sonar.app (Hardened Runtime + entitlements),
# re-zips, submits to notarytool, staples, and verifies with spctl.
# Requires: Apple Developer ID cert in keychain, `xcrun notarytool` profile.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d ' \n' < "$ROOT/VERSION")"
APP="$ROOT/dist/Sonar.app"

[ -d "$APP" ] || { echo "Missing $APP — run scripts/build-app.sh first" >&2; exit 1; }

if [ "${1:-}" != "--release" ]; then
    echo "== ad-hoc lane =="
    codesign -dvv "$APP" 2>&1 | head -8
    echo "Note: ad-hoc builds need 'Open Anyway' (System Settings > Privacy & Security) on first run."
    echo "For a distributable build, run with --release + DEVELOPER_ID + NOTARY_PROFILE."
    exit 0
fi

: "${DEVELOPER_ID:?set DEVELOPER_ID to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to your notarytool keychain profile}"

echo "== Developer ID sign =="
codesign --deep --force --options runtime \
    --entitlements "$ROOT/Sonar/Sonar.entitlements" \
    --sign "$DEVELOPER_ID" "$APP"
codesign -vv "$APP"

echo "== re-zip =="
"$ROOT/scripts/package-release.sh"
ZIP="$ROOT/dist/$VERSION/Sonar-$VERSION.zip"

echo "== notarize =="
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "== staple =="
xcrun stapler staple "$APP"
# The zip is rewritten here, so the checksum package-release.sh wrote above now
# describes a file that does not exist. Recompute it, or the published
# SHA256SUMS.txt fails for every user who checks it - which is exactly the
# person trying to verify the download.
COPYFILE_DISABLE=1 ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
xcrun stapler staple "$ZIP" || true
(cd "$(dirname "$ZIP")" && shasum -a 256 "$(basename "$ZIP")" > SHA256SUMS.txt)

echo "== verify =="
spctl -a -vv "$APP"
xcrun stapler validate "$APP"
echo "Release lane done."
