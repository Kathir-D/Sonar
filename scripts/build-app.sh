#!/bin/sh
# Build Sonar.app (Release) and inject VERSION.
# Usage: scripts/build-app.sh
# Env: CODE_SIGN_IDENTITY (default "-" = ad-hoc local dev lane).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d ' \n' < "$ROOT/VERSION")"
BUILD_NUMBER="$(git -C "$ROOT" rev-parse --short HEAD)"
IDENTITY="${CODE_SIGN_IDENTITY:--}"

xcodebuild -project "$ROOT/SpotMenu.xcodeproj" \
    -scheme Sonar \
    -configuration Release \
    -derivedDataPath "$ROOT/dist/DerivedData" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
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
echo "Built $ROOT/dist/Sonar.app (version $VERSION, build $BUILD_NUMBER, identity $IDENTITY)"
