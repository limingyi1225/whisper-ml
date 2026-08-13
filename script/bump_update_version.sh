#!/usr/bin/env bash
# Advances Whisper to the next release version before the release source is committed.
# If the project already contains an unpublished version/build, it leaves it unchanged.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/Whisper.xcodeproj/project.pbxproj"
APPCAST="$ROOT_DIR/updates/appcast.xml"

for command in xcodebuild perl xmllint; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "!! required command is missing: $command" >&2
    exit 1
  fi
done
if [ ! -f "$APPCAST" ]; then
  echo "!! update feed is missing: $APPCAST" >&2
  exit 1
fi

BUILD_SETTINGS=$(xcodebuild -project "$ROOT_DIR/Whisper.xcodeproj" -scheme Whisper \
  -configuration Release -showBuildSettings 2>/dev/null)
VERSION=$(printf '%s\n' "$BUILD_SETTINGS" \
  | sed -n 's/^ *MARKETING_VERSION = //p' | sort -u)
BUILD=$(printf '%s\n' "$BUILD_SETTINGS" \
  | sed -n 's/^ *CURRENT_PROJECT_VERSION = //p' | sort -u)
if [ -z "$VERSION" ] || [ "$(printf '%s\n' "$VERSION" | wc -l | tr -d ' ')" -ne 1 ]; then
  echo "!! could not read one unambiguous marketing version" >&2
  exit 1
fi
if [ -z "$BUILD" ] || [ "$(printf '%s\n' "$BUILD" | wc -l | tr -d ' ')" -ne 1 ]; then
  echo "!! could not read one unambiguous build number" >&2
  exit 1
fi
if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  echo "!! automatic versioning requires a dotted numeric version: $VERSION" >&2
  exit 1
fi
case "$BUILD" in
  0|[1-9]|[1-9][0-9]*) ;;
  *) echo "!! build must be a non-negative integer without leading zeroes: $BUILD" >&2; exit 1 ;;
esac

VERSION_IS_PUBLISHED=0
BUILD_IS_PUBLISHED=0
grep -Fq "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST" \
  && VERSION_IS_PUBLISHED=1
grep -Fq "<sparkle:version>$BUILD</sparkle:version>" "$APPCAST" \
  && BUILD_IS_PUBLISHED=1
if [ "$VERSION_IS_PUBLISHED" -ne "$BUILD_IS_PUBLISHED" ]; then
  echo "!! only one of version $VERSION and build $BUILD is published" >&2
  echo "   Repair the version pair manually before continuing." >&2
  exit 1
fi
if [ "$VERSION_IS_PUBLISHED" -eq 1 ]; then
  PUBLISHED_PAIR_COUNT=$(xmllint --xpath \
    "count(//*[local-name()='item'][*[local-name()='shortVersionString' and text()='$VERSION'] and *[local-name()='version' and text()='$BUILD']])" \
    "$APPCAST" 2>/dev/null || true)
  if [ "$PUBLISHED_PAIR_COUNT" != 1 ]; then
    echo "!! version $VERSION and build $BUILD are not one unique published item" >&2
    exit 1
  fi
fi
if [ "$VERSION_IS_PUBLISHED" -eq 0 ]; then
  LATEST_BUILD=$(sed -n \
    's#.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*#\1#p' "$APPCAST" \
    | awk 'BEGIN { max = 0 } $1 > max { max = $1 } END { print max }')
  if [ "$BUILD" -le "$LATEST_BUILD" ]; then
    echo "!! unpublished build $BUILD must be newer than published build $LATEST_BUILD" >&2
    exit 1
  fi
  echo "==> version already prepared: Whisper $VERSION ($BUILD)"
  exit 0
fi

NEXT_VERSION=$(printf '%s\n' "$VERSION" \
  | awk -F. 'BEGIN { OFS="." } { $NF += 1; print }')
NEXT_BUILD=$(awk -v build="$BUILD" 'BEGIN { print build + 1 }')
VERSION_OCCURRENCES=$(grep -Fxc $'\t\t\t\tMARKETING_VERSION = '"$VERSION"';' "$PROJECT_FILE")
BUILD_OCCURRENCES=$(grep -Fxc $'\t\t\t\tCURRENT_PROJECT_VERSION = '"$BUILD"';' "$PROJECT_FILE")
if [ "$VERSION_OCCURRENCES" -ne 2 ] || [ "$BUILD_OCCURRENCES" -ne 2 ]; then
  echo "!! expected exactly two Whisper target version settings" >&2
  echo "   marketing matches: $VERSION_OCCURRENCES; build matches: $BUILD_OCCURRENCES" >&2
  exit 1
fi

OLD_VERSION="$VERSION" NEW_VERSION="$NEXT_VERSION" \
OLD_BUILD="$BUILD" NEW_BUILD="$NEXT_BUILD" \
  perl -0pi -e '
    s/MARKETING_VERSION = \Q$ENV{OLD_VERSION}\E;/MARKETING_VERSION = $ENV{NEW_VERSION};/g;
    s/CURRENT_PROJECT_VERSION = \Q$ENV{OLD_BUILD}\E;/CURRENT_PROJECT_VERSION = $ENV{NEW_BUILD};/g;
  ' "$PROJECT_FILE"

if [ "$(grep -Fxc $'\t\t\t\tMARKETING_VERSION = '"$NEXT_VERSION"';' "$PROJECT_FILE")" -ne 2 ] \
    || [ "$(grep -Fxc $'\t\t\t\tCURRENT_PROJECT_VERSION = '"$NEXT_BUILD"';' "$PROJECT_FILE")" -ne 2 ]; then
  echo "!! version update did not produce the expected project settings" >&2
  exit 1
fi

echo "==> advanced Whisper $VERSION ($BUILD) -> $NEXT_VERSION ($NEXT_BUILD)"
