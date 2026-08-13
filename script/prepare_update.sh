#!/usr/bin/env bash
# Prepares the notarized public DMG and a signed Sparkle appcast for a GitHub release.
# This deliberately does not publish anything: upload the asset first, then replace the
# live appcast, so clients can never observe a feed whose download URL still returns 404.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Whisper.xcodeproj"
source "$ROOT_DIR/script/update_common.sh"
REPOSITORY="limingyi1225/whisper-ml"
RELEASE_BRANCH="main"
SOURCE_DMG="${WHISPER_UPDATE_DMG:-$ROOT_DIR/dist/Whisper-public.dmg}"
EXPORTED_APP="${WHISPER_UPDATE_APP:-$ROOT_DIR/build/public/developer-id/Whisper.app}"
LIVE_APPCAST="${WHISPER_UPDATE_APPCAST:-$ROOT_DIR/updates/appcast.xml}"
OUTPUT_DIR="${WHISPER_UPDATE_OUTPUT_DIR:-$ROOT_DIR/dist/update}"
NOTES_FILE="${1:-}"

if [ "$#" -gt 1 ] || { [ -n "$NOTES_FILE" ] && [ ! -f "$NOTES_FILE" ]; }; then
  echo "usage: $0 [release-notes.md]" >&2
  exit 2
fi
if [ ! -f "$SOURCE_DMG" ] || [ ! -d "$EXPORTED_APP" ]; then
  echo "!! no packaged public release found; run this first:" >&2
  echo "   ./script/package_release.sh --public" >&2
  exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$EXPORTED_APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$EXPORTED_APP/Contents/Info.plist")
PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' \
  "$EXPORTED_APP/Contents/Info.plist" 2>/dev/null || true)
FEED_URL=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' \
  "$EXPORTED_APP/Contents/Info.plist" 2>/dev/null || true)
case "$VERSION" in
  ''|*[!0-9A-Za-z.-]*) echo "!! unsafe marketing version: $VERSION" >&2; exit 1 ;;
esac
case "$BUILD" in
  ''|*[!0-9]*) echo "!! build version must contain only digits: $BUILD" >&2; exit 1 ;;
esac
if [ -z "$PUBLIC_KEY" ]; then
  echo "!! this app predates signed updates; package the current source before preparing it" >&2
  exit 1
fi
EXPECTED_FEED_URL="https://raw.githubusercontent.com/$REPOSITORY/$RELEASE_BRANCH/updates/appcast.xml"
if [ "$FEED_URL" != "$EXPECTED_FEED_URL" ]; then
  echo "!! exported app reads a different update feed:" >&2
  echo "   expected: $EXPECTED_FEED_URL" >&2
  echo "   actual:   ${FEED_URL:-missing}" >&2
  exit 1
fi
LATEST_BUILD=$(sed -n 's#.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*#\1#p' \
  "$LIVE_APPCAST" | awk 'BEGIN { max = 0 } $1 > max { max = $1 } END { print max }')
if [ "$BUILD" -le "$LATEST_BUILD" ]; then
  echo "!! build $BUILD is not newer than the published build $LATEST_BUILD" >&2
  echo "   increment CURRENT_PROJECT_VERSION, then package again" >&2
  exit 1
fi
if grep -Fq "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$LIVE_APPCAST"; then
  echo "!! marketing version $VERSION is already published" >&2
  echo "   increment MARKETING_VERSION, then package again" >&2
  exit 1
fi

resolve_sparkle_tools "$PROJECT" Whisper

# Verifying with sign_update alone is circular: without an explicit key it reads the
# same Keychain private key that generate_appcast just used. First prove that private
# key's public half is exactly the one embedded in the shipped app.
verify_sparkle_signing_key "$PUBLIC_KEY"

ASSET_NAME="Whisper-$VERSION-$BUILD.dmg"
ASSET="$OUTPUT_DIR/$ASSET_NAME"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/whisper-update.XXXXXX")
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

mkdir -p "$OUTPUT_DIR"
cp "$SOURCE_DMG" "$ASSET"
cp "$LIVE_APPCAST" "$STAGING/appcast.xml"
cp "$ASSET" "$STAGING/$ASSET_NAME"
if [ -n "$NOTES_FILE" ]; then
  cp "$NOTES_FILE" "$STAGING/${ASSET_NAME%.dmg}.md"
fi

echo "==> signing update $VERSION ($BUILD)"
"$SPARKLE_GENERATE_APPCAST" \
  --download-url-prefix "https://github.com/$REPOSITORY/releases/download/v$VERSION/" \
  --link "https://github.com/$REPOSITORY/releases/tag/v$VERSION" \
  --embed-release-notes \
  --maximum-versions 0 \
  --maximum-deltas 0 \
  "$STAGING" >/dev/null

STAGED_APPCAST="$OUTPUT_DIR/appcast.xml"
cp "$STAGING/appcast.xml" "$STAGED_APPCAST"
EXPECTED_URL="https://github.com/$REPOSITORY/releases/download/v$VERSION/$ASSET_NAME"
verify_update_artifacts \
  "$ASSET" "$STAGED_APPCAST" "$EXPECTED_URL" "$VERSION" "$BUILD"

echo "==> prepared"
echo "    asset:   $ASSET"
echo "    appcast: $STAGED_APPCAST"
echo
echo "Publish in this order:"
echo "  1. Create GitHub release v$VERSION and upload $ASSET_NAME"
echo "  2. Confirm this URL downloads it:"
echo "     $EXPECTED_URL"
echo "  3. cp '$STAGED_APPCAST' '$LIVE_APPCAST'"
echo "  4. Commit and push updates/appcast.xml"
