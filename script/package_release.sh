#!/usr/bin/env bash
# Builds a Developer ID–signed, notarized, stapled Whisper.app and zips it for hand-off.
# The result opens on any Mac with no Gatekeeper prompt at all.
#
#   ./script/package_release.sh                 → a plain build (for you)
#   ./script/package_release.sh --for alice     → a build for one other person:
#       mints a device token, registers its hash on the relay, bakes the token into
#       the bundle. They unzip, open, grant two permissions, and it works. No pasting.
#
# One build per person on purpose. Handing the same token to ten people would make them
# share one identity on the relay: MAX_CONNECTIONS_PER_DEVICE=2 means the third person
# to open the app gets 429'd, the 30/min cleanup budget is shared, and removing one
# person means rotating everyone. A token each costs one command and none of that.
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
RELAY_SSH_HOST="${RELAY_SSH_HOST:-nyuclass}"
RELAY_ENV_FILE=/etc/whisper-relay.env
LEDGER=/opt/whisper-relay-backups/issued-tokens.tsv

RECIPIENT=""
case "${1:-}" in
  --for)
    RECIPIENT="${2:-}"
    [ -n "$RECIPIENT" ] || { echo "usage: $0 --for <name>" >&2; exit 2; }
    # Kept to characters that are safe in a filename and readable in a token comment.
    case "$RECIPIENT" in
      *[!A-Za-z0-9_-]*) echo "!! name must be letters, digits, - or _" >&2; exit 2 ;;
    esac
    ;;
  "") ;;
  *) echo "usage: $0 [--for <name>]" >&2; exit 2 ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
ARCHIVE="$BUILD_DIR/Whisper.xcarchive"
EXPORT_DIR="$BUILD_DIR/developer-id"
APP="$EXPORT_DIR/Whisper.app"
DIST="$ROOT_DIR/dist"
ZIP="$DIST/Whisper${RECIPIENT:+-$RECIPIENT}.zip"

# Checked before spending several minutes on a build that cannot be finished.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "!! no notarization credentials stored under profile '$NOTARY_PROFILE'." >&2
  echo "   Without them the app can be signed but not notarized, and every Mac that" >&2
  echo "   is not this one will refuse to open it. See the header of this script." >&2
  exit 1
fi

# Minted before the build so a relay that cannot be reached fails the run in seconds
# rather than after a full archive and notarization.
if [ -n "$RECIPIENT" ]; then
  echo "==> minting a device token for '$RECIPIENT'"
  TOKEN_OUTPUT=$(cd "$ROOT_DIR/server" && node scripts/generate-token.js)
  BUNDLED_TOKEN=$(printf '%s\n' "$TOKEN_OUTPUT" | grep -o 'relay_[A-Za-z0-9_-]*' || true)
  TOKEN_HASH=$(printf '%s\n' "$TOKEN_OUTPUT" | grep -oE '^[a-f0-9]{64}$' || true)
  if [ -z "$BUNDLED_TOKEN" ] || [ -z "$TOKEN_HASH" ]; then
    echo "!! could not parse generate-token.js output" >&2
    exit 1
  fi
  echo "    token minted (not printed; it only ever lives in the build)"

  echo "==> registering its hash on the relay"
  # Appended, never replaced: everyone else's token has to keep working. Idempotent,
  # so a re-run after a failure cannot add the same hash twice.
  ssh "$RELAY_SSH_HOST" "set -e
    umask 077
    grep -q '$TOKEN_HASH' $RELAY_ENV_FILE \
      || sed -i 's|^RELAY_DEVICE_TOKEN_HASHES=.*|&,$TOKEN_HASH|' $RELAY_ENV_FILE
    # A ledger of who holds what, kept beside the env file rather than inside it: the
    # hashes alone are anonymous, and revoking someone six months from now means being
    # able to tell which of ten identical-looking hashes is theirs.
    grep -q '$TOKEN_HASH' $LEDGER 2>/dev/null \
      || printf '%s\t%s\t%s\n' '$RECIPIENT' '$TOKEN_HASH' \"\$(date -Is)\" >> $LEDGER
    systemctl restart whisper-relay
    systemctl is-active --quiet whisper-relay
    printf '    %s tokens now authorised\n' \
      \"\$(sed -n 's/^RELAY_DEVICE_TOKEN_HASHES=//p' $RELAY_ENV_FILE | tr ',' '\n' | grep -c .)\""
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

if [ -n "$RECIPIENT" ]; then
  echo "==> baking the token into the archive"
  # Into the archive, before the export signs it — not into the exported .app after.
  # Editing a signed bundle breaks its seal, and re-signing by hand is not an option
  # here: Xcode's automatically-managed Developer ID identity does not live in the
  # login keychain, so `security find-identity` cannot even see it. Letting
  # `-exportArchive` do the signing it was already doing sidesteps all of that.
  #
  # Info.plist rather than a generated Swift file, so nothing that has ever held a
  # token exists in the working tree and an interrupted run cannot leave one to be
  # committed. (`INFOPLIST_KEY_…` does not work for this: Xcode only maps the keys it
  # knows, and a custom one is silently dropped — verified.)
  /usr/libexec/PlistBuddy -c "Add :WhisperRelayToken string $BUNDLED_TOKEN" \
    "$ARCHIVE/Products/Applications/Whisper.app/Contents/Info.plist" >/dev/null
  echo "    baked for '$RECIPIENT'"
fi

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
if [ -n "$RECIPIENT" ]; then
  # Confirms the thing the recipient actually depends on, rather than assuming the
  # PlistBuddy edit survived re-signing and stapling.
  BAKED=$(/usr/libexec/PlistBuddy -c "Print :WhisperRelayToken" "$APP/Contents/Info.plist")
  case "$BAKED" in
    relay_*) echo "    token is in the bundle and the signature covers it" ;;
    *) echo "!! the token did not survive packaging" >&2; exit 1 ;;
  esac
  echo "    Send this to $RECIPIENT. They unzip, drag it to 应用程序, open it, and grant"
  echo "    辅助功能 + 麦克风. Nothing to paste, nothing to configure."
  echo "    To cut them off later: ./script/revoke_token.sh $RECIPIENT"
else
  echo "    Send that file. It opens with no prompt on any Mac running macOS 26 or later."
fi
