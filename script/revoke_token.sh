#!/usr/bin/env bash
# Cuts one person off the relay, leaving everyone else connected and untouched.
#
#   ./script/revoke_token.sh            → list who currently has access
#   ./script/revoke_token.sh alice      → revoke alice
#
# Takes effect immediately: the reload drops their live socket too, and everyone else's
# stays up. Nothing on their Mac needs uninstalling.
#
# The remote half is a quoted heredoc fed to `bash -s`, with values passed as positional
# arguments. The earlier form — a double-quoted string full of \$ escapes — was its own
# bug source; escaping is not worth the risk when the alternative is this.
set -Eeuo pipefail

HOST="${RELAY_SSH_HOST:-nyuclass}"
NAME="${1:-}"
[ "$#" -le 1 ] || { echo "usage: $0 [name]" >&2; exit 2; }

if [ -z "$NAME" ]; then
  echo "==> tokens currently authorised"
  ssh "$HOST" bash -s <<'REMOTE'
set -euo pipefail
ENV_FILE=/etc/whisper-relay.env
TOKEN_FILE=/opt/whisper-relay/device-tokens
LEDGER=/opt/whisper-relay-backups/issued-tokens.tsv
PORT=$(sed -n 's/^PORT=//p' "$ENV_FILE"); PORT=${PORT:-8787}
EMPTY_LEGACY_SENTINEL='# whisper-relay: intentionally empty legacy allowlist'

# Reads the file exactly the way config.js does: strip a trailing comment, trim,
# lowercase, and a hash counts once however many times it appears — the server keeps a
# Set. Any other counting would disagree with the server, and every check in this
# script compares against the server's own number.
effective() { awk '{ sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); if (length) print tolower($0) }' "$1" | LC_ALL=C sort -u; }
is_intentionally_empty() {
  awk -v marker="$EMPTY_LEGACY_SENTINEL" '
    { line = $0; gsub(/^[ \t]+|[ \t]+$/, "", line); if (length(line)) { n += 1; only = line } }
    END { exit (n == 1 && only == marker) ? 0 : 1 }' "$1"
}

# Never `... | grep -q`. grep exits at its first match, the producer takes SIGPIPE, and
# under `pipefail` the pipeline then reports 141 — so the predicate inverts. It is a
# *race* (whether the producer is still writing when grep goes), so it passes in small
# tests and fails on a real list: measured on this host with 2 000 hashes, `effective |
# grep -qx <hash-that-is-present>` reported ABSENT. That was the check guarding "a hash
# survived the edit". awk reads to EOF and cannot lose the race.
has_hash() {
  effective "$1" | awk -v h="$2" 'BEGIN { h = tolower(h) } tolower($0) == h { f = 1 } END { exit f ? 0 : 1 }'
}
count_hashes() { effective "$1" | awk 'END { print NR + 0 }'; }
# The digest /healthz reports, computed from the file: sorted unique hashes joined by
# newlines, sha256, first 16 hex. Must stay byte-identical to allowlistDigest() in
# config.js — there is a test asserting the two agree.
#
# Refuses an absent or empty file rather than digesting nothing: sha256 of "" is a
# perfectly valid-looking 16 hex chars, and printing it next to the relay's own digest
# would read as a real answer about a list that does not exist.
digest_of() {
  [ -s "$1" ] || return 1
  if is_intentionally_empty "$1"; then
    printf '' | sha256sum | cut -c1-16
    return
  fi
  printf '%s' "$(effective "$1")" | sha256sum | cut -c1-16
}

HEALTH_BODY=$(curl -fsS -m 10 "http://127.0.0.1:$PORT/healthz" || true)
RELAY_TOKENS=$(printf '%s' "$HEALTH_BODY" | sed -n 's/.*"tokens":\([0-9]*\).*/\1/p')
RELAY_DIGEST=$(printf '%s' "$HEALTH_BODY" | sed -n 's/.*"allowlist":"\([a-f0-9]*\)".*/\1/p')
LEGACY_TOKENS=$(printf '%s' "$HEALTH_BODY" | sed -n 's/.*"legacyTokens":\([0-9]*\).*/\1/p')
LEGACY_DIGEST=$(printf '%s' "$HEALTH_BODY" | sed -n 's/.*"legacyAllowlist":"\([a-f0-9]*\)".*/\1/p')
[ -n "$LEGACY_TOKENS" ] || LEGACY_TOKENS="$RELAY_TOKENS"
[ -n "$LEGACY_DIGEST" ] || LEGACY_DIGEST="$RELAY_DIGEST"

# Branch on the file existing instead of letting every helper fail into the output. With
# no file, `effective` used to spray "awk: fatal: cannot open" across the table while
# still printing a count of 0 *and* a fallback '?' — two answers, both misleading.
if [ -s "$TOKEN_FILE" ]; then
  printf '    %s in the allowlist (%s), relay reports %s (%s)\n\n' \
    "$(count_hashes "$TOKEN_FILE")" "$(digest_of "$TOKEN_FILE")" \
    "${LEGACY_TOKENS:-?}" "${LEGACY_DIGEST:-?}"
else
  printf '    no allowlist file at %s yet.\n' "$TOKEN_FILE"
  printf '    Run ./script/deploy_relay.sh first — it creates the file and makes the\n'
  printf '    relay able to reload it, which is what issuing and revoking need.\n'
  printf '    (the relay reports %s token(s), digest %s)\n\n' \
    "${RELAY_TOKENS:-?}" "${RELAY_DIGEST:-none}"
fi

if [ -s "$LEDGER" ]; then
  printf '    %-16s %-10s %s\n' NAME STATUS ISSUED
  while IFS=$'\t' read -r name hash issued; do
    if [ ! -s "$TOKEN_FILE" ]; then s=unknown
    elif has_hash "$TOKEN_FILE" "$hash"; then s=active
    else s=revoked
    fi
    printf '    %-16s %-10s %s\n' "$name" "$s" "$issued"
  done < "$LEDGER"
else
  printf '    (no ledger yet — only your own token exists)\n'
fi
REMOTE
  echo
  echo "    revoke with: $0 <name>"
  exit 0
fi

echo "==> revoking '$NAME'"
ssh "$HOST" bash -s -- "$NAME" <<'REMOTE'
set -euo pipefail
NAME="$1"
ENV_FILE=/etc/whisper-relay.env
TOKEN_FILE=/opt/whisper-relay/device-tokens
LEDGER=/opt/whisper-relay-backups/issued-tokens.tsv
LOCK=/opt/whisper-relay-backups/.allowlist.lock
PORT=$(sed -n 's/^PORT=//p' "$ENV_FILE"); PORT=${PORT:-8787}
HEALTH="http://127.0.0.1:$PORT/healthz"
EMPTY_LEGACY_SENTINEL='# whisper-relay: intentionally empty legacy allowlist'

# Issuing appends and revoking rewrites, both without coordination — interleave them and
# a revoke's snapshot can clobber a hash that was just issued and confirmed, handing
# someone a signed, notarized build that 401s on its first connection. One lock covers
# both, so the two operations simply queue.
exec 9>"$LOCK"
flock -w 60 9 || { echo '!! another issue/revoke is holding the lock' >&2; exit 1; }

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

# Never `... | grep -q`: grep exits at its first match, the producer takes SIGPIPE, and
# under `pipefail` the pipeline reports 141, inverting the predicate. It is a race — it
# passes on a short list and fails on a real one (measured here at 2 000 hashes: a hash
# that WAS present was reported absent). Both of these read to EOF instead.
has_hash() {
  effective "$1" | awk -v h="$2" 'BEGIN { h = tolower(h) } tolower($0) == h { f = 1 } END { exit f ? 0 : 1 }'
}
# The exact test config.js applies before it will swap the allowlist in: at least one
# effective line, every one of them 64 hex chars. One awk pass over the whole input, for
# the reason above — the earlier `! printf … | grep -qvE …` form could report a malformed
# list as valid, which is precisely how a rejected reload got mistaken for a good one.
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
health_field() {
  curl -fsS -m 10 "$HEALTH" | sed -n "s/.*\"$1\":\"\{0,1\}\([a-f0-9]*\)\"\{0,1\}.*/\1/p"
}

# *Every* hash on record for this name, not just the most recent. A re-issued build (or
# a packaging run that failed after registering) leaves more than one row, and revoking
# only the last would quietly leave an earlier token working forever. Lowercased to
# match `effective`: the server lowercases before parsing, so case must never make the
# ledger and the allowlist disagree about the same hash.
HASHES=$(awk -F'\t' -v n="$NAME" '$1 == n { print tolower($2) }' "$LEDGER" 2>/dev/null || true)
if [ -z "$HASHES" ]; then
  echo '!! no token on record for that name; run with no arguments to list' >&2
  exit 1
fi

BEFORE=$(count_hashes "$TOKEN_FILE")
cp -a "$TOKEN_FILE" "$TOKEN_FILE.bak"

restore() {
  mv "$TOKEN_FILE.bak" "$TOKEN_FILE"
  systemctl reload whisper-relay || systemctl restart whisper-relay || true
}
# Armed from the moment a backup exists, which is the moment there is something to undo.
#
# Between the `mv` below and the digest confirmation, disk and memory disagree: the file
# says revoked, the running relay still says authorised. Any exit through that window — a
# dropped ssh session, HUP/TERM, a `set -e` surprise — has to close it, or the listing
# would report someone as revoked while their token kept working. Restoring is the honest
# resolution: both sides end up agreeing on "not revoked" and the script fails loudly, so
# the operator re-runs — rather than leaving a half-applied edit on disk for some later,
# unrelated reload to enact.
#
# Every path that gives up *before* the mv removes the backup itself, which disarms this;
# so does the success path. The mv consumes it too, so no path can restore twice.
on_exit() {
  local status=$?
  if [ "$status" -ne 0 ] && [ -f "$TOKEN_FILE.bak" ]; then
    echo '!! interrupted mid-revoke; restoring the previous allowlist' >&2
    restore
  fi
}
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# One awk pass removing every hash for this name, into a candidate file, validated in
# full — and only then moved over the live list. The earlier loop mv'd the live file once
# per hash, so a failure on the second iteration (or in the chmod, or the count) left a
# *partially* revoked list on disk with the old one still running, and the next unrelated
# reload would silently apply that half-finished edit. Now the live file is only ever
# replaced by a candidate that has passed every check, so there is no partial state to
# apply later: either the whole revoke happened or none of it did.
printf '%s\n' "$HASHES" > "$TOKEN_FILE.hashes"
awk 'NR == FNR { drop[tolower($0)] = 1; next }
  { l = $0; sub(/#.*/, "", l); gsub(/^[ \t]+|[ \t]+$/, "", l); if (!(tolower(l) in drop)) print }' \
  "$TOKEN_FILE.hashes" "$TOKEN_FILE" > "$TOKEN_FILE.next"
rm -f "$TOKEN_FILE.hashes"

EXPECTED=$(count_hashes "$TOKEN_FILE.next")
abandon_candidate() { rm -f "$TOKEN_FILE.next" "$TOKEN_FILE.bak"; }
for HASH in $HASHES; do
  if has_hash "$TOKEN_FILE.next" "$HASH"; then
    echo '!! a hash survived the edit; aborting without touching the live list' >&2
    abandon_candidate
    exit 1
  fi
done
if [ "$EXPECTED" -eq 0 ]; then
  # A genuinely blank/truncated file remains invalid. The exact marker is the only
  # explicit revoke-all representation, and the server accepts it only while invite
  # enrollment is configured. Confirm the running service reports that mode before
  # replacing the last hash, so this cannot turn an old relay into a reload no-op.
  CURRENT_HEALTH=$(curl -fsS -m 10 "$HEALTH" || true)
  if [[ "$CURRENT_HEALTH" != *'"enrollment":true'* ]] \
    || ! grep -q '^RELAY_ENROLLMENT_REGISTRY_FILE=/' "$ENV_FILE" \
    || ! grep -q '^RELAY_ADMIN_SOCKET=/' "$ENV_FILE"; then
    echo '!! this is the last legacy hash, but invite enrollment is not active;' >&2
    echo '   refusing to write a revoke-all marker the running relay cannot accept.' >&2
    abandon_candidate
    exit 1
  fi
  printf '%s\n' "$EMPTY_LEGACY_SENTINEL" > "$TOKEN_FILE.next"
fi
if ! valid_allowlist "$TOKEN_FILE.next"; then
  echo '!! the allowlist has a line the server will refuse to load — the reload would' >&2
  echo '   keep the old set (this token included). Aborting without touching the live' >&2
  echo '   list; fix /opt/whisper-relay/device-tokens by hand, then revoke again.' >&2
  abandon_candidate
  exit 1
fi

WANT=$(digest_of "$TOKEN_FILE.next")
mv "$TOKEN_FILE.next" "$TOKEN_FILE"
chmod 0644 "$TOKEN_FILE"
printf '    removed %s hash(es), %s left\n' "$((BEFORE - EXPECTED))" "$EXPECTED"

# `if ! ...`, not `... || { }`. Under `set -e` a failing reload exits the shell on the
# spot, so a recovery block placed after it is unreachable — the edited allowlist would
# stay in place with nobody restoring it.
if ! systemctl reload whisper-relay; then
  echo '!! reload failed; restoring the previous allowlist' >&2
  restore
  exit 1
fi
sleep 1
# The digest, not the count. A reload the server *rejected* keeps the old set, and its
# count can equal what the new file would have reported — so a matching count was never
# proof, and "we think they are cut off" is the wrong thing to be unsure of. A matching
# digest says the running server is serving exactly the list on disk.
AFTER=$(health_field legacyAllowlist || true)
[ -n "$AFTER" ] || AFTER=$(health_field allowlist || true)
if [ "$AFTER" != "$WANT" ]; then
  echo "!! relay is serving allowlist '$AFTER', expected '$WANT' — the revoke did NOT" >&2
  echo "   take effect; restoring the previous list" >&2
  restore
  exit 1
fi
rm -f "$TOKEN_FILE.bak"
printf '    revoked and live. %s tokens authorised (%s), their socket dropped, nobody else disturbed\n' \
  "$EXPECTED" "$AFTER"
REMOTE

echo "==> done"
