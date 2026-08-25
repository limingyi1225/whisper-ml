#!/usr/bin/env bash
# Builds a Developer ID–signed, notarized, stapled Whisper distribution.
# The result opens on any Mac with no Gatekeeper prompt at all.
#
#   ./script/package_release.sh                 → a plain build (for you)
#   ./script/package_release.sh --public        → one invite-enabled DMG for everyone
#   ./script/package_release.sh --for alice     → a build for one other person:
#       mints a device token, bakes it into the bundle, and — only after the build has
#       passed every check — registers its hash on the relay. They unzip, open, grant
#       two permissions, and it works. No pasting.
#
# One build per person on purpose. Handing the same token to ten people would make them
# share one identity on the relay: their apps consume the same connection allowance,
# the 30/min cleanup budget is shared, and removing one person means rotating everyone.
# A token each costs one command and none of that.
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
TOKEN_FILE=/opt/whisper-relay/device-tokens
LEDGER=/opt/whisper-relay-backups/issued-tokens.tsv

RECIPIENT=""
PUBLIC_BUILD=0
case "${1:-}" in
  --public)
    [ "$#" -eq 1 ] || { echo "usage: $0 --public" >&2; exit 2; }
    PUBLIC_BUILD=1
    ;;
  --for)
    [ "$#" -eq 2 ] || { echo "usage: $0 --for <name>" >&2; exit 2; }
    RECIPIENT="${2:-}"
    [ -n "$RECIPIENT" ] || { echo "usage: $0 --for <name>" >&2; exit 2; }
    # Kept to characters that are safe in a filename and readable in a token comment.
    case "$RECIPIENT" in
      *[!A-Za-z0-9_-]*) echo "!! name must be letters, digits, - or _" >&2; exit 2 ;;
    esac
    ;;
  "")
    [ "$#" -eq 0 ] || { echo "usage: $0 [--public | --for <name>]" >&2; exit 2; }
    ;;
  *) echo "usage: $0 [--public | --for <name>]" >&2; exit 2 ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/update_common.sh"
BUILD_DIR="$ROOT_DIR/build"
# Per recipient, not shared. With one `Whisper.xcarchive` and one `developer-id/`, two
# runs overlapping would have one process deleting and replacing the very app bundle the
# other was about to zip — producing Whisper-alice.zip containing Bob's token, which no
# later revocation of Alice can undo because it is not her token in there.
#
# `for-<name>` rather than the bare name, so `--for plain` cannot land in the plain
# build's slot — two different deliverables, one set of mutable intermediates.
if [ "$PUBLIC_BUILD" -eq 1 ]; then
  SLOT=public
  PACKAGE_NAME=Whisper-public
elif [ -n "$RECIPIENT" ]; then
  SLOT="for-$RECIPIENT"
  PACKAGE_NAME="Whisper-$RECIPIENT"
else
  SLOT=plain
  PACKAGE_NAME=Whisper
fi
ARCHIVE="$BUILD_DIR/$SLOT/Whisper.xcarchive"
EXPORT_DIR="$BUILD_DIR/$SLOT/developer-id"
EXPORT_OPTIONS="$BUILD_DIR/$SLOT/ExportOptions.plist"
APP="$EXPORT_DIR/Whisper.app"
DIST="$ROOT_DIR/dist"
ZIP="$DIST/$PACKAGE_NAME.zip"
DMG="$DIST/$PACKAGE_NAME.dmg"
STAGED="$BUILD_DIR/$SLOT/$PACKAGE_NAME.staging.zip"
STAGED_DMG="$BUILD_DIR/$SLOT/$PACKAGE_NAME.staging.dmg"
DMG_ROOT="$BUILD_DIR/$SLOT/dmg-root"
DMG_MOUNT="$BUILD_DIR/$SLOT/dmg-mount"
QUARANTINE_ROOT="$BUILD_DIR/$SLOT/quarantine-check"
DMG_ATTACHED=0

# The deliverable for this recipient is removed up front, so a run that dies anywhere
# can never leave the previous one behind looking like its result. A *failed*
# personalised run also removes its whole build slot: the archive and export carry the
# minted token in plaintext, and a token that will never be registered has no business
# outliving the run that minted it.
mkdir -p "$BUILD_DIR/$SLOT"

# One run per slot at a time. Every intermediate below — the archive, the exported .app,
# the staged zip — is named only by slot, so two concurrent `--for alice` runs share all
# of them: run A can verify that the exported app holds token A, then have run B replace
# that same app and staging zip with token B's, and A goes on to register A and publish
# B's build. The zip's embedded token then does not match the hash registered under that
# name, so revoking alice does not cut it off. The lock is taken before anything is
# removed or written, and held for the whole run.
#
# `mkdir`, not `flock`: macOS ships no flock(1). mkdir is atomic on every filesystem
# that matters here. The PID inside lets a crashed run's lock be reclaimed rather than
# blocking every future build until someone deletes it by hand.
LOCK_DIR="$BUILD_DIR/$SLOT.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  # The pid is written a moment after the directory appears, so "no pid yet" is
  # ambiguous: it means either a live holder mid-acquire or a run that died between the
  # two. Waiting briefly resolves the first; the second is then refused rather than
  # reclaimed. Treating a pidless lock as stale was a way for both runs to end up inside
  # the critical section — one registers its token while the other publishes a zip
  # containing an unregistered one, and the recipient 401s on first connect.
  HOLDER=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    HOLDER=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    [ -n "$HOLDER" ] && break
    sleep 0.2
  done
  if [ -z "$HOLDER" ]; then
    echo "!! '$SLOT' is locked but the holder never identified itself, so this cannot" >&2
    echo "   tell a run that is starting from one that died. Refusing rather than" >&2
    echo "   guessing. If no packaging run is active, remove it:" >&2
    echo "     rm -rf '$LOCK_DIR'" >&2
    exit 1
  fi
  if kill -0 "$HOLDER" 2>/dev/null; then
    echo "!! another packaging run (pid $HOLDER) already holds the '$SLOT' slot." >&2
    echo "   Wait for it to finish, or use a different name." >&2
    exit 1
  fi
  echo "    reclaiming a stale lock from dead pid $HOLDER"
  rm -rf "$LOCK_DIR"
  # Whoever wins this mkdir owns the slot; a loser must not proceed just because it
  # was the one that noticed the staleness.
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "!! another run claimed '$SLOT' first; not proceeding" >&2
    exit 1
  fi
fi
printf '%s\n' "$$" > "$LOCK_DIR/pid"

rm -f "$ZIP" "$DMG" "$STAGED" "$STAGED_DMG"
# Flipped immediately *before* the registration attempt, not after it returns. Registering
# is a remote commit acknowledged over ssh: a connection dropped after the relay committed
# but before the exit status came back is indistinguishable, locally, from never having
# registered — and treating that as "not registered" would delete the only verified copy
# of a build whose token may well be live. So the flag means "registration may have
# happened", and from that point a failure keeps the zip and asks for the state to be
# resolved by hand.
REGISTRATION_ATTEMPTED=0
cleanup() {
  local status=$?
  local detach_failed=0
  # A mount-point-shaped directory is not evidence that an image is attached there.
  # Calling `diskutil eject` on every exit was both noisy and capable of targeting an
  # unrelated volume if a stale path had been reused. The flag is armed only after a
  # successful attach and cleared only after a successful detach.
  if [ "$DMG_ATTACHED" -eq 1 ]; then
    if hdiutil detach "$DMG_MOUNT" >/dev/null 2>&1; then
      DMG_ATTACHED=0
    else
      detach_failed=1
      echo "!! could not detach the validation image; staging and lock were kept:" >&2
      echo "   hdiutil detach '$DMG_MOUNT'" >&2
      echo "   rm -rf '$LOCK_DIR'   # only after detach succeeds" >&2
    fi
  fi
  if [ "$detach_failed" -eq 1 ]; then
    # Do not remove a live mountpoint or unlock a slot whose next run starts with rm -rf
    # on that path. The image is read-only, but retaining both is still the safe failure.
    [ "$status" -ne 0 ] || status=1
    return "$status"
  fi
  if [ "$status" -eq 0 ]; then
    rm -f "$STAGED" "$STAGED_DMG"
    rm -rf "$DMG_ROOT" "$DMG_MOUNT" "$QUARANTINE_ROOT" "$LOCK_DIR"
    return
  fi
  if [ -n "$RECIPIENT" ] && [ "$REGISTRATION_ATTEMPTED" -eq 1 ]; then
    echo "!! failed at or after registration, so the token may or may not be live." >&2
    echo "   The verified zip has been kept:" >&2
    echo "     $STAGED" >&2
    echo "   Check which it is, then finish or undo:" >&2
    echo "     ./script/revoke_token.sh              # is $RECIPIENT listed active?" >&2
    echo "     mv '$STAGED' '$ZIP'                   # if active: ship this build" >&2
    echo "     ./script/revoke_token.sh $RECIPIENT   # if active but not shipping it" >&2
    rm -rf "$LOCK_DIR"
    return
  fi
  rm -f "$STAGED" "$STAGED_DMG"
  rm -rf "$DMG_ROOT" "$DMG_MOUNT" "$QUARANTINE_ROOT"
  if [ -n "$RECIPIENT" ]; then rm -rf "$BUILD_DIR/$SLOT"; fi
  rm -rf "$LOCK_DIR"
}
trap cleanup EXIT

# Checked before spending several minutes on a build that cannot be finished.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "!! no notarization credentials stored under profile '$NOTARY_PROFILE'." >&2
  echo "   Without them the app can be signed but not notarized, and every Mac that" >&2
  echo "   is not this one will refuse to open it. See the header of this script." >&2
  exit 1
fi

if [ "$PUBLIC_BUILD" -eq 1 ]; then
  echo "==> checking invite enrollment is live"
  ssh "$RELAY_SSH_HOST" bash -s <<'REMOTE'
set -euo pipefail
ENV_FILE=/etc/whisper-relay.env
PORT=$(sed -n 's/^PORT=//p' "$ENV_FILE"); PORT=${PORT:-8787}
BODY=$(curl -fsS -m 10 "http://127.0.0.1:$PORT/healthz")
case "$BODY" in
  *'"enrollment":true'*) echo "    relay enrollment is ready" ;;
  *) echo "!! relay enrollment is not enabled; deploy the relay first" >&2; exit 1 ;;
esac
REMOTE

  # Check the exact public base URL compiled into this app, not just loopback health.
  # A missing nginx/edge route otherwise survives all server checks and is discovered
  # only after a friend has downloaded a fully notarized DMG and tries to activate it.
  RELAY_BASE_SOURCE="$ROOT_DIR/DictationKit/Sources/DictationKit/ServiceRoute.swift"
  PUBLIC_RELAY_BASE=$(sed -En \
    's/^ *public nonisolated static let relayBaseURL = URL\(string: "([^"]+)"\)!$/\1/p' \
    "$RELAY_BASE_SOURCE")
  if [ -z "$PUBLIC_RELAY_BASE" ] \
    || [ "$(printf '%s\n' "$PUBLIC_RELAY_BASE" | wc -l | tr -d ' ')" != 1 ]; then
    echo "!! could not unambiguously read the app's public relay URL from:" >&2
    echo "   $RELAY_BASE_SOURCE" >&2
    exit 1
  fi
  ENROLLMENT_PROBE=$(curl -sS -m 20 -w '\n%{http_code}' \
    -H 'content-type: application/json' --data-binary '{' \
    "$PUBLIC_RELAY_BASE/v1/enroll" || true)
  ENROLLMENT_CODE=$(printf '%s' "$ENROLLMENT_PROBE" | tail -n 1)
  ENROLLMENT_BODY=$(printf '%s' "$ENROLLMENT_PROBE" | sed '$d')
  if [ "$ENROLLMENT_CODE" != 400 ] \
    || [[ "$ENROLLMENT_BODY" != *'"code":"enrollment_invalid_request"'* ]]; then
    echo "!! the public enrollment route compiled into the app is not working" >&2
    echo "   $PUBLIC_RELAY_BASE/v1/enroll returned HTTP ${ENROLLMENT_CODE:-none}" >&2
    exit 1
  fi
  echo "    public enrollment route is ready"
fi

# Minted before the build so the bake step has something to bake; *registered* only at
# the very end, once every check has passed. Registering up front meant a run that then
# failed anywhere — tests, archive, notarization — had already put a live token on the
# relay with nothing to revoke it by except the ledger row, and a retry minted and
# registered yet another one. An unregistered token, by contrast, is inert: the relay
# has never heard of it, so a failed run leaves nothing to clean up remotely.
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

  echo "==> checking the relay can take a registration later"
  # The fail-fast the early registration used to provide, without its side effect: a
  # relay that is unreachable, or too old to report a token count (i.e. too old to
  # reload an allowlist at all), fails the run in seconds rather than after a full
  # archive and notarization.
  ssh "$RELAY_SSH_HOST" bash -s <<'REMOTE'
set -euo pipefail
PORT=$(sed -n 's/^PORT=//p' /etc/whisper-relay.env); PORT=${PORT:-8787}
BODY=$(curl -fsS -m 10 "http://127.0.0.1:$PORT/healthz")
case "$BODY" in
  *'"allowlist":'*) echo "    relay is up and reloadable" ;;
  *) echo '!! the running relay does not report an allowlist digest, so a reload cannot' >&2
     echo '   be verified — it predates that. Deploy the relay first, then package.' >&2
     exit 1 ;;
esac
REMOTE
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
  #
  # The issuance stamp rides along because the token value alone cannot be ordered
  # against another one. Deciding whether to install a bundled token by comparing values
  # meant an *older* personalised copy, opened after a newer build had installed its
  # token, could not tell "mine is newer" from "mine is older" — and downgraded a working
  # token back to a revoked one. Epoch seconds, which is monotonic across runs and needs
  # no state anywhere to interpret.
  ISSUED_AT=$(date +%s)
  # Feed the plaintext credential on stdin. `PlistBuddy -c "...$BUNDLED_TOKEN"`
  # exposed it in the process argv to any local process listing while the edit ran.
  printf 'Add :WhisperRelayToken string %s\nSave\nExit\n' "$BUNDLED_TOKEN" \
    | /usr/libexec/PlistBuddy \
      "$ARCHIVE/Products/Applications/Whisper.app/Contents/Info.plist" >/dev/null
  ARCHIVE_TOKEN=$(/usr/libexec/PlistBuddy -c 'Print :WhisperRelayToken' \
    "$ARCHIVE/Products/Applications/Whisper.app/Contents/Info.plist" 2>/dev/null || true)
  if [ "$ARCHIVE_TOKEN" != "$BUNDLED_TOKEN" ]; then
    echo "!! could not write this run's token into the archive" >&2
    exit 1
  fi
  /usr/libexec/PlistBuddy -c "Add :WhisperRelayTokenIssuedAt integer $ISSUED_AT" \
    "$ARCHIVE/Products/Applications/Whisper.app/Contents/Info.plist" >/dev/null
  echo "    baked for '$RECIPIENT' (issuance $ISSUED_AT)"
elif [ "$PUBLIC_BUILD" -eq 1 ]; then
  echo "==> enabling one-time invite enrollment"
  /usr/libexec/PlistBuddy -c "Add :WhisperInviteEnrollment bool true" \
    "$ARCHIVE/Products/Applications/Whisper.app/Contents/Info.plist" >/dev/null
fi

echo "==> exporting with Developer ID"
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

# A Developer ID signature that is not also hardened-runtime will be rejected by the
# notary service, so confirm both here rather than reading it in a rejection log.
#
# Captured into a variable, not piped into `grep -q`: grep exits on its first match and
# SIGPIPEs codesign, and under `pipefail` the pipeline then reports codesign's 141 — so
# a correctly signed app fails the check that was supposed to wave it through.
SIGNATURE=$(codesign -dvv "$APP" 2>&1)
codesign --verify --deep --strict --verbose=2 "$APP"
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
ARCHS=$(lipo -archs "$APP/Contents/MacOS/Whisper")
case " $ARCHS " in *" arm64 "*) ;; *)
  echo "!! app is missing arm64: $ARCHS" >&2; exit 1
esac
case " $ARCHS " in *" x86_64 "*) ;; *)
  echo "!! app is missing x86_64: $ARCHS" >&2; exit 1
esac
echo "    Universal: $ARCHS"

# The app can be perfectly signed and notarized while still being unable to discover
# or verify an update. Gate the four invariants that make the in-app updater operational
# before spending time notarizing a release that would strand itself on this version.
UPDATE_FEED=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' \
  "$APP/Contents/Info.plist" 2>/dev/null || true)
UPDATE_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' \
  "$APP/Contents/Info.plist" 2>/dev/null || true)
SIGNED_FEED=$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' \
  "$APP/Contents/Info.plist" 2>/dev/null || true)
VERIFY_BEFORE_EXTRACTION=$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' \
  "$APP/Contents/Info.plist" 2>/dev/null || true)
EXPECTED_UPDATE_FEED="https://raw.githubusercontent.com/limingyi1225/whisper-ml/main/updates/appcast.xml"
if [ "$UPDATE_FEED" != "$EXPECTED_UPDATE_FEED" ]; then
  echo "!! the exported app has the wrong Sparkle feed URL" >&2
  echo "   expected: $EXPECTED_UPDATE_FEED" >&2
  echo "   actual:   ${UPDATE_FEED:-missing}" >&2
  exit 1
fi
if [ -z "$UPDATE_KEY" ]; then
  echo "!! the exported app has no Sparkle EdDSA public key" >&2
  exit 1
fi
if [ "$SIGNED_FEED" != true ] || [ "$VERIFY_BEFORE_EXTRACTION" != true ]; then
  echo "!! signed-feed or verify-before-extraction protection is disabled" >&2
  exit 1
fi
if [ ! -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
  echo "!! the exported app is missing Sparkle.framework" >&2
  exit 1
fi
resolve_sparkle_tools "$ROOT_DIR/Whisper.xcodeproj" Whisper
verify_sparkle_signing_key "$UPDATE_KEY"
echo "    signed updater feed, verified public key and embedded framework present"

echo "==> notarizing (a few minutes)"
# Everything below stages through $STAGED and only becomes $ZIP once every check has
# passed. Writing the deliverable early meant a failure anywhere after it left a file in
# dist/ that looked ready to send but had never been notarized or verified — and a
# failure *before* it left the previous run's zip sitting there, which is worse, because
# it is a plausible-looking build for the wrong person.
ditto -c -k --keepParent "$APP" "$STAGED"
xcrun notarytool submit "$STAGED" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> stapling"
# Staples the ticket into the .app so it opens on a Mac that is offline the first time.
xcrun stapler staple "$APP"
rm -f "$STAGED"
ditto -c -k --keepParent "$APP" "$STAGED"

echo "==> verifying the way the receiving Mac will"
spctl -a -vvv -t exec "$APP"
xcrun stapler validate "$APP"
# Before registration, so that once the token is live the only remaining local step is
# the same-filesystem rename at the bottom.
mkdir -p "$DIST"
if [ "$PUBLIC_BUILD" -eq 1 ]; then
  ENROLLMENT=$(/usr/libexec/PlistBuddy -c "Print :WhisperInviteEnrollment" \
    "$APP/Contents/Info.plist" 2>/dev/null || true)
  BUNDLED=$(/usr/libexec/PlistBuddy -c "Print :WhisperRelayToken" \
    "$APP/Contents/Info.plist" 2>/dev/null || true)
  if [ "$ENROLLMENT" != true ] || [ -n "$BUNDLED" ]; then
    echo "!! public build is missing enrollment or contains a shared credential" >&2
    exit 1
  fi
  echo "    public bundle contains enrollment, and no shared relay credential"
elif [ -n "$RECIPIENT" ]; then
  # Confirms the thing the recipient actually depends on, rather than assuming the
  # PlistBuddy edit survived export and stapling.
  BAKED=$(/usr/libexec/PlistBuddy -c "Print :WhisperRelayToken" "$APP/Contents/Info.plist")
  # Equality, not a `relay_*` prefix check. A prefix match passes just as happily on
  # *someone else's* token, so it could not have caught a build that picked up the wrong
  # identity — and the person whose name is on the zip would then be unrevocable,
  # because the hash on record for them is not the one inside their app.
  if [ "$BAKED" != "$BUNDLED_TOKEN" ]; then
    echo "!! the bundle does not carry this run's token — refusing to ship it" >&2
    exit 1
  fi
  # Without the stamp the app cannot order this token against one already installed, so
  # it falls back to "only fill an empty slot" — which silently breaks rotation for this
  # recipient. Not shippable.
  BAKED_AT=$(/usr/libexec/PlistBuddy -c "Print :WhisperRelayTokenIssuedAt" \
    "$APP/Contents/Info.plist" 2>/dev/null || true)
  if [ "$BAKED_AT" != "$ISSUED_AT" ]; then
    echo "!! the bundle is missing this run's issuance stamp — refusing to ship it" >&2
    exit 1
  fi
  echo "    the bundle carries this run's token and issuance, and the signature covers both"

  echo "==> registering the token on the relay"
  # Last, deliberately: everything that can fail already has, so all that stands
  # between a registered token and its finished zip is one same-filesystem rename.
  #
  # `reload`, never `restart`: a restart closes every open WebSocket, and the app
  # scores that as a failed utterance — onboarding one person must not cost everyone
  # else the sentence they were speaking. Appended, never replaced: everyone else's
  # token has to keep working.
  REGISTRATION_ATTEMPTED=1
ssh "$RELAY_SSH_HOST" bash -s -- "$TOKEN_HASH" "$RECIPIENT" <<'REMOTE'
set -euo pipefail
TOKEN_HASH="$1"; RECIPIENT="$2"
ENV_FILE=/etc/whisper-relay.env
TOKEN_FILE=/opt/whisper-relay/device-tokens
LEDGER=/opt/whisper-relay-backups/issued-tokens.tsv
LOCK=/opt/whisper-relay-backups/.allowlist.lock
PORT=$(sed -n 's/^PORT=//p' "$ENV_FILE"); PORT=${PORT:-8787}
HEALTH="http://127.0.0.1:$PORT/healthz"
EMPTY_LEGACY_SENTINEL='# whisper-relay: intentionally empty legacy allowlist'

# The same lock the revoke script takes. Issuing appends while revoking rewrites from a
# snapshot; interleaved without coordination, a revoke can silently drop a hash that was
# just issued and confirmed — and the resulting build 401s on its very first connection.
exec 9>"$LOCK"
flock -w 60 9 || { echo '!! another issue/revoke is holding the lock' >&2; exit 1; }

# Canonicalised the way config.js parses: comment stripped, trimmed, lowercased, once
# each — the server keeps a Set. Never `... | grep -q`: grep exits at the first match,
# the producer takes SIGPIPE, and under `pipefail` the pipeline reports 141 and inverts
# the predicate. It is a race, so it passes on short lists and fails on real ones.
effective() { awk '{ sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); if (length) print tolower($0) }' "$1" | LC_ALL=C sort -u; }
is_intentionally_empty() {
  awk -v marker="$EMPTY_LEGACY_SENTINEL" '
    { line = $0; gsub(/^[ \t]+|[ \t]+$/, "", line); if (length(line)) { n += 1; only = line } }
    END { exit (n == 1 && only == marker) ? 0 : 1 }' "$1"
}
contains_empty_sentinel() {
  awk -v marker="$EMPTY_LEGACY_SENTINEL" '
    { line = $0; gsub(/^[ \t]+|[ \t]+$/, "", line); if (line == marker) found = 1 }
    END { exit found ? 0 : 1 }' "$1"
}
has_hash() {
  effective "$1" | awk -v h="$2" 'BEGIN { h = tolower(h) } tolower($0) == h { f = 1 } END { exit f ? 0 : 1 }'
}
valid_allowlist() {
  is_intentionally_empty "$1" && return 0
  contains_empty_sentinel "$1" && return 1
  effective "$1" | awk '
    { n += 1; if ($0 !~ /^[a-f0-9]{64}$/) bad = 1 }
    END { exit (n > 0 && !bad) ? 0 : 1 }'
}
count_hashes() { effective "$1" | awk 'END { print NR + 0 }'; }
# Byte-identical to allowlistDigest() in config.js — a test asserts the two agree.
digest_of() { printf '%s' "$(effective "$1")" | sha256sum | cut -c1-16; }

# Built as a candidate and validated in full before the live list is touched, so a
# failure anywhere in here cannot leave a half-edited allowlist for the next unrelated
# reload to apply. The intentional-empty marker must be the only nonblank line, so a
# legacy issue replaces it rather than appending a hash beside it.
if is_intentionally_empty "$TOKEN_FILE"; then
  printf '%s\n' "$TOKEN_HASH" > "$TOKEN_FILE.next"
else
  cp -a "$TOKEN_FILE" "$TOKEN_FILE.next"
  has_hash "$TOKEN_FILE.next" "$TOKEN_HASH" \
    || printf '%s\n' "$TOKEN_HASH" >> "$TOKEN_FILE.next"
fi

# Validated the way config.js will read it, *before* the reload — the same check the
# revoke script runs, and skipping it here reopened the same hole: a pre-existing
# malformed line makes the server reject the reload and keep its old set, and the
# retained set's count can equal what the new file would report, so the check below
# would bless a token that was never loaded — a signed, notarized build that 401s.
if ! valid_allowlist "$TOKEN_FILE.next"; then
  echo '!! the allowlist has a line the server will refuse to load; not registering.' >&2
  echo '   Fix /opt/whisper-relay/device-tokens by hand, then re-run.' >&2
  rm -f "$TOKEN_FILE.next"
  exit 1
fi
WANT=$(digest_of "$TOKEN_FILE.next")
COUNT=$(count_hashes "$TOKEN_FILE.next")

# The ledger row goes in before the reload, not after a success: a hash that went live
# with no row against it would be unrevocable by name, which is strictly worse than a
# stale row for a hash that never went live (the list just shows it as revoked).
grep -q "$TOKEN_HASH" "$LEDGER" 2>/dev/null \
  || printf '%s\t%s\t%s\n' "$RECIPIENT" "$TOKEN_HASH" "$(date -Is)" >> "$LEDGER"

cp -a "$TOKEN_FILE" "$TOKEN_FILE.bak"
restore() {
  mv "$TOKEN_FILE.bak" "$TOKEN_FILE"
  systemctl reload whisper-relay || systemctl restart whisper-relay || true
}
# Issuance fails closed: *any* exit that is not the success path — an explicit check, a
# `set -e` surprise, or this shell dying with a dropped ssh session — puts the previous
# allowlist back. The success path removes the .bak, which disarms this.
# (The revoke script needs no equivalent: it validates a candidate and swaps it in with
# one mv, and "restoring" after a failed reload there would resurrect the token.)
on_exit() {
  local status=$?
  rm -f "$TOKEN_FILE.next"
  if [ "$status" -ne 0 ] && [ -f "$TOKEN_FILE.bak" ]; then restore; fi
}
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mv "$TOKEN_FILE.next" "$TOKEN_FILE"
chmod 0644 "$TOKEN_FILE"
systemctl reload whisper-relay
sleep 1
# The digest, not the count. A count is an inference — it can collide, and a reload the
# server rejected keeps an old set whose count may match what the new file would have
# reported, which is exactly how an unauthorised token got shipped. (`-le` against a
# previous count was worse still: an old /healthz without the field made `[ "" -le "" ]`
# an *error*, and an errored `if` condition is simply false, so the guard passed.) The
# digest is the server telling us which list it is actually serving.
HEALTH_BODY=$(curl -fsS -m 10 "$HEALTH" || true)
AFTER=$(printf '%s' "$HEALTH_BODY" \
  | sed -n 's/.*"legacyAllowlist":"\([a-f0-9]*\)".*/\1/p')
[ -n "$AFTER" ] || AFTER=$(printf '%s' "$HEALTH_BODY" \
  | sed -n 's/.*"allowlist":"\([a-f0-9]*\)".*/\1/p')
if [ "$AFTER" != "$WANT" ]; then
  echo "!! relay is serving allowlist '$AFTER', expected '$WANT' — the token is NOT" >&2
  echo "   live; rolling back" >&2
  exit 1
fi
rm -f "$TOKEN_FILE.bak"
printf '    %s tokens authorised (%s), nobody disconnected\n' "$COUNT" "$AFTER"
REMOTE
fi

if [ "$PUBLIC_BUILD" -eq 1 ]; then
  echo "==> creating the public DMG"
  rm -rf "$DMG_ROOT"
  mkdir -p "$DMG_ROOT"
  ditto "$APP" "$DMG_ROOT/Whisper.app"
  ln -s /Applications "$DMG_ROOT/Applications"
  # `diskutil image create from` is the supported spelling on macOS 27, but does not
  # exist on the macOS 26 build machines this project still supports. Feature-detect
  # the subcommand instead of keying off an OS version string; the old hdiutil path
  # produces the same compressed UDZO image and remains available there.
  if diskutil image create from --help >/dev/null 2>&1; then
    diskutil image create from --format UDZO --volumeName Whisper \
      "$DMG_ROOT" "$STAGED_DMG" >/dev/null
  else
    hdiutil create -srcfolder "$DMG_ROOT" -format UDZO -volname Whisper \
      "$STAGED_DMG" >/dev/null
  fi

  echo "==> notarizing the DMG"
  xcrun notarytool submit "$STAGED_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$STAGED_DMG"
  xcrun stapler validate "$STAGED_DMG"
  hdiutil verify "$STAGED_DMG" >/dev/null

  echo "==> checking the mounted DMG like a downloaded copy"
  rm -rf "$DMG_MOUNT" "$QUARANTINE_ROOT"
  mkdir -p "$DMG_MOUNT" "$QUARANTINE_ROOT"
  hdiutil attach -readonly -nobrowse -mountpoint "$DMG_MOUNT" \
    "$STAGED_DMG" >/dev/null
  DMG_ATTACHED=1
  ditto "$DMG_MOUNT/Whisper.app" "$QUARANTINE_ROOT/Whisper.app"
  hdiutil detach "$DMG_MOUNT" >/dev/null
  DMG_ATTACHED=0
  xattr -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");Whisper;" \
    "$QUARANTINE_ROOT/Whisper.app"
  codesign --verify --deep --strict --verbose=2 "$QUARANTINE_ROOT/Whisper.app"
  spctl -a -vvv -t exec "$QUARANTINE_ROOT/Whisper.app"
  syspolicy_check distribution "$QUARANTINE_ROOT/Whisper.app" --verbose
  mv -f "$STAGED_DMG" "$DMG"
  FINAL="$DMG"
else
  # Atomic within the same filesystem: dist/ never holds a half-written or
  # half-verified archive. For a personalised build this is the only local step left
  # after registration, so a failure cannot strand a live token behind a stale ZIP.
  mv -f "$STAGED" "$ZIP"
  FINAL="$ZIP"
fi

echo "==> done: $FINAL"
if [ "$PUBLIC_BUILD" -eq 1 ]; then
  echo "    Send this one DMG to everyone. Give each person a separate code from:"
  echo "      ./script/invite_access.sh <name>"
elif [ -n "$RECIPIENT" ]; then
  echo "    Send this to $RECIPIENT. They unzip, drag it to 应用程序, open it, and grant"
  echo "    辅助功能 + 麦克风. Nothing to paste, nothing to configure."
  echo "    To cut them off later: ./script/revoke_token.sh $RECIPIENT"
else
  echo "    Send that file. It opens with no prompt on any Mac running macOS 26 or later."
fi
