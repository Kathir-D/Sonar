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
echo "Built $ROOT/dist/Sonar.app (version $VERSION, build $BUILD_NUMBER, identity $IDENTITY)"
