#!/usr/bin/env bash
# Manages one-time invite identities for the single public Whisper build.
#
#   ./script/invite_access.sh alice        issue one invite (printed once)
#   ./script/invite_access.sh --list       list pending, active, and revoked identities
#   ./script/invite_access.sh --revoke alice
set -Eeuo pipefail

HOST="${RELAY_SSH_HOST:-nyuclass}"
ADMIN_SOCKET=/run/whisper-relay/admin.sock
ACTION="${1:---list}"
LABEL="${2:-}"

case "$ACTION" in
  --list)
    [ "$#" -le 1 ] || { echo "usage: $0 --list" >&2; exit 2; }
    ;;
  --revoke)
    [ "$#" -eq 2 ] || { echo "usage: $0 --revoke <name>" >&2; exit 2; }
    ;;
  --*)
    echo "usage: $0 [--list | --revoke <name> | <name>]" >&2
    exit 2
    ;;
  *)
    [ "$#" -eq 1 ] || { echo "usage: $0 <name>" >&2; exit 2; }
    LABEL="$ACTION"
    ACTION=--issue
    ;;
esac

if [ -n "$LABEL" ]; then
  case "$LABEL" in
    *[!A-Za-z0-9_-]*) echo "!! name must be letters, digits, - or _" >&2; exit 2 ;;
  esac
fi

# OpenSSH assembles these arguments back into one remote shell command. An empty
# argument is therefore not preserved as argv[2], which made `--list` shift the socket
# into `$2` and die reading an unset `$3`. The list path ignores the label, so carry an
# explicit inert placeholder instead.
REMOTE_LABEL="${LABEL:--}"
ssh "$HOST" bash -s -- "$ACTION" "$REMOTE_LABEL" "$ADMIN_SOCKET" <<'REMOTE'
set -Eeuo pipefail
ACTION="$1"
LABEL="$2"
ADMIN_SOCKET="$3"

[ -S "$ADMIN_SOCKET" ] || {
  echo "!! enrollment admin socket is missing; deploy the relay first" >&2
  exit 1
}

request() {
  local path="$1"
  shift
  curl --silent --show-error --fail-with-body --unix-socket "$ADMIN_SOCKET" \
    "$@" "http://localhost$path"
}

case "$ACTION" in
  --issue)
    RESPONSE=$(request /admin/invites -H 'content-type: application/json' \
      -d "{\"label\":\"$LABEL\"}")
    printf '%s' "$RESPONSE" | node -e '
      let raw = "";
      process.stdin.on("data", (chunk) => { raw += chunk; });
      process.stdin.on("end", () => {
        const value = JSON.parse(raw);
        if (!value.code) process.exit(1);
        console.log(`invite for ${value.label}:`);
        console.log(value.code);
        console.log("This code is shown once. Send it privately.");
      });
    '
    ;;
  --revoke)
    RESPONSE=$(request /admin/revoke -H 'content-type: application/json' \
      -d "{\"label\":\"$LABEL\"}")
    printf '%s' "$RESPONSE" | node -e '
      let raw = "";
      process.stdin.on("data", (chunk) => { raw += chunk; });
      process.stdin.on("end", () => {
        const value = JSON.parse(raw);
        console.log(`revoked: ${value.devices} device(s), ${value.invites} pending invite(s)`);
      });
    '
    ;;
  --list)
    RESPONSE=$(request /admin/status)
    printf '%s' "$RESPONSE" | node -e '
      let raw = "";
      process.stdin.on("data", (chunk) => { raw += chunk; });
      process.stdin.on("end", () => {
        const value = JSON.parse(raw);
        console.log("PENDING INVITES");
        if (!value.pendingInvites.length) console.log("  (none)");
        for (const item of value.pendingInvites) console.log(`  ${item.label}\t${item.issuedAt}`);
        console.log("DEVICES");
        if (!value.devices.length) console.log("  (none)");
        for (const item of value.devices) console.log(`  ${item.label}\t${item.status}\t${item.enrolledAt}`);
      });
    '
    ;;
esac
REMOTE
