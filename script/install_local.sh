#!/usr/bin/env bash
# Promotes the working tree to the Whisper you actually use: a Release build, signed the
# same way a release is, installed into /Applications and relaunched.
#
#   ./script/install_local.sh          → build, install, relaunch
#   ./script/install_local.sh --test   → run the suites first
#
# This is the third build script and the other two do not cover it:
#
#   Xcode ⌘R           Debug, run in place. For iterating.
#   package_release.sh  Release + notarized + zipped. For other people's Macs.
#   install_local.sh    Release, installed. For your Mac.
#
# Tests are off by default because of where this sits in the day: you reach for it after
# ⌘R has already shown you the change working, so the suites would be re-proving what you
# just watched. `--test` when you want them anyway. The safety net that stays on is the
# one that catches what tests would not — if the installed build fails to stay running,
# the previous copy goes back.
#
# Notarization is deliberately skipped. It exists so a Mac that did not build the app
# will open it; this one did, so nothing is quarantined and Gatekeeper has no say. That
# is the several minutes package_release.sh spends that you do not have to.
#
# Signing, on the other hand, is NOT skipped, and it is why this is a script rather than
# two commands you could type. macOS attaches both of these to the code signature:
#
#   - the 辅助功能 and 麦克风 grants in TCC, and
#   - the ACL on the keychain items holding your API key and device token.
#
# Whisper cannot work without Accessibility — CGEventTap and synthetic keystrokes are
# the whole app — so a build signed differently from the one already installed does not
# merely warn: it silently loses the grant, and dictation stops working until you walk
# back through 系统设置 → 隐私与安全性 → 辅助功能. Exporting with the same Developer ID
# identity a release uses keeps the signature stable, so permissions survive every
# reinstall. The check at the end catches the case where it changed anyway.
set -Eeuo pipefail

TEAM_ID="${WHISPER_TEAM_ID:-9W3S5586KN}"
APP_NAME="Whisper"
INSTALLED="/Applications/$APP_NAME.app"

RUN_TESTS=0
case "${1:-}" in
  --test) RUN_TESTS=1 ;;
  "") ;;
  *) echo "usage: $0 [--test]" >&2; exit 2 ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLOT="$ROOT_DIR/build/local"
ARCHIVE="$SLOT/$APP_NAME.xcarchive"
EXPORT_DIR="$SLOT/developer-id"
EXPORT_OPTIONS="$SLOT/ExportOptions.plist"
BUILT="$EXPORT_DIR/$APP_NAME.app"
# Its own slot, so this never races package_release.sh over an archive or an export
# directory — that script builds under build/plain and build/for-<name>.
mkdir -p "$SLOT"

# The previous install is moved aside rather than deleted, and only removed once the new
# one is in place and running. Deleting first means a failure anywhere below leaves you
# with no Whisper at all — on a tool that is in the way of everything else you were about
# to do.
BACKUP="$SLOT/$APP_NAME.previous.app"
RESTORED=0
cleanup() {
  local status=$?
  if [ "$status" -ne 0 ] && [ "$RESTORED" -eq 0 ] && [ -d "$BACKUP" ] && [ ! -d "$INSTALLED" ]; then
    echo "!! failed after the old copy was moved aside; putting it back" >&2
    mv "$BACKUP" "$INSTALLED" && open -g "$INSTALLED" || true
  fi
}
trap cleanup EXIT

# What is installed right now, so the signature comparison at the end has something to
# compare against. Empty on a first install, which is not an error.
installed_signature() {
  [ -d "$INSTALLED" ] || return 0
  # `-dvv`, not `-dv`: the Authority lines only appear at verbosity 2, so the single-v
  # form returns nothing and the comparison below silently passes for every build —
  # exactly the check this script exists for, quietly disabled. codesign writes all of
  # this to stderr, hence the redirect.
  codesign -dvv "$INSTALLED" 2>&1 | sed -n 's/^Authority=//p' | head -1
}
PREVIOUS_AUTHORITY="$(installed_signature || true)"

if [ "$RUN_TESTS" -eq 1 ]; then
  echo "==> tests"
  (cd "$ROOT_DIR/server" && npm test >/dev/null) && echo "    relay ok"
  xcodebuild -project "$ROOT_DIR/Whisper.xcodeproj" -scheme "$APP_NAME" \
    -destination 'platform=macOS' test >/dev/null 2>&1 && echo "    swift ok"
else
  echo "==> tests skipped (--test to run them)"
fi

echo "==> archiving (Release)"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
xcodebuild -project "$ROOT_DIR/Whisper.xcodeproj" -scheme "$APP_NAME" \
  -configuration Release -destination 'platform=macOS' \
  -archivePath "$ARCHIVE" archive >/dev/null

echo "==> exporting with Developer ID"
# Byte-for-byte the options package_release.sh exports with. Anything else here — a
# development identity, ad-hoc, or unsigned — produces a bundle macOS treats as a
# different program, with the permission loss described in the header.
cat > "$EXPORT_OPTIONS" <<EOF
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
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_DIR" -allowProvisioningUpdates >/dev/null

# No relay token is baked in, which is what makes this the build for you rather than for
# someone else: you connect direct with your own API key. A token in /Applications would
# also be one nothing on the relay can revoke, because it was never registered.
if /usr/libexec/PlistBuddy -c "Print :WhisperRelayToken" \
     "$BUILT/Contents/Info.plist" >/dev/null 2>&1; then
  echo "!! this build carries a relay token; that is package_release.sh's job, not this" >&2
  exit 1
fi

echo "==> installing"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
# pkill returns before the process is gone, and copying over a bundle whose binary is
# still mapped is how you get a half-replaced app that launches into nothing.
for _ in $(seq 1 50); do
  pgrep -x "$APP_NAME" >/dev/null || break
  sleep 0.1
done
if pgrep -x "$APP_NAME" >/dev/null; then
  echo "!! $APP_NAME is still running and would not quit; not overwriting it" >&2
  exit 1
fi

rm -rf "$BACKUP"
# `if`, not `[ -d … ] && mv`: under `set -e` a false test is the last command in the
# list, so the whole script would exit here on a first install, when nothing is
# installed yet — the one run where that is completely normal.
if [ -d "$INSTALLED" ]; then mv "$INSTALLED" "$BACKUP"; fi
cp -R "$BUILT" "$INSTALLED"

echo "==> verifying"
codesign --verify --strict "$INSTALLED"
CURRENT_AUTHORITY="$(installed_signature || true)"
echo "    $CURRENT_AUTHORITY"
if [ -n "$PREVIOUS_AUTHORITY" ] && [ "$PREVIOUS_AUTHORITY" != "$CURRENT_AUTHORITY" ]; then
  # Loud, because the symptom is otherwise "the hotkey silently stopped working" and
  # nothing on screen connects that to having reinstalled.
  echo "!! the signing identity changed since the last install:" >&2
  echo "     was: $PREVIOUS_AUTHORITY" >&2
  echo "     now: $CURRENT_AUTHORITY" >&2
  echo "   macOS treats this as a different program, so 辅助功能 and 麦克风 have been" >&2
  echo "   reset and dictation will do nothing until you re-grant them in" >&2
  echo "   系统设置 → 隐私与安全性. Your keychain items may prompt once as well." >&2
fi

open "$INSTALLED"
sleep 2
if ! pgrep -x "$APP_NAME" >/dev/null; then
  echo "!! it did not stay running; rolling back to the previous copy" >&2
  rm -rf "$INSTALLED"
  mv "$BACKUP" "$INSTALLED"
  RESTORED=1
  open -g "$INSTALLED" || true
  exit 1
fi

rm -rf "$BACKUP"
echo "==> done: $INSTALLED is running"
