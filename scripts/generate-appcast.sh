#!/bin/sh
# Generate Sparkle 2 appcast.xml for a release zip.
# Usage: scripts/generate-appcast.sh <version> <zip-url>
# Signs with `sign_update` (Sparkle CLI) when available; otherwise writes the
# enclosure with an UNSIGNED placeholder and exits 2 with instructions.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: generate-appcast.sh <version> <zip-url>}"
ZIP_URL="${2:?usage: generate-appcast.sh <version> <zip-url>}"
ZIP="$ROOT/dist/$VERSION/Sonar-$VERSION.zip"
OUT="$ROOT/dist/$VERSION/appcast.xml"

[ -f "$ZIP" ] || { echo "Missing $ZIP — run scripts/package-release.sh first" >&2; exit 1; }
LENGTH="$(stat -f %z "$ZIP")"
DATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"

SIGN_update="$(command -v sign_update || true)"
if [ -n "$SIGN_update" ]; then
    SIG="$("$SIGN_update" "$ZIP")"
else
    SIG="UNSIGNED-PRIVATE-KEY-REQUIRED"
fi

cat > "$OUT" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Sonar updates</title>
    <link>$ZIP_URL</link>
    <description>Sonar auto-pause for Spotify.</description>
    <language>en</language>
    <item>
      <title>Sonar $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$(git -C "$ROOT" rev-list --count HEAD)</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <enclosure url="$ZIP_URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIG" />
    </item>
  </channel>
</rss>
EOF

echo "Wrote $OUT"
if [ "$SIG" = "UNSIGNED-PRIVATE-KEY-REQUIRED" ]; then
    echo "NOTE: enclosure is UNSIGNED. Generate a Sparkle EdDSA key (Sparkle's generate_keys), set SUPublicEDKey in Sonar/Info.plist, install sign_update, and re-run." >&2
    exit 2
fi
