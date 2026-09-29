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

# The build phase above stamps CFBundleVersion, but it stamps the *intermediate*
# bundle under dist/DerivedData/Build/Intermediates.noindex. Xcode only copies
# that into dist/DerivedData/Build/Products/Release when it decides the app
# needs rebuilding - and "running swift test first" is enough to make it decide
# that, because the local package's state changed. The phase still runs (it is
# marked always-run), it stamps the intermediate plist, and the copy is skipped.
# build-app.sh then ships a bundle whose build number is whatever
# CURRENT_PROJECT_VERSION says.
#
# So re-assert the number on the copy that actually ships, and fail loudly
# rather than publish a build that cannot be ordered against a later one.
PLIST="$ROOT/dist/Sonar.app/Contents/Info.plist"
expected_build_number="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || true)}"
if [ -n "$expected_build_number" ]; then
    actual_build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || echo '')"
    if [ "$actual_build_number" != "$expected_build_number" ]; then
        echo "CFBundleVersion was $actual_build_number, expected $expected_build_number" >&2
        echo "(Xcode skipped copying the bundle into Products; re-stamping the copy)" >&2
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $expected_build_number" "$PLIST"
        codesign --force --sign "$IDENTITY" "$ROOT/dist/Sonar.app"
    fi
elif [ -z "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || echo '')" ]; then
    echo "error: could not determine or stamp CFBundleVersion" >&2
    exit 1
fi

codesign -v "$ROOT/dist/Sonar.app"
echo "Built $ROOT/dist/Sonar.app (version $VERSION, identity $IDENTITY)"
echo "  CFBundleVersion: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/dist/Sonar.app/Contents/Info.plist")"
