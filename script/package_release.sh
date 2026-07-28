#!/usr/bin/env bash
# Builds a Developer ID–signed, notarized, stapled Whisper.app and zips it for hand-off.
# The result opens on any Mac with no Gatekeeper prompt at all.
#
# One-time setup (only you can do this part — it needs an Apple ID credential):
#
#   1. Create an app-specific password at https://appleid.apple.com → 登录与安全
#      → App 专用密码. It is NOT your Apple ID password.
#   2. Store it once, so it never has to be typed again:
#
#        xcrun notarytool store-credentials whisper-notary \
#          --apple-id <your-apple-id> --team-id 9W3S5586KN
#
#      It prompts for the app-specific password and saves it to the keychain.
#
# After that this script is the whole release process.
set -Eeuo pipefail

TEAM_ID="${WHISPER_TEAM_ID:-9W3S5586KN}"
NOTARY_PROFILE="${WHISPER_NOTARY_PROFILE:-whisper-notary}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
ARCHIVE="$BUILD_DIR/Whisper.xcarchive"
EXPORT_DIR="$BUILD_DIR/developer-id"
APP="$EXPORT_DIR/Whisper.app"
DIST="$ROOT_DIR/dist"
ZIP="$DIST/Whisper.zip"

# Checked before spending several minutes on a build that cannot be finished.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "!! no notarization credentials stored under profile '$NOTARY_PROFILE'." >&2
  echo "   Without them the app can be signed but not notarized, and every Mac that" >&2
  echo "   is not this one will refuse to open it. See the header of this script." >&2
  exit 1
fi

echo "==> tests"
(cd "$ROOT_DIR/server" && npm test >/dev/null) && echo "    relay ok"
xcodebuild -project "$ROOT_DIR/Whisper.xcodeproj" -scheme Whisper \
  -destination 'platform=macOS' test >/dev/null 2>&1 && echo "    swift ok"

echo "==> archiving (Release)"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
xcodebuild -project "$ROOT_DIR/Whisper.xcodeproj" -scheme Whisper \
  -configuration Release -destination 'platform=macOS' \
  -archivePath "$ARCHIVE" archive >/dev/null

echo "==> exporting with Developer ID"
cat > "$BUILD_DIR/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -exportPath "$EXPORT_DIR" -allowProvisioningUpdates >/dev/null

# A Developer ID signature that is not also hardened-runtime will be rejected by the
# notary service, so confirm both here rather than reading it in a rejection log.
#
# Captured into a variable, not piped into `grep -q`: grep exits on its first match and
# SIGPIPEs codesign, and under `pipefail` the pipeline then reports codesign's 141 — so
# a correctly signed app fails the check that was supposed to wave it through.
SIGNATURE=$(codesign -dvv "$APP" 2>&1)
case "$SIGNATURE" in
  *"Developer ID Application"*) ;;
  *) echo "!! not signed with Developer ID:" >&2
     printf '%s\n' "$SIGNATURE" | sed -n 's/^Authority=/    /p' >&2
     exit 1 ;;
esac
case "$SIGNATURE" in
  *runtime*) ;;
  *) echo "!! hardened runtime is off; the notary service will reject it" >&2; exit 1 ;;
esac
# Same trap as above, one stage further along: `| head -1` would SIGPIPE sed. Take the
# first line with parameter expansion instead of with an early-exiting reader.
AUTHORITIES=$(printf '%s\n' "$SIGNATURE" | sed -n 's/^Authority=//p')
echo "    ${AUTHORITIES%%$'\n'*}"

echo "==> notarizing (a few minutes)"
mkdir -p "$DIST"
rm -f "$ZIP"
# ditto, not `zip`: the symlinks and resource forks inside a .app must survive.
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> stapling"
# Staples the ticket into the .app so it opens on a Mac that is offline the first time.
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> verifying the way the receiving Mac will"
spctl -a -vvv -t exec "$APP"
xcrun stapler validate "$APP"

echo "==> done: $ZIP"
echo "    Send that file. It opens with no prompt on any Mac running macOS 26 or later."
