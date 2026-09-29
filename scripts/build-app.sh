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

# ARCHS is pinned explicitly, and ARCHS is what the release must be.
#
# Without a -destination, xcodebuild picks "the first of multiple matching
# destinations" and that was arch=arm64, so the released Sonar-0.1.0.zip
# contained a Non-fat arm64 binary: it could not run on an Intel Mac at all,
# and nothing in the build or the workflow noticed. ONLY_ACTIVE_ARCH=YES is
# only in the Debug config, so the cause was the implicit destination, not
# that setting.
#
# A public release has to be universal. KeyboardShortcuts and the local
# AutoPauseEngine package both build for both slices from here, so this is
# just a matter of asking for them.
xcodebuild -project "$ROOT/SpotMenu.xcodeproj" \
    -scheme Sonar \
    -configuration Release \
    -derivedDataPath "$ROOT/dist/DerivedData" \
    -destination "generic/platform=macOS" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
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

# Refuse to ship a single-architecture bundle. This is the check that would
# have caught the arm64-only 0.1.0 release: a public build that cannot run on
# half of the Macs people own, with a green CI run and no error anywhere.
APP_BINARY="$ROOT/dist/Sonar.app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$ROOT/dist/Sonar.app/Contents/Info.plist")"
ARCHS_FOUND="$(lipo -archs "$APP_BINARY" 2>/dev/null | tr ' ' '\n' | grep -E '^(arm64|x86_64)$' | sort | tr '\n' ' ' | sed 's/ $//')"
case "$ARCHS_FOUND" in
    *"arm64"*"x86_64"*|*"x86_64"*"arm64"*)
        echo "Built $(basename "$APP_BINARY") for: $ARCHS_FOUND"
        ;;
    *)
        echo "error: expected a universal arm64+x86_64 binary, got: ${ARCHS_FOUND:-none}" >&2
        echo "       A single-architecture release cannot run on every Mac. Check ARCHS" >&2
        echo "       and -destination in scripts/build-app.sh." >&2
        exit 1
        ;;
esac

codesign -v "$ROOT/dist/Sonar.app"
echo "Built $ROOT/dist/Sonar.app (version $VERSION, identity $IDENTITY)"
echo "  CFBundleVersion: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/dist/Sonar.app/Contents/Info.plist")"
