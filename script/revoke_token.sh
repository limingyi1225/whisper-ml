#!/usr/bin/env bash
# Cuts one person off the relay, leaving everyone else untouched.
#
#   ./script/revoke_token.sh            → list who currently has access
#   ./script/revoke_token.sh alice      → revoke alice
#
# Their copy of the app keeps working until the restart below, then every connection
# it opens is refused with 401. Nothing on their Mac needs to be uninstalled, and no
# other person's token changes.
set -Eeuo pipefail

HOST="${RELAY_SSH_HOST:-nyuclass}"
ENV_FILE=/etc/whisper-relay.env
LEDGER=/opt/whisper-relay-backups/issued-tokens.tsv

NAME="${1:-}"

if [ -z "$NAME" ]; then
  echo "==> tokens currently authorised"
  ssh "$HOST" "set -e
    AUTHORISED=\$(sed -n 's/^RELAY_DEVICE_TOKEN_HASHES=//p' $ENV_FILE | tr ',' '\n' | grep -c . || true)
    printf '    %s in RELAY_DEVICE_TOKEN_HASHES\n\n' \"\$AUTHORISED\"
    if [ -s $LEDGER ]; then
      printf '    %-16s %-12s %s\n' NAME STATUS ISSUED
      while IFS=\$'\t' read -r name hash issued; do
        if grep -q \"\$hash\" $ENV_FILE; then status=active; else status=revoked; fi
        printf '    %-16s %-12s %s\n' \"\$name\" \"\$status\" \"\$issued\"
      done < $LEDGER
    else
      printf '    (no ledger yet — only your own token exists)\n'
    fi"
  echo
  echo "    revoke with: $0 <name>"
  exit 0
fi

echo "==> revoking '$NAME'"
ssh "$HOST" "set -e
  # *Every* hash on record for this name, not just the most recent. A re-issued build
  # (or a packaging run that failed after registering) leaves more than one row, and
  # revoking only the last would quietly leave an earlier token working forever.
  HASHES=\$(awk -F'\t' -v n='$NAME' '\$1 == n { print \$2 }' $LEDGER 2>/dev/null)
  if [ -z \"\$HASHES\" ]; then
    echo '!! no token on record for that name; run with no arguments to list' >&2
    exit 1
  fi
  cp -a $ENV_FILE $ENV_FILE.bak
  for HASH in \$HASHES; do
    # Handles the hash sitting first, last, or in the middle of the list; the pass
    # below collapses the separator it leaves behind, because a stray ',,' would parse
    # as an empty hash and fail the startup check that every entry is 64 hex chars.
    sed -i \"s/,\${HASH}//; s/\${HASH},//; s/=\${HASH}\\\$/=/\" $ENV_FILE
  done
  sed -i 's/,,/,/g; s/=,/=/; s/,\$//' $ENV_FILE
  for HASH in \$HASHES; do
    if grep -q \"\$HASH\" $ENV_FILE; then
      echo '!! a hash is still present after the edit; restoring and aborting' >&2
      mv $ENV_FILE.bak $ENV_FILE
      exit 1
    fi
  done
  printf '    removed %s hash(es)\n' \"\$(printf '%s\n' \$HASHES | grep -c .)\"
  if ! sed -n 's/^RELAY_DEVICE_TOKEN_HASHES=//p' $ENV_FILE | grep -qE '^[a-f0-9]{64}(,[a-f0-9]{64})*\$'; then
    echo '!! the remaining list is malformed; restoring and aborting' >&2
    mv $ENV_FILE.bak $ENV_FILE
    exit 1
  fi
  systemctl restart whisper-relay
  sleep 2
  systemctl is-active --quiet whisper-relay || {
    echo '!! relay did not come back; restoring' >&2
    mv $ENV_FILE.bak $ENV_FILE
    systemctl restart whisper-relay
    exit 1
  }
  rm -f $ENV_FILE.bak
  printf '    revoked. %s tokens still authorised\n' \
    \"\$(sed -n 's/^RELAY_DEVICE_TOKEN_HASHES=//p' $ENV_FILE | tr ',' '\n' | grep -c .)\""

echo "==> done"
