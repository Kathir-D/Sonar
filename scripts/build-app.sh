#!/bin/sh
# Build Sonar.app (Release) and inject VERSION.
# Usage: scripts/build-app.sh
# Env: CODE_SIGN_IDENTITY (default "-" = ad-hoc local dev lane).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d ' \n' < "$ROOT/VERSION")"
IDENTITY="${CODE_SIGN_IDENTITY:--}"

# CFBundleVersion is the build identity shown in About and by Homebrew, so it
# has to be an INCREASING INTEGER. The build phase used to stamp the git short
# hash in, which is not a number. CI passes its run number; leave it unset
# locally and the phase falls back to the commit count, also an integer.
if [ -n "${BUILD_NUMBER:-}" ]; then
    case "$BUILD_NUMBER" in
        ''|*[!0-9]*)
            echo "BUILD_NUMBER must be a positive integer, got '$BUILD_NUMBER'." >&2
            echo "CFBundleVersion is compared numerically, so a non-number" >&2
            echo "cannot be ordered against a later build." >&2
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

# There is deliberately no ad-hoc re-sign step here any more. It existed only
# to work around the embedded Sparkle.framework, whose separate signing
# identity made dyld apply library validation and refuse to load it under an
# ad-hoc host. Sonar now embeds no framework, so a build is a single signing
# identity and library validation passes on its own.

codesign -v "$ROOT/dist/Sonar.app"
echo "Built $ROOT/dist/Sonar.app (version $VERSION, identity $IDENTITY)"
echo "  CFBundleVersion: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/dist/Sonar.app/Contents/Info.plist")"
