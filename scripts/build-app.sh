#!/bin/sh
# Build Sonar.app (Release) and inject VERSION.
# Usage: scripts/build-app.sh
# Env: CODE_SIGN_IDENTITY (default "-" = ad-hoc local dev lane).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d ' \n' < "$ROOT/VERSION")"
IDENTITY="${CODE_SIGN_IDENTITY:--}"

# CFBundleVersion must be an INCREASING INTEGER: Sparkle compares build numbers
# to decide whether an update is newer, and the build phase used to stamp the
# git short hash in, which is not a number - so every update check silently
# meant nothing. CI passes its run number; leave it unset locally and the
# phase falls back to the commit count, which is also an integer.
if [ -n "${BUILD_NUMBER:-}" ]; then
    case "$BUILD_NUMBER" in
        ''|*[!0-9]*)
            echo "BUILD_NUMBER must be a positive integer, got '$BUILD_NUMBER'." >&2
            echo "Sparkle compares CFBundleVersion numerically, so a non-number" >&2
            echo "breaks auto-update silently." >&2
            exit 1
            ;;
    esac
fi

xcodebuild -project "$ROOT/SpotMenu.xcodeproj" \
    -scheme Sonar \
    -configuration Release \
    -derivedDataPath "$ROOT/dist/DerivedData" \
    MARKETING_VERSION="$VERSION" \
    BUILD_NUMBER="${BUILD_NUMBER:-}" \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    build

rm -rf "$ROOT/dist/Sonar.app"
cp -R "$ROOT/dist/DerivedData/Build/Products/Release/Sonar.app" "$ROOT/dist/Sonar.app"

# Ad-hoc lane: a sandboxed ad-hoc binary gets library validation applied and
# then refuses to load the embedded Sparkle.framework (its own signing
# identity), so the app dies at dyld with "different Team IDs". Re-sign with
# the dev entitlement set. The release lane is left alone: sign-release.sh
# re-signs all nested code with the Developer ID, which passes validation.
if [ "$IDENTITY" = "-" ]; then
    BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$ROOT/dist/Sonar.app/Contents/Info.plist")"
    DEV_ENTITLEMENTS="$(mktemp)"
    sed "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/g" \
        "$ROOT/Sonar/Sonar-dev.entitlements" > "$DEV_ENTITLEMENTS"
    codesign --force --sign - \
        --entitlements "$DEV_ENTITLEMENTS" \
        "$ROOT/dist/Sonar.app"
    rm -f "$DEV_ENTITLEMENTS"
fi

codesign -v "$ROOT/dist/Sonar.app"
echo "Built $ROOT/dist/Sonar.app (version $VERSION, identity $IDENTITY)"
echo "  CFBundleVersion: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/dist/Sonar.app/Contents/Info.plist")"
