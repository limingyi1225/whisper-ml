#!/usr/bin/env bash
# Ships server/ to the relay host and restarts it, rolling back if the new build
# does not come up healthy. Safe to re-run; every run leaves a timestamped backup.
# -E so the ERR trap below is inherited by functions and subshells; without it a
# failure inside one silently skips the rollback.
set -Eeuo pipefail

HOST="${RELAY_SSH_HOST:-nyuclass}"
REMOTE_DIR=/opt/whisper-relay
ENV_FILE=/etc/whisper-relay.env
BACKUPS=/opt/whisper-relay-backups
BASE_PATH="${RELAY_BASE_PATH:-/whisper-relay}"
PUBLIC_HEALTH="${RELAY_PUBLIC_HEALTH:-https://limingyi.com/whisper-relay/healthz}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR/server"

STAMP=""
# Flipped the instant the remote tree stops matching the backup. Everything from that
# point on has to roll back on *any* failure, not just the ones with an explicit check:
# the earlier version only guarded the health check, so a failed `npm ci` exited through
# `set -e` and left new source paired with a half-installed node_modules — a tree that
# keeps serving from memory and then dies at the next restart.
REMOTE_DIRTY=0

restore_backup() {
  ssh "$HOST" "set -e
    rm -rf $REMOTE_DIR/src
    cp -a $BACKUPS/src-$STAMP $REMOTE_DIR/src
    cp -a $BACKUPS/env-$STAMP $ENV_FILE
    cp -a $BACKUPS/manifests-$STAMP/. $REMOTE_DIR/
    cd $REMOTE_DIR && npm ci --omit=dev --no-audit --no-fund
    systemctl restart whisper-relay"
}

on_failure() {
  local status=$?
  trap - ERR
  if [ "$REMOTE_DIRTY" -eq 0 ]; then
    echo "!! failed before the remote tree was touched (exit $status); nothing to roll back" >&2
    exit "$status"
  fi
  echo "!! deploy failed (exit $status) — rolling back to $STAMP" >&2
  if restore_backup; then
    echo "!! rolled back to $STAMP" >&2
  else
    echo "!! ROLLBACK ALSO FAILED — the relay is down; restore by hand:" >&2
    echo "   ssh $HOST 'cd $REMOTE_DIR && cp -a $BACKUPS/src-$STAMP src && npm ci --omit=dev && systemctl restart whisper-relay'" >&2
  fi
  exit 1
}
trap on_failure ERR

echo "==> running tests before shipping"
npm test

# The model names the app actually sends. They used to be pinned independently in the
# Swift source, in config.js's defaults, and in the server's .env — three copies with
# nothing comparing them, and a deploy that changed only the first would go fully green
# and then 400 on the user's first sentence, because /healthz never sends a real
# request. Extracting them here and writing them into the env file below makes the app
# the single source of truth, so that drift cannot survive a deploy.
echo "==> reading the model names out of the app sources"
POLISH_MODEL=$(sed -n 's/^ *private static let model = "\(.*\)"$/\1/p' \
  "$ROOT_DIR/Whisper/Net/TranscriptPolisher.swift")
# Scoped to the enum body rather than grepping the whole file for `gpt-…`, so a later
# unrelated constant cannot quietly widen the server's allowlist.
TRANSCRIPTION_MODELS=$(awk '
  /^enum TranscriptionModel/ { inside = 1; next }
  inside && /^}/            { exit }
  inside && match($0, /case [a-zA-Z]+ = "[^"]+"/) {
    line = substr($0, RSTART, RLENGTH)
    split(line, parts, "\"")
    print parts[2]
  }' "$ROOT_DIR/Whisper/Core/AppSettings.swift" | paste -sd, -)
if [ -z "$POLISH_MODEL" ] || [ -z "$TRANSCRIPTION_MODELS" ]; then
  echo "!! could not read the model names from the Swift sources — the extraction" >&2
  echo "   patterns in this script have drifted from the code. Fix them rather than" >&2
  echo "   deploying: an empty allowlist would reject every request." >&2
  exit 1
fi
echo "    polish:        $POLISH_MODEL"
echo "    transcription: $TRANSCRIPTION_MODELS"

# Resolved here, before anything remote is touched, so a missing token fails the run
# instead of aborting halfway through a deploy that would then need a rollback. Read
# from the same keychain item the app writes, so no secret sits in this file or in
# shell history. Used by the smoke test at the very end.
SMOKE_TOKEN="${RELAY_SMOKE_TOKEN:-$(security find-generic-password \
  -s com.mingyili.Whisper -a relay-device-token -w 2>/dev/null || true)}"
if [ -z "$SMOKE_TOKEN" ] && [ "${RELAY_SKIP_SMOKE:-0}" != "1" ]; then
  echo "!! no device token available, so the post-deploy smoke test cannot run." >&2
  echo "   /healthz alone would pass a relay that rejects the app's model or has a" >&2
  echo "   dead OpenAI key, which is the whole reason the smoke test exists." >&2
  echo "   Set RELAY_SMOKE_TOKEN=…, or save the token in the app (设置 → 设备 Token)," >&2
  echo "   or re-run with RELAY_SKIP_SMOKE=1 to accept the weaker check." >&2
  exit 1
fi
[ -n "$SMOKE_TOKEN" ] || echo "    RELAY_SKIP_SMOKE=1 — the smoke test will not run"

echo "==> backing up current deployment on $HOST"
# The manifests are part of the version. Backing up only src/ makes a "rollback" that
# pairs old code with whatever dependencies the failed deploy installed.
STAMP=$(ssh "$HOST" "set -e
  STAMP=\$(date +%Y%m%d-%H%M%S)
  mkdir -p $BACKUPS/manifests-\$STAMP
  cp -a $REMOTE_DIR/src $BACKUPS/src-\$STAMP
  cp -a $ENV_FILE $BACKUPS/env-\$STAMP
  cp -a $REMOTE_DIR/package.json $REMOTE_DIR/package-lock.json \
     $BACKUPS/manifests-\$STAMP/
  printf '%s' \"\$STAMP\"")
echo "    backup stamp: $STAMP"

echo "==> uploading src/ and scripts/"
REMOTE_DIRTY=1
tar czf - src scripts package.json package-lock.json .env.example \
  | ssh "$HOST" "mkdir -p $REMOTE_DIR && tar xzf - -C $REMOTE_DIR"

echo "==> installing dependencies from the uploaded lockfile"
# Without this the box keeps whatever node_modules it already had, so a new or upgraded
# dependency silently runs against the old tree — and the failure shows up at runtime.
ssh "$HOST" "cd $REMOTE_DIR && npm ci --omit=dev --no-audit --no-fund"

echo "==> reconciling $ENV_FILE"
# RELAY_BASE_PATH lets the relay answer on both /v1/... and <base>/v1/..., so it no
# longer depends on nginx's proxy_pass keeping its trailing slash. MAX_TURN_AUDIO_BYTES
# is dropped so the default derived from the app's own 610 s buffer governs instead of
# a hand-picked constant that can drift away from it.
ssh "$HOST" "set -e
  umask 077
  sed -i '/^RELAY_BASE_PATH=/d;/^CLIENT_HEARTBEAT_INTERVAL_MS=/d;/^MAX_TURN_AUDIO_BYTES=/d;/^ALLOWED_POLISH_MODELS=/d;/^ALLOWED_TRANSCRIPTION_MODELS=/d' $ENV_FILE
  printf 'RELAY_BASE_PATH=%s\n' '$BASE_PATH' >> $ENV_FILE
  printf 'CLIENT_HEARTBEAT_INTERVAL_MS=25000\n' >> $ENV_FILE
  printf 'ALLOWED_POLISH_MODELS=%s\n' '$POLISH_MODEL' >> $ENV_FILE
  printf 'ALLOWED_TRANSCRIPTION_MODELS=%s\n' '$TRANSCRIPTION_MODELS' >> $ENV_FILE"

echo "==> restarting whisper-relay"
ssh "$HOST" "systemctl restart whisper-relay && sleep 2 && systemctl is-active whisper-relay"

echo "==> health check (loopback, both path forms, plus crash-loop check)"
# `/healthz` alone is not proof of a good deploy: it answers from the HTTP server while
# a misconfiguration that only bites when a bridge is constructed would still take the
# process down on the first real connection. Config now validates the endpoint URLs at
# startup, so that failure surfaces as a service that will not stay up — which is what
# the restart-counter check below catches.
ssh "$HOST" "set -e
  PORT=\$(sed -n 's/^PORT=//p' $ENV_FILE); PORT=\${PORT:-8787}
  curl -fsS -m 10 http://127.0.0.1:\$PORT/healthz >/dev/null
  curl -fsS -m 10 http://127.0.0.1:\$PORT$BASE_PATH/healthz >/dev/null
  BEFORE=\$(systemctl show whisper-relay -p NRestarts --value)
  sleep 5
  AFTER=\$(systemctl show whisper-relay -p NRestarts --value)
  test \"\$BEFORE\" = \"\$AFTER\" || { echo \"    service restarted (crash loop)\" >&2; exit 1; }
  systemctl is-active --quiet whisper-relay
  echo '    loopback ok, service stable'"

echo "==> health check (public)"
# The loopback check says the process is fine; only this one says the thing the app
# actually dials is fine. It used to be `curl ... && echo`, where curl sits on the left
# of an `&&` — a position `set -e` deliberately exempts — so TLS, Cloudflare or nginx
# could all be broken and the script would still print "done" and exit 0.
#
# Retried before giving up: a rollback triggered by one flaky hop through Cloudflare
# would be a self-inflicted outage of a perfectly good build. The body is matched too,
# because an edge that answers 200 with its own page is not the relay answering.
#
# Captured into a variable rather than piped into grep: `grep -q` exits on the first
# match, which SIGPIPEs curl, which under `pipefail` fails the whole pipeline — a
# healthy relay reported as dead, and with the rollback now wired up that would take a
# good build down.
public_health_ok() {
  local body
  for attempt in 1 2 3; do
    if body=$(curl -fsS -m 20 "$PUBLIC_HEALTH") && [[ "$body" == *'"ok":true'* ]]; then
      echo "    public ok: $body"
      return 0
    fi
    echo "    attempt $attempt failed" >&2
    [ "$attempt" -lt 3 ] && sleep 3
  done
  return 1
}
public_health_ok

if [ -n "$SMOKE_TOKEN" ]; then
  echo "==> smoke test (a real /v1/polish round trip)"
  SMOKE_URL="${PUBLIC_HEALTH%/healthz}/v1/polish"
  SMOKE_BODY=$(printf '{"model":"%s","messages":[{"role":"system","content":"只输出整理后的文本。"},{"role":"user","content":"<transcript>嗯 部署 冒烟 测试</transcript>"}],"reasoning_effort":"none"}' "$POLISH_MODEL")
  # No -f: the status code and the body are both wanted, especially on a rejection.
  SMOKE_OUT=$(curl -sS -m 30 -w '\n%{http_code}' \
    -H "authorization: Bearer $SMOKE_TOKEN" \
    -H 'content-type: application/json' \
    -d "$SMOKE_BODY" "$SMOKE_URL" || true)
  SMOKE_CODE=$(printf '%s' "$SMOKE_OUT" | tail -n1)
  SMOKE_TEXT=$(printf '%s' "$SMOKE_OUT" | sed '$d')
  case "$SMOKE_CODE" in
    200)
      echo "    polish ok ($POLISH_MODEL)"
      ;;
    400|401|403|424)
      # Exactly the drift this test exists for: a model the server does not allow, a
      # request shape it does not accept, a device token it no longer validates, or an
      # OpenAI key it cannot use. All of them are this deployment's problem.
      echo "!! smoke test rejected by the relay (HTTP $SMOKE_CODE): $SMOKE_TEXT" >&2
      false
      ;;
    *)
      # 429, 502, 504, a timeout: OpenAI or the edge, not this build. Rolling back a
      # good relay because OpenAI had a bad minute would be a self-inflicted outage.
      echo "!! smoke test inconclusive (HTTP ${SMOKE_CODE:-none}): $SMOKE_TEXT" >&2
      echo "   Treated as upstream trouble, not a bad deploy. Re-run to confirm." >&2
      ;;
  esac
fi

echo "==> pruning old backups (keeping the 10 most recent)"
# Every deploy leaves src-<stamp> plus manifests-<stamp>; unpruned that is unbounded
# growth on a small VPS. Runs last and never fails the deploy: a full disk is a problem,
# but rolling back a good relay because a cleanup hiccuped is a worse one.
ssh "$HOST" "cd $BACKUPS 2>/dev/null || exit 0
  ls -1d src-* 2>/dev/null | sort -r | tail -n +11 | xargs -r rm -rf
  ls -1d manifests-* 2>/dev/null | sort -r | tail -n +11 | xargs -r rm -rf
  ls -1 env-* 2>/dev/null | sort -r | tail -n +11 | xargs -r rm -f
  echo \"    \$(ls -1d src-* 2>/dev/null | wc -l) backups kept\"" || \
  echo "!! backup prune failed (harmless, deploy stands)" >&2

trap - ERR
echo "==> done. rollback if needed:"
echo "    ssh $HOST 'set -e; rm -rf $REMOTE_DIR/src; cp -a $BACKUPS/src-$STAMP $REMOTE_DIR/src; cp -a $BACKUPS/env-$STAMP $ENV_FILE; cp -a $BACKUPS/manifests-$STAMP/. $REMOTE_DIR/; cd $REMOTE_DIR && npm ci --omit=dev --no-audit --no-fund; systemctl restart whisper-relay'"
