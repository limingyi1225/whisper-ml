#!/usr/bin/env bash
# Ships server/ to the relay host and restarts it, rolling back if the new build
# does not come up healthy. Safe to re-run; every run leaves a timestamped backup.
# -E so the ERR trap below is inherited by functions and subshells; without it a
# failure inside one silently skips the rollback.
set -Eeuo pipefail
[ "$#" -eq 0 ] || { echo "usage: $0" >&2; exit 2; }

HOST="${RELAY_SSH_HOST:-nyuclass}"
REMOTE_DIR=/opt/whisper-relay
ENV_FILE=/etc/whisper-relay.env
BACKUPS=/opt/whisper-relay-backups
TOKEN_FILE=/opt/whisper-relay/device-tokens
REGISTRY_FILE=/var/lib/whisper-relay/registry.json
ADMIN_SOCKET=/run/whisper-relay/admin.sock
UNIT_FILE=/etc/systemd/system/whisper-relay.service
BASE_PATH="${RELAY_BASE_PATH:-/whisper-relay}"
PUBLIC_HEALTH="${RELAY_PUBLIC_HEALTH:-https://limingyi.com/whisper-relay/healthz}"
DEPLOY_LOCK_FILE=/run/lock/whisper-relay-deploy.lock

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR/server"

STAMP=""
# Flipped the instant the remote tree stops matching the backup. Everything from that
# point on has to roll back on *any* failure, not just the ones with an explicit check:
# the earlier version only guarded the health check, so a failed `npm ci` exited through
# `set -e` and left new source paired with a half-installed node_modules — a tree that
# keeps serving from memory and then dies at the next restart.
REMOTE_DIRTY=0
# Set when *this* run is the one that creates the allowlist file. Rolling back has to
# remove it again, because the pre-deploy state had no file and the restored old code
# does not read one — it reads RELAY_DEVICE_TOKEN_HASHES, which this run deletes from
# the env file. Leaving the file behind makes the restored pair inconsistent: the env
# snapshot is a frozen copy of the hashes as they were at migration time, so from then
# on it would authorise anyone revoked since and reject everyone issued since.
CREATED_TOKEN_FILE=0
REMOTE_LOCK_HELD=0
REMOTE_LOCK_PID=""
REMOTE_LOCK_TEMP=""

# Anything spliced into command text that a *remote* shell re-parses has to be checked
# here, because over there a quote or a semicolon is root. These are functions rather
# than inline conditions so the test harness can lift and exercise them.
#
# `.` and `-` are legal inside a segment but a segment may not be `.` or `..`: the
# loopback check curls both `/healthz` and `$BASE_PATH/healthz` to prove base-path
# routing works, and a traversal segment collapses those two URLs into one, so the
# check would pass without testing anything.
valid_base_path() {
  local candidate=$1
  [[ "$candidate" =~ ^(/[A-Za-z0-9_.-]+)*$ ]] || return 1
  [[ "$candidate" =~ (^|/)\.\.?(/|$) ]] && return 1
  return 0
}

valid_model_list() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$ ]]
}

# EnvironmentFile is line-oriented. A carriage return is just as destructive as a
# newline here: it leaves a visually plausible assignment whose value includes an
# invisible byte. Keep this a function so the deploy decision tests execute the exact
# guard used by the shipping script.
valid_gemini_key_shape() {
  [ -n "$1" ] \
    && [ "${#1}" -le 512 ] \
    && [[ "$1" != *$'\n'* ]] \
    && [[ "$1" != *$'\r'* ]]
}

# `updated` means the rollback's EnvironmentFile snapshot contains a different value,
# not merely that the operator exported GEMINI_API_KEY again. CI commonly supplies the
# same secret on every run; calling that a change makes a pre-existing revoked key look
# attributable to this artifact.
gemini_key_provenance() {
  case "$1" in
    SAME) printf retained ;;
    DIFFERENT) printf updated ;;
    *) return 1 ;;
  esac
}

# `date +%Y%m%d-%H%M%S` on a host we already trust, but it is captured from a remote
# shell's entire stdout — a stray `echo` in a login file lands in it — and it is then
# interpolated bare into every rollback path, the one place that has to work when
# things are already wrong.
valid_stamp() {
  [[ "$1" =~ ^[0-9]{8}-[0-9]{6}$ ]]
}

cleanup_remote_lock_temp() {
  [ -n "$REMOTE_LOCK_TEMP" ] || return 0
  rm -f "$REMOTE_LOCK_TEMP/hold" "$REMOTE_LOCK_TEMP/status" "$REMOTE_LOCK_TEMP/control"
  rmdir "$REMOTE_LOCK_TEMP"
  REMOTE_LOCK_TEMP=""
}

remote_ssh() {
  if [ "$REMOTE_LOCK_HELD" -ne 1 ] \
    || ! kill -0 "$REMOTE_LOCK_PID" 2>/dev/null; then
    echo "!! remote deploy-lock owner is gone; refusing a new SSH connection" >&2
    return 74
  fi

  # Every mutable/checking channel is multiplexed through the TCP connection whose
  # primary session owns flock. ProxyCommand=false makes a missing control socket fail
  # instead of OpenSSH silently falling back to a fresh, unlocked connection.
  local status=0
  if ssh -S "$REMOTE_LOCK_TEMP/control" -o ControlMaster=no \
    -o ProxyCommand=false -o BatchMode=yes "$HOST" "$@"; then
    status=0
  else
    status=$?
  fi
  if [ "$status" -ne 0 ]; then return "$status"; fi
  if ! kill -0 "$REMOTE_LOCK_PID" 2>/dev/null; then
    echo "!! remote deploy-lock owner died during the SSH command" >&2
    return 74
  fi
}

# Two callers with opposite needs, so they are two functions.
#
# The explicit call at the end of a verified deploy must report an unhealthy lease as a
# non-zero exit: the work is done, but it was not confidently serialised and the
# operator has to know. The EXIT trap must do the reverse — its return value *becomes*
# the script's exit status, so it can neither invent a failure after a good deploy nor
# mask a real one.
release_remote_lock() {
  if [ "$REMOTE_LOCK_HELD" -ne 1 ]; then
    cleanup_remote_lock_temp
    return 0
  fi
  # Closing the only writer gives the remote `cat` EOF. Its process exits, fd 8 closes,
  # and the kernel releases flock — including after local interruption or power loss.
  exec 9>&-
  local status=0
  if wait "$REMOTE_LOCK_PID"; then status=0; else status=$?; fi
  REMOTE_LOCK_HELD=0
  cleanup_remote_lock_temp
  if [ "$status" -ne 0 ]; then
    echo "!! remote deploy-lock lease ended unexpectedly (ssh exit $status)" >&2
    return 1
  fi
}

# The EXIT-trap face of the same release: carry the pending exit status through
# untouched, whatever the lease did.
release_remote_lock_quietly() {
  local incoming=$?
  release_remote_lock || true
  return "$incoming"
}

acquire_remote_lock() {
  echo "==> acquiring remote deploy lock"
  REMOTE_LOCK_TEMP=$(mktemp -d "/tmp/whisper-relay-lock.XXXXXX")
  mkfifo "$REMOTE_LOCK_TEMP/hold"

  # The ssh process lives for the whole deploy. fd 8 owns the remote flock while `cat`
  # keeps the connection attached to our FIFO; there is no directory owner record that
  # can survive kill -9 and block every later deploy forever.
  # In a subshell that ignores the signals first, because `exec` keeps a SIG_IGN
  # disposition and bash only sets SIGINT and SIGQUIT to SIG_IGN in asynchronous
  # children when job control is off. SIGTERM and SIGHUP got the default, so a closed
  # terminal or a `kill` on the process group killed the lock owner outright — measured
  # — and every remote_ssh after that refuses on its own `kill -0` guard. The rollback
  # that the INT/TERM/HUP trap exists to run could not run, which is the one moment the
  # connection matters most.
  ( trap '' INT QUIT TERM HUP
    exec ssh -M -S "$REMOTE_LOCK_TEMP/control" \
    -o ControlMaster=yes -o ControlPersist=no \
    -o BatchMode=yes -o ConnectTimeout=10 \
    -o ServerAliveInterval=10 -o ServerAliveCountMax=2 \
    "$HOST" "set -e
    exec 8>$DEPLOY_LOCK_FILE
    if ! flock -n 8; then printf 'BUSY\n'; exit 73; fi
    printf 'LOCKED\n'
    cat >/dev/null" ) \
    < "$REMOTE_LOCK_TEMP/hold" > "$REMOTE_LOCK_TEMP/status" &
  REMOTE_LOCK_PID=$!
  # Bash 3.2 has no dynamic-fd syntax. fd 9 is intentionally reserved for this lease;
  # keeping it open is the lifetime signal delivered to remote `cat`.
  exec 9>"$REMOTE_LOCK_TEMP/hold"

  local state=""
  local attempt
  # TCP connect has its own 10 s deadline, but authentication and opening the first
  # remote channel come afterwards. On the production host that whole handshake has
  # measured 7-11 s, so a 10 s local poll could close a lease that was about to report
  # LOCKED and then misleadingly print "ssh exit 0". This bounds the complete handshake.
  for attempt in $(seq 1 400); do
    if [ -s "$REMOTE_LOCK_TEMP/status" ]; then
      state=$(sed -n '1p' "$REMOTE_LOCK_TEMP/status")
      break
    fi
    if ! kill -0 "$REMOTE_LOCK_PID" 2>/dev/null; then break; fi
    sleep 0.05
  done

  if [ "$state" = LOCKED ] && kill -0 "$REMOTE_LOCK_PID" 2>/dev/null; then
    REMOTE_LOCK_HELD=1
    echo "    exclusive remote flock held"
    return 0
  fi

  exec 9>&-
  local status=0
  if wait "$REMOTE_LOCK_PID"; then status=0; else status=$?; fi
  cleanup_remote_lock_temp
  if [ "$state" = BUSY ]; then
    echo "!! deploy not started; another backup/upload/restart transaction holds the lock" >&2
  else
    echo "!! could not acquire remote deploy lock (ssh exit $status)" >&2
  fi
  exit 1
}

trap release_remote_lock_quietly EXIT

# The text of the rollback, as one remote script. It is written to the backup directory
# at backup time as well as run from here, so the by-hand recovery instructions can point
# at a file on the box instead of restating this — an earlier version restated it as a
# one-liner in two `echo`s, and keeping three copies in step by hand is not a thing that
# stays true.
restore_script() {
  # The unit file is part of the version too. This deploy adds ExecReload=kill -HUP to
  # it; roll back the source without rolling that back and the restored server has no
  # SIGHUP handler — Node's default for SIGHUP is to die — so the next issue/revoke's
  # `systemctl reload` would kill the relay and drop everyone mid-sentence.
  # The allowlist file is restored only in the one case where this run created it —
  # by deleting it, back to not existing. Otherwise it is left strictly alone: it is
  # live data, and "rolling back" an allowlist means resurrecting revoked tokens.
  cat <<REMOTE
set -e
# Copy into place beside the live tree, then swap. Copying is the part that can run out
# of disk or be cut off, and while it runs the live tree is still whole; the swap that
# follows is renames within one filesystem. Deleting first and copying second — which is
# what this used to do — meant an interrupted rollback left no src/ at all: not the old
# version, not the new one, nothing to serve and nothing to diff.
rm -rf $REMOTE_DIR/src.restoring $REMOTE_DIR/scripts.restoring $REMOTE_DIR/node_modules.restoring
cp -a $BACKUPS/src-$STAMP $REMOTE_DIR/src.restoring
cp -a $BACKUPS/scripts-$STAMP $REMOTE_DIR/scripts.restoring
# Prefer the dependency snapshot: it is already known to pair with the restored
# lockfile, and a rollback is exactly the moment not to depend on the registry being
# reachable. Absent only for a first-ever deploy.
if [ -d $BACKUPS/modules-$STAMP ]; then
  cp -a $BACKUPS/modules-$STAMP $REMOTE_DIR/node_modules.restoring
else
  # Nothing to restore, and what is here belongs to the deploy that just failed —
  # possibly half-installed, and in any case matched to the lockfile being replaced.
  rm -rf $REMOTE_DIR/node_modules
fi

rm -rf $REMOTE_DIR/src $REMOTE_DIR/scripts
mv $REMOTE_DIR/src.restoring $REMOTE_DIR/src
mv $REMOTE_DIR/scripts.restoring $REMOTE_DIR/scripts
if [ -d $REMOTE_DIR/node_modules.restoring ]; then
  rm -rf $REMOTE_DIR/node_modules
  mv $REMOTE_DIR/node_modules.restoring $REMOTE_DIR/node_modules
fi

# Every cheap local restore happens before the one step that can block on the network.
# Both orderings of that were wrong before: the fallback npm ci ran while
# package-lock.json was still the *new* one, so a rollback of a dependency bump
# installed the bumped tree under the old source and then overwrote the lockfile it had
# just installed from; and when that npm ci failed — which it does for the same reason
# the deploy did, a box that lost its network — `set -e` abandoned the rollback with the
# new env file still in place. That env file has had RELAY_DEVICE_TOKEN_HASHES stripped
# from it by this very deploy, so the restored old code, which reads exactly that
# variable, comes back up rejecting every device.
cp -a $BACKUPS/env-$STAMP $ENV_FILE
cp -a $BACKUPS/unit-$STAMP $UNIT_FILE
cp -a $BACKUPS/manifests-$STAMP/. $REMOTE_DIR/
if [ '$CREATED_TOKEN_FILE' = 1 ]; then rm -f $TOKEN_FILE; fi
systemctl daemon-reload

if [ ! -d $REMOTE_DIR/node_modules ]; then
  # No snapshot existed, so whatever the failed deploy left has to go and be rebuilt
  # from the lockfile restored just above.
  cd $REMOTE_DIR && npm ci --omit=dev --no-audit --no-fund
fi
systemctl restart whisper-relay
REMOTE
}

# Puts the rollback on the box as a runnable file. The by-hand instructions then point
# at it instead of restating it: the previous arrangement kept three copies of the
# sequence in step by hand, and both echoes had already drifted back to the delete-first
# ordering that was removed for being unsafe, with no mention of the allowlist file at
# all. Rewritten whenever CREATED_TOKEN_FILE can have changed, because that flag is
# baked into the text.
publish_restore_script() {
  restore_script | remote_ssh "cat > $BACKUPS/restore-$STAMP.sh"
}

restore_backup() {
  # Via a variable, not straight into the argument: a command substitution that fails
  # expands to the empty string, and `remote_ssh ""` runs an empty remote script and
  # succeeds — a rollback that does nothing at all and reports that it worked.
  local script
  script=$(restore_script) || return 1
  [ -n "$script" ] || { echo "!! rollback script came out empty; refusing to run it" >&2; return 1; }
  remote_ssh "$script"
}

on_failure() {
  local status=$?
  trap - ERR
  # A second Ctrl-C must not cut the rollback in half.
  trap '' INT TERM HUP
  if [ "$REMOTE_DIRTY" -eq 0 ]; then
    echo "!! failed before the remote tree was touched (exit $status); nothing to roll back" >&2
    exit "$status"
  fi
  echo "!! deploy failed (exit $status) — rolling back to $STAMP" >&2
  if restore_backup; then
    echo "!! rolled back to $STAMP" >&2
  else
    echo "!! ROLLBACK ALSO FAILED — the relay is down; restore by hand:" >&2
    echo "   ssh $HOST bash $BACKUPS/restore-$STAMP.sh" >&2
  fi
  exit 1
}
trap on_failure ERR
# A terminal Ctrl-C reaches EXIT but never ERR. Without these the lock is released, the
# half-installed tree is left standing, and the second release Mac this lock exists to
# exclude is free to start — and to snapshot that corrupted tree as *its* rollback
# target. Signals route to the same handler, which rolls back before EXIT releases.
trap on_failure INT TERM HUP

echo "==> running tests before shipping"
npm test

# The model names the app actually sends. They used to be pinned independently in the
# Swift source, in config.js's defaults, and in the server's .env — three copies with
# nothing comparing them, and a deploy that changed only the first would go fully green
# and then 400 on the user's first sentence, because /healthz never sends a real
# request. Extracting them here and writing them into the env file below makes the app
# the single source of truth, so that drift cannot survive a deploy.
echo "==> reading the model names out of the app sources"
# Located by what they declare, not by where they live. Both of these moved into
# DictationKit/ when the voice stack was extracted into a local package, which broke the
# hardcoded paths — safely (the guard below fails the deploy rather than shipping an
# empty allowlist), but it broke them. A search cannot be invalidated by the next move.
#
# `head -1` is deliberately not used to pick a winner: grep would take SIGPIPE and, under
# `pipefail`, fail the pipeline. Ambiguity is an error here anyway — two files declaring
# the same thing means this script can no longer know which one the app compiles.
declaring() {
  local matches
  matches=$(grep -rlE "$1" "$ROOT_DIR/Whisper" "$ROOT_DIR/DictationKit" \
    --include='*.swift' 2>/dev/null || true)
  if [ -z "$matches" ]; then
    echo "!! nothing declares /$1/ any more — the extraction patterns in this script" >&2
    echo "   have drifted from the code. Fix them rather than deploying: an empty" >&2
    echo "   allowlist would reject every request." >&2
    exit 1
  fi
  if [ "$(printf '%s\n' "$matches" | wc -l | tr -d ' ')" != 1 ]; then
    echo "!! more than one file declares /$1/, so which one the app compiles is a" >&2
    echo "   guess. Refusing to guess:" >&2
    printf '%s\n' "$matches" | sed 's/^/     /' >&2
    exit 1
  fi
  printf '%s' "$matches"
}

# `(public )?` on both anchors: extraction into a package made these declarations public,
# and an anchor that only matched the internal form silently found nothing.
POLISH_SOURCE=$(declaring '^ *(public |private )?static let model = "')
# `sed -E`, not basic regex: `\(a\|b\)` alternation is a GNU extension that BSD sed —
# which is the sed on this Mac — treats as literal characters, so the pattern matched
# nothing and silently returned empty.
POLISH_MODEL=$(sed -En 's/^ *(public |private )?static let model = "([^"]*)"$/\2/p' \
  "$POLISH_SOURCE")
# Scoped to the enum body rather than grepping the whole file for `gpt-…`, so a later
# unrelated constant cannot quietly widen the server's allowlist.
MODELS_SOURCE=$(declaring '^(public )?enum TranscriptionModel')
TRANSCRIPTION_MODELS=$(awk '
  /^(public )?enum TranscriptionModel/ { inside = 1; next }
  inside && /^}/                       { exit }
  inside && match($0, /case [a-zA-Z]+ = "[^"]+"/) {
    line = substr($0, RSTART, RLENGTH)
    split(line, parts, "\"")
    print parts[2]
  }' "$MODELS_SOURCE" | paste -sd, -)
if [ -z "$POLISH_MODEL" ] || [ -z "$TRANSCRIPTION_MODELS" ]; then
  echo "!! could not read the model names from the Swift sources — the extraction" >&2
  echo "   patterns in this script have drifted from the code. Fix them rather than" >&2
  echo "   deploying: an empty allowlist would reject every request." >&2
  echo "   polish source:        ${POLISH_SOURCE:-none}" >&2
  echo "   transcription source: ${MODELS_SOURCE:-none}" >&2
  exit 1
fi
echo "    from ${POLISH_SOURCE#"$ROOT_DIR/"} and ${MODELS_SOURCE#"$ROOT_DIR/"}"
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
if [ -n "$SMOKE_TOKEN" ] && [[ ! "$SMOKE_TOKEN" =~ ^relay_[A-Za-z0-9_-]{40,80}$ ]]; then
  echo "!! the smoke-test device token has an invalid format" >&2
  exit 1
fi
# The token is validated because it is a credential; this one is validated because it is
# spliced into command text that a *remote* shell then re-parses — inside single quotes
# at the env-file write, and bare inside a URL at the loopback check. A quote or a
# semicolon in it would run as root on the relay host. Every other operator-settable
# value either stays local (RELAY_PUBLIC_HEALTH) or is passed as a single argv entry
# that ssh never re-parses (RELAY_SSH_HOST).
if ! valid_base_path "$BASE_PATH"; then
  echo "!! RELAY_BASE_PATH must be empty or /-separated path segments: $BASE_PATH" >&2
  exit 2
fi
# Two lines below the env-file write this guard was written for, the same construct
# interpolates these — and they come out of Swift source by regex, which excludes `"`
# but not `'`. A model name carrying a quote closes the shell quoting and runs as root
# on the relay at the next deploy.
if ! valid_model_list "$POLISH_MODEL"; then
  echo "!! the polish model name is not a plain model identifier: $POLISH_MODEL" >&2
  exit 2
fi
if ! valid_model_list "$TRANSCRIPTION_MODELS"; then
  echo "!! the transcription model list is not plain model identifiers: $TRANSCRIPTION_MODELS" >&2
  exit 2
fi
[ -n "$SMOKE_TOKEN" ] || echo "    RELAY_SKIP_SMOKE=1 — the smoke test will not run"

# Supplied for the first Gemini deployment, then retained in the remote EnvironmentFile
# on ordinary later deploys. It travels over the locked SSH channel's stdin and is never
# interpolated into remote command text or printed.
GEMINI_DEPLOY_KEY="${GEMINI_API_KEY:-}"
GEMINI_KEY_PROVENANCE=retained
if [ -n "$GEMINI_DEPLOY_KEY" ]; then
  if ! valid_gemini_key_shape "$GEMINI_DEPLOY_KEY"; then
    echo "!! GEMINI_API_KEY has an invalid shape" >&2
    exit 2
  fi
fi

# One owner covers the whole mutable transaction, including verification and any
# rollback. A local-only lock cannot coordinate two release Macs, and locking each ssh
# command separately still lets another deploy enter between upload and env/restart.
acquire_remote_lock

# Check the retained credential before taking a backup or changing any remote file.
# This stays behind the deploy flock: a separate unlocked preflight SSH has a race with
# another deploy replacing the EnvironmentFile between the check and lock acquisition.
# REMOTE_DIRTY is still zero here, so failure exits clearly without a pointless rollback.
if [ -n "$GEMINI_DEPLOY_KEY" ]; then
  echo "==> comparing supplied Gemini credential with the retained value"
  # The secret crosses stdin and is compared remotely. Only SAME/DIFFERENT comes back;
  # neither argv nor stdout contains credential material.
  GEMINI_KEY_MATCH=$(printf '%s\n' "$GEMINI_DEPLOY_KEY" | remote_ssh "set -e
    IFS= read -r GEMINI_VALUE
    if grep -Fqx -- \"GEMINI_API_KEY=\$GEMINI_VALUE\" $ENV_FILE; then
      printf SAME
    else
      printf DIFFERENT
    fi")
  if ! GEMINI_KEY_PROVENANCE=$(gemini_key_provenance "$GEMINI_KEY_MATCH"); then
    echo "!! could not determine whether GEMINI_API_KEY changes the retained value" >&2
    false
  fi
  echo "    credential provenance: $GEMINI_KEY_PROVENANCE"
else
  echo "==> checking retained Gemini credential"
  if ! remote_ssh "grep -q '^GEMINI_API_KEY=.' $ENV_FILE"; then
    echo "!! no GEMINI_API_KEY was supplied and the remote EnvironmentFile has none" >&2
    echo "   Set GEMINI_API_KEY for the first Gemini deployment." >&2
    false
  fi
  echo "    existing remote credential found"
fi

echo "==> backing up current deployment on $HOST"
# The manifests are part of the version. Backing up only src/ makes a "rollback" that
# pairs old code with whatever dependencies the failed deploy installed.
capture_backup() {
  remote_ssh "set -e
    STAMP=\$(date +%Y%m%d-%H%M%S)
    mkdir -p $BACKUPS/manifests-\$STAMP
    cp -a $REMOTE_DIR/src $BACKUPS/src-\$STAMP
    cp -a $ENV_FILE $BACKUPS/env-\$STAMP
    cp -a $UNIT_FILE $BACKUPS/unit-\$STAMP
    # Disaster copy only — deliberately NOT in restore_backup: the allowlist is live
    # data, not part of the code version, and 'rolling it back' would resurrect tokens
    # revoked since the stamp. It exists so a lost file is recoverable by hand.
    if [ -f $TOKEN_FILE ]; then cp -a $TOKEN_FILE $BACKUPS/device-tokens-\$STAMP; fi
    # Also a disaster copy only. Enrollment state is live data: restoring an older copy
    # would make used invites reusable and revive devices revoked after this deployment.
    if [ -f $REGISTRY_FILE ]; then cp -a $REGISTRY_FILE $BACKUPS/enrollment-registry-\$STAMP; fi
    cp -a $REMOTE_DIR/scripts $BACKUPS/scripts-\$STAMP
    # npm ci *deletes* node_modules before it installs, so a forward install that dies
    # halfway leaves the box with no dependencies at all — and the rollback's own npm ci
    # then has to succeed over the same network that just failed. This copy makes the
    # rollback local: the tree here matches the package-lock.json in manifests-\$STAMP
    # exactly, because both are snapshots of the same moment. 212K a deploy, pruned with
    # everything else. Absent on a first-ever deploy, which the restore handles.
    if [ -d $REMOTE_DIR/node_modules ]; then
      cp -a $REMOTE_DIR/node_modules $BACKUPS/modules-\$STAMP
    fi
    cp -a $REMOTE_DIR/package.json $REMOTE_DIR/package-lock.json $REMOTE_DIR/.env.example \
       $BACKUPS/manifests-\$STAMP/
    printf '%s' \"\$STAMP\""
}
STAMP=$(capture_backup)
if ! valid_stamp "$STAMP"; then
  echo "!! the remote backup stamp is not a timestamp: ${STAMP:-<empty>}" >&2
  echo "   (something on the relay writes to stdout for non-interactive shells)" >&2
  exit 1
fi
echo "    backup stamp: $STAMP"
publish_restore_script

echo "==> uploading src/ and scripts/"
REMOTE_DIRTY=1
COPYFILE_DISABLE=1 tar czf - src scripts package.json package-lock.json .env.example \
  | remote_ssh "set -e
  mkdir -p $REMOTE_DIR
  # A rollback that was interrupted mid-copy leaves these behind, and nothing on the
  # success path removed them — so a full spare copy of src, scripts and node_modules
  # could sit here indefinitely, which is its own problem when the interruption was a
  # full disk in the first place.
  rm -rf $REMOTE_DIR/src.restoring $REMOTE_DIR/scripts.restoring $REMOTE_DIR/node_modules.restoring
  rm -rf $REMOTE_DIR/src $REMOTE_DIR/scripts
  tar xzf - -C $REMOTE_DIR"

echo "==> installing dependencies from the uploaded lockfile"
# Without this the box keeps whatever node_modules it already had, so a new or upgraded
# dependency silently runs against the old tree — and the failure shows up at runtime.
remote_ssh "cd $REMOTE_DIR && npm ci --omit=dev --no-audit --no-fund"

echo "==> reconciling $ENV_FILE"
# RELAY_BASE_PATH lets the relay answer on both /v1/... and <base>/v1/..., so it no
# longer depends on nginx's proxy_pass keeping its trailing slash. MAX_TURN_AUDIO_BYTES
# is dropped so the default derived from the app's own 610 s buffer governs instead of
# a hand-picked constant that can drift away from it.
remote_ssh "set -e
  umask 077
  sed -i '/^RELAY_BASE_PATH=/d;/^CLIENT_HEARTBEAT_INTERVAL_MS=/d;/^MAX_CONNECTIONS_PER_DEVICE=/d;/^MAX_TURN_AUDIO_BYTES=/d;/^ALLOWED_POLISH_MODELS=/d;/^ALLOWED_TRANSCRIPTION_MODELS=/d;/^RELAY_ENROLLMENT_REGISTRY_FILE=/d;/^RELAY_ADMIN_SOCKET=/d;/^MAX_ENROLLMENT_ATTEMPTS_PER_MINUTE=/d;/^MAX_TRANSCRIPTION_SECONDS_PER_DEVICE_PER_DAY=/d;/^MAX_TOTAL_TRANSCRIPTION_SECONDS_PER_DAY=/d;/^MAX_POLISH_REQUESTS_PER_DEVICE_PER_DAY=/d;/^MAX_TOTAL_POLISH_REQUESTS_PER_DAY=/d' $ENV_FILE
  printf 'RELAY_BASE_PATH=%s\n' '$BASE_PATH' >> $ENV_FILE
  printf 'CLIENT_HEARTBEAT_INTERVAL_MS=25000\n' >> $ENV_FILE
  printf 'MAX_CONNECTIONS_PER_DEVICE=5\n' >> $ENV_FILE
  printf 'ALLOWED_POLISH_MODELS=%s\n' '$POLISH_MODEL' >> $ENV_FILE
  printf 'ALLOWED_TRANSCRIPTION_MODELS=%s\n' '$TRANSCRIPTION_MODELS' >> $ENV_FILE
  printf 'RELAY_ENROLLMENT_REGISTRY_FILE=%s\n' '$REGISTRY_FILE' >> $ENV_FILE
  printf 'RELAY_ADMIN_SOCKET=%s\n' '$ADMIN_SOCKET' >> $ENV_FILE
  printf 'MAX_ENROLLMENT_ATTEMPTS_PER_MINUTE=10\n' >> $ENV_FILE
  printf 'MAX_TRANSCRIPTION_SECONDS_PER_DEVICE_PER_DAY=7200\n' >> $ENV_FILE
  printf 'MAX_TOTAL_TRANSCRIPTION_SECONDS_PER_DAY=43200\n' >> $ENV_FILE
  printf 'MAX_POLISH_REQUESTS_PER_DEVICE_PER_DAY=1000\n' >> $ENV_FILE
  printf 'MAX_TOTAL_POLISH_REQUESTS_PER_DAY=6000\n' >> $ENV_FILE"

echo "==> provisioning Gemini credential"
if [ -n "$GEMINI_DEPLOY_KEY" ]; then
  printf '%s\n' "$GEMINI_DEPLOY_KEY" | remote_ssh "set -e
    umask 077
    IFS= read -r GEMINI_VALUE
    test -n \"\$GEMINI_VALUE\"
    sed -i '/^GEMINI_API_KEY=/d' $ENV_FILE
    printf 'GEMINI_API_KEY=%s\n' \"\$GEMINI_VALUE\" >> $ENV_FILE"
  echo "    updated from this deploy's environment"
else
  echo "    existing remote credential retained"
fi

echo "==> provisioning the reloadable allowlist"
# Asked before the file is touched, so a rollback knows whether removing it restores the
# previous state or destroys the live allowlist. Exit 1 is the remote `test` saying the
# file is absent. Any other non-zero is transport/lock failure and must hit the ERR trap:
# treating ssh 255 (or our lost-lease 74) as "absent" would make rollback delete a live
# allowlist that this deploy never created.
if remote_ssh "[ -s $TOKEN_FILE ]"; then
  echo "    allowlist file already present; leaving it as the source of truth"
else
  TOKEN_FILE_STATUS=$?
  if [ "$TOKEN_FILE_STATUS" -eq 1 ]; then
    CREATED_TOKEN_FILE=1
    echo "    no allowlist file yet — this run creates it (and a rollback removes it)"
    # The flag is interpolated into the published rollback, so it has to be republished.
    publish_restore_script
  else
    echo "!! could not determine whether the live allowlist exists (exit $TOKEN_FILE_STATUS)" >&2
    false
  fi
fi
# The allowlist has to live somewhere the *service* can read. systemd parses
# EnvironmentFile as root before dropping to the DynamicUser, so the 0600
# /etc/whisper-relay.env is unreadable at runtime and cannot be re-read on SIGHUP —
# which is what issuing or revoking a token needs, so that neither has to restart the
# relay and disconnect everyone mid-sentence. These are SHA-256 hashes, not tokens:
# nothing in this file is replayable, so 0644 costs nothing.
remote_ssh "set -e
  if [ ! -s $TOKEN_FILE ]; then
    # Captured and checked before anything is written: '... | grep . > file' truncates
    # the file the moment the pipeline starts, so an empty migration source would eat
    # the very file whose absence it was reacting to, and then fail the deploy anyway.
    if MIGRATED=\$(sed -n 's/^RELAY_DEVICE_TOKEN_HASHES=//p' $ENV_FILE | tr ',' '\n' | grep .); then
      printf '%s\n' \"\$MIGRATED\" > $TOKEN_FILE
      echo '    migrated existing hashes out of the env file'
    else
      # Enrollment is configured by this deploy, so a fresh install with no legacy
      # devices has an explicit representation distinct from a truncated file.
      printf '%s\n' '# whisper-relay: intentionally empty legacy allowlist' > $TOKEN_FILE
      echo '    no legacy hashes to migrate; created an intentional-empty allowlist'
    fi
  fi
  chmod 0644 $TOKEN_FILE
  EMPTY_LEGACY_SENTINEL='# whisper-relay: intentionally empty legacy allowlist'
  if ! awk -v marker=\"\$EMPTY_LEGACY_SENTINEL\" '
    {
      raw = \$0
      gsub(/^[ \t]+|[ \t]+\$/, \"\", raw)
      if (raw == marker) markerLines += 1
      if (length(raw)) nonblank += 1
      line = \$0
      sub(/#.*/, \"\", line)
      gsub(/^[ \t]+|[ \t]+\$/, \"\", line)
      if (length(line)) {
        hashes += 1
        if (tolower(line) !~ /^[a-f0-9]{64}\$/) bad = 1
      }
    }
    END {
      intentionalEmpty = (markerLines == 1 && nonblank == 1 && hashes == 0)
      exit (intentionalEmpty || (markerLines == 0 && hashes > 0 && !bad)) ? 0 : 1
    }' $TOKEN_FILE; then
    echo '!! legacy allowlist is neither valid hashes nor the sole intentional-empty marker' >&2
    exit 1
  fi
  # The env snapshot dies the moment the file becomes the source of truth. Left in
  # place it only ever gets staler — issue/revoke touch the file, never the env — and
  # a later deploy that found the file lost would have 'migrated' that fossil back in,
  # resurrecting every token revoked since. Better no fallback than a wrong one.
  sed -i '/^RELAY_DEVICE_TOKEN_HASHES=/d' $ENV_FILE
  grep -q '^RELAY_DEVICE_TOKEN_FILE=' $ENV_FILE \
    || printf 'RELAY_DEVICE_TOKEN_FILE=%s\n' '$TOKEN_FILE' >> $ENV_FILE
  UNIT=$UNIT_FILE
  # Reconcile each scalar directive, rather than appending a second value only when the
  # exact desired line is absent. An old later RuntimeDirectoryMode=0755 would otherwise
  # override the new 0700 line even though all of the grep checks below passed.
  grep -q '^DynamicUser=yes$' \$UNIT || {
    echo '!! the service no longer uses DynamicUser=yes; refusing to guess ownership' >&2
    exit 1
  }
  sed -i '/^RuntimeDirectory=/d;/^RuntimeDirectoryMode=/d;/^StateDirectory=/d;/^StateDirectoryMode=/d' \$UNIT
  sed -i '/^DynamicUser=yes$/a RuntimeDirectory=whisper-relay\nRuntimeDirectoryMode=0700\nStateDirectory=whisper-relay\nStateDirectoryMode=0700' \$UNIT
  grep -q '^RuntimeDirectory=whisper-relay$' \$UNIT
  grep -q '^RuntimeDirectoryMode=0700$' \$UNIT
  grep -q '^StateDirectory=whisper-relay$' \$UNIT
  grep -q '^StateDirectoryMode=0700$' \$UNIT
  if ! grep -q '^ExecReload=' \$UNIT; then
    sed -i '/^ExecStart=/a ExecReload=/bin/kill -HUP \$MAINPID' \$UNIT
    echo '    added ExecReload to the unit'
  fi
  # Unconditional because any directive above may have changed the unit.
  # Tying daemon-reload only to ExecReload meant an already-reloadable service ignored
  # newly added StateDirectory paths and then failed its first enrollment-aware restart.
  systemctl daemon-reload
  LEGACY_COUNT=\$(awk '{ sub(/#.*/, \"\"); gsub(/^[ \\t]+|[ \\t]+\$/, \"\"); if (length) seen[tolower(\$0)] = 1 } END { print length(seen) }' $TOKEN_FILE)
  printf '    %s hashes in the legacy allowlist\n' \"\$LEGACY_COUNT\""

echo "==> restarting whisper-relay"
remote_ssh "systemctl restart whisper-relay && sleep 2 && systemctl is-active whisper-relay"

echo "==> health check (loopback, both path forms, plus crash-loop check)"
# `/healthz` alone is not proof of a good deploy: it answers from the HTTP server while
# a misconfiguration that only bites when a bridge is constructed would still take the
# process down on the first real connection. Config now validates the endpoint URLs at
# startup, so that failure surfaces as a service that will not stay up — which is what
# the restart-counter check below catches.
remote_ssh "set -e
  PORT=\$(sed -n 's/^PORT=//p' $ENV_FILE); PORT=\${PORT:-8787}
  curl -fsS -m 10 http://127.0.0.1:\$PORT/healthz >/dev/null
  curl -fsS -m 10 http://127.0.0.1:\$PORT$BASE_PATH/healthz >/dev/null
  test -S '$ADMIN_SOCKET'
  ADMIN=\$(curl -fsS --unix-socket '$ADMIN_SOCKET' http://localhost/admin/status)
  case \"\$ADMIN\" in
    *'\"pendingInvites\"'*) ;;
    *) echo '    admin socket returned the wrong body' >&2; exit 1 ;;
  esac
  BEFORE=\$(systemctl show whisper-relay -p NRestarts --value)
  sleep 5
  AFTER=\$(systemctl show whisper-relay -p NRestarts --value)
  test \"\$BEFORE\" = \"\$AFTER\" || { echo \"    service restarted (crash loop)\" >&2; exit 1; }
  systemctl is-active --quiet whisper-relay
  echo '    loopback ok, service stable'"

# ---- one rule for all three public probes ------------------------------------------
# The three checks below (health, enrollment, polish) each ask the same question: is the
# thing that was just deployed broken, or is the path between here and it having a bad
# minute? They used to answer it three different ways, and two of them were two-state —
# a single 502 from Cloudflare counted as proof the new build was bad and triggered a
# rollback plus a second restart of a relay that was fine.
#
# $1 names a function that makes one attempt and echoes "<verdict>\t<reason>\t<body>".
# The verdict is pass, rollback (the relay itself answered, and answered wrongly) or
# inconclusive (nothing that can be attributed to this build). A rollback needs *two*
# attempts naming the same reason: one attempt is not evidence, and reasons are
# normalised so that genuine repeats collapse onto the same string.
#
# Sets PROBE_DECISION (pass|rollback|inconclusive), PROBE_REASON (the last reason seen),
# PROBE_BODY (the last body seen) and PROBE_ROLLBACK_REASON (the deterministic reason,
# if any attempt named one — reported even when it was not reproduced, because an
# operator should hear about it).
probe_with_retries() {
  local classify=$1
  local attempt classification rest verdict reason
  local rollback_reason_1="" rollback_reason_2="" last_rollback_reason=""
  local rollback_matches_1=0 rollback_matches_2=0
  PROBE_DECISION=""
  PROBE_REASON=""
  PROBE_BODY=""
  PROBE_ROLLBACK_REASON=""
  for attempt in 1 2 3; do
    classification=$("$classify")
    verdict=${classification%%$'\t'*}
    rest=${classification#*$'\t'}
    reason=${rest%%$'\t'*}
    PROBE_REASON=$reason
    PROBE_BODY=${rest#*$'\t'}
    if [ "$verdict" = pass ]; then
      PROBE_DECISION=pass
      return 0
    fi
    if [ "$verdict" = rollback ]; then
      last_rollback_reason=$reason
      if [ "$rollback_reason_1" = "$reason" ]; then
        rollback_matches_1=$((rollback_matches_1 + 1))
      elif [ "$rollback_reason_2" = "$reason" ]; then
        rollback_matches_2=$((rollback_matches_2 + 1))
      elif [ -z "$rollback_reason_1" ]; then
        rollback_reason_1=$reason
        rollback_matches_1=1
      else
        rollback_reason_2=$reason
        rollback_matches_2=1
      fi
    fi
    echo "    attempt $attempt: $reason" >&2
    [ "$attempt" -lt 3 ] && sleep 3
  done
  PROBE_ROLLBACK_REASON=$last_rollback_reason
  if [ "$rollback_matches_1" -ge 2 ]; then
    PROBE_ROLLBACK_REASON=$rollback_reason_1
    PROBE_DECISION=rollback
  elif [ "$rollback_matches_2" -ge 2 ]; then
    PROBE_ROLLBACK_REASON=$rollback_reason_2
    PROBE_DECISION=rollback
  else
    PROBE_DECISION=inconclusive
  fi
}

# Separates "the relay answered, wrongly" from "something else answered instead". Only
# the first says anything about the code just uploaded. Cloudflare's own 429 (the edge
# IP is shared), a 000 transport failure, a gateway 5xx and an HTML WAF page are all
# the second kind, however deterministic they look from here.
probe_attempt_verdict() {
  local code=$1 body=$2
  # An allowlist, like the smoke classifier next door. This one used to be a denylist —
  # any status not named as transient, with a body merely containing a JSON-ish key,
  # counted as deterministic — and the two therefore disagreed about the same response.
  # The enrollment probe deliberately POSTs malformed JSON to a public route, which is
  # exactly the shape a WAF rule flags, so a Cloudflare 403 reproduced on the second
  # attempt and rolled back a relay that was fine.
  [[ "$code" =~ ^[0-9]{3}$ ]] || {
    printf 'inconclusive\thttp-%s' "${code:-none}"
    return 0
  }
  # The route is gone. Whichever hop lost it, a deploy is what changed the routing, so
  # this is attributable without needing the body to prove it.
  if [ "$code" = 404 ]; then
    printf 'rollback\thttp-404'
    return 0
  fi
  # Everything else has to be the relay's own voice: a JSON body, on a status this
  # relay actually answers these two routes with. An edge announces its own trouble
  # with 403, 409, 3xx and the gateway 5xx range, and does it in HTML.
  case "$body" in
    *'"ok":'*|*'"code":'*|*'"error":'*) ;;
    *)
      printf 'inconclusive\tnot-a-relay-body-http-%s' "$code"
      return 0
      ;;
  esac
  case "$code" in
    200|400|401|500) printf 'rollback\thttp-%s' "$code" ;;
    *) printf 'inconclusive\thttp-%s' "$code" ;;
  esac
}

report_unreproduced_failure() {
  [ -n "$PROBE_ROLLBACK_REASON" ] || return 0
  echo "   one attempt did name a deterministic failure ($PROBE_ROLLBACK_REASON)," >&2
  echo "   but no other attempt reproduced it. Worth a look by hand." >&2
}

classify_public_health() {
  local out code body
  out=$(curl -sS -m 20 -w '\n%{http_code}' "$PUBLIC_HEALTH" || true)
  code=$(printf '%s' "$out" | tail -n1)
  body=$(printf '%s' "$out" | sed '$d')
  if [ "$code" = 200 ] \
    && [[ "$body" == *'"ok":true'* ]] \
    && [[ "$body" == *'"enrollment":true'* ]]; then
    printf 'pass\thttp-200\t%s' "$body"
    return 0
  fi
  printf '%s\t%s' "$(probe_attempt_verdict "$code" "$body")" "$body"
}

classify_public_enrollment() {
  local out code body
  out=$(curl -sS -m 20 -w '\n%{http_code}' \
    -H 'content-type: application/json' --data-binary '{' \
    "$PUBLIC_ENROLLMENT" || true)
  code=$(printf '%s' "$out" | tail -n1)
  body=$(printf '%s' "$out" | sed '$d')
  if [ "$code" = 400 ] && [[ "$body" == *'"code":"enrollment_invalid_request"'* ]]; then
    printf 'pass\thttp-400-as-designed\t%s' "$body"
    return 0
  fi
  printf '%s\t%s' "$(probe_attempt_verdict "$code" "$body")" "$body"
}

classify_polish_smoke() {
  local out code body
  # No -f: the status code and the body are both evidence. Feed the credential through
  # curl's stdin config; an Authorization `-H` exposes the token in the process list.
  out=$(printf 'header = "authorization: Bearer %s"\n' "$SMOKE_TOKEN" \
    | curl --config - -sS -m 30 -w '\n%{http_code}' \
    -H 'content-type: application/json' \
    -d "$SMOKE_BODY" "$SMOKE_URL" || true)
  code=$(printf '%s' "$out" | tail -n1)
  body=$(printf '%s' "$out" | sed '$d')
  # A crashing classifier is not evidence about the deployment either, but it should say
  # so by name rather than arriving as an empty verdict that happens to read as one.
  local verdict
  verdict=$(printf '%s' "$body" | node "$ROOT_DIR/script/relay_smoke_verdict.mjs" "$code") \
    || verdict=$'inconclusive\tsmoke-classifier-failed'
  printf '%s\t%s' "$verdict" "$body"
}

classify_gemini_setup_smoke() {
  local result verdict reason
  # The device token travels on stdin, never argv. The Node probe dials the same public
  # WebSocket route as the app, sends the app's Gemini session.update, and reports pass
  # only after the Relay has received Google's setupComplete and emitted session.updated.
  result=$(printf '%s\n' "$SMOKE_TOKEN" \
    | node "$ROOT_DIR/server/scripts/gemini-smoke.mjs" \
      "$GEMINI_SMOKE_URL" "$GEMINI_KEY_PROVENANCE" || true)
  verdict=${result%%$'\t'*}
  reason=${result#*$'\t'}
  case "$verdict" in
    pass|rollback|inconclusive) ;;
    *) verdict=inconclusive; reason=gemini-smoke-classifier-failed ;;
  esac
  [ -n "$reason" ] || reason=gemini-smoke-classifier-failed
  printf '%s\t%s\t' "$verdict" "$reason"
}

echo "==> health check (public)"
# The loopback check says the process is fine; only this one says the thing the app
# actually dials is fine. It used to be `curl ... && echo`, where curl sits on the left
# of an `&&` — a position `set -e` deliberately exempts — so TLS, Cloudflare or nginx
# could all be broken and the script would still print "done" and exit 0.
#
# The body is matched too, because an edge that answers 200 with its own page is not the
# relay answering. Captured into a variable rather than piped into grep: `grep -q` exits
# on the first match, which SIGPIPEs curl, which under `pipefail` fails the whole
# pipeline — a healthy relay reported as dead.
probe_with_retries classify_public_health
case "$PROBE_DECISION" in
  pass) echo "    public ok: $PROBE_BODY" ;;
  rollback)
    echo "!! public health check repeatedly proved a bad deployment" >&2
    echo "   ($PROBE_ROLLBACK_REASON): $PROBE_BODY" >&2
    false
    ;;
  *)
    echo "!! public health check inconclusive after retries ($PROBE_REASON);" >&2
    report_unreproduced_failure
    echo "   the loopback check passed, so the relay process is up and this is the path" >&2
    echo "   between here and it. Rolling back would not fix that and would cost another" >&2
    echo "   restart, so the deployment is kept. Verify by hand." >&2
    ;;
esac

echo "==> enrollment check (public route, deliberately invalid request)"
PUBLIC_ENROLLMENT="${PUBLIC_HEALTH%/healthz}/v1/enroll"
probe_with_retries classify_public_enrollment
case "$PROBE_DECISION" in
  pass) echo "    public enrollment route ok" ;;
  rollback)
    echo "!! public enrollment route repeatedly proved a bad deployment" >&2
    echo "   ($PROBE_ROLLBACK_REASON): $PROBE_BODY" >&2
    false
    ;;
  *)
    echo "!! enrollment probe inconclusive after retries ($PROBE_REASON);" >&2
    report_unreproduced_failure
    echo "   local health and the admin socket passed, so the deployment is kept." >&2
    echo "   No rollback or second restart was performed." >&2
    ;;
esac

if [ -n "$SMOKE_TOKEN" ]; then
  echo "==> smoke test (a real Gemini setup through the public Relay)"
  GEMINI_SMOKE_URL="${PUBLIC_HEALTH%/healthz}/v1/realtime?intent=transcription&provider=gemini"
  # No synthetic audio is needed to validate the credential. session.updated is emitted
  # only after Google accepts the key, model and setup and returns setupComplete.
  probe_with_retries classify_gemini_setup_smoke
  case "$PROBE_DECISION" in
    pass) echo "    Gemini setup ok (gemini-3.5-transcribe-live)" ;;
    rollback)
      echo "!! Gemini setup smoke repeatedly proved a bad deployment" >&2
      echo "   ($PROBE_ROLLBACK_REASON)" >&2
      false
      ;;
    *)
      echo "!! Gemini setup smoke inconclusive after retries ($PROBE_REASON);" >&2
      report_unreproduced_failure
      echo "   local/public health and enrollment passed, so the deployment is kept." >&2
      echo "   No rollback or second restart was performed." >&2
      ;;
  esac

  echo "==> smoke test (a real /v1/polish round trip)"
  SMOKE_URL="${PUBLIC_HEALTH%/healthz}/v1/polish"
  SMOKE_BODY=$(printf '{"model":"%s","messages":[{"role":"system","content":"只输出整理后的文本。"},{"role":"user","content":"<transcript>嗯 部署 冒烟 测试</transcript>"}],"reasoning_effort":"none"}' "$POLISH_MODEL")
  # A valid client body proves the whole round trip. A deterministic contract or config
  # failure, named twice, rolls the artifact back. OpenAI, network and edge failures are
  # reported without causing a second restart of an otherwise healthy relay — an
  # upstream 429 must not become a self-inflicted outage for every live dictation.
  probe_with_retries classify_polish_smoke
  case "$PROBE_DECISION" in
    pass) echo "    polish ok ($POLISH_MODEL)" ;;
    rollback)
      echo "!! smoke test repeatedly proved a bad deployment" >&2
      echo "   ($PROBE_ROLLBACK_REASON): $PROBE_BODY" >&2
      false
      ;;
    *)
      echo "!! polish smoke inconclusive after retries ($PROBE_REASON);" >&2
      report_unreproduced_failure
      echo "   local/public health and enrollment passed, so the deployment is kept." >&2
      echo "   No rollback or second restart was performed." >&2
      ;;
  esac
fi

echo "==> pruning old backups (keeping the 10 most recent)"
# Every deploy leaves src-<stamp> plus manifests-<stamp>; unpruned that is unbounded
# growth on a small VPS. Runs last and never fails the deploy: a full disk is a problem,
# but rolling back a good relay because a cleanup hiccuped is a worse one.
remote_ssh "cd $BACKUPS 2>/dev/null || exit 0
  ls -1d src-* 2>/dev/null | sort -r | tail -n +11 | xargs -r rm -rf
  ls -1d scripts-* 2>/dev/null | sort -r | tail -n +11 | xargs -r rm -rf
  ls -1d modules-* 2>/dev/null | sort -r | tail -n +11 | xargs -r rm -rf
  ls -1 restore-*.sh 2>/dev/null | sort -r | tail -n +11 | xargs -r rm -f
  ls -1d manifests-* 2>/dev/null | sort -r | tail -n +11 | xargs -r rm -rf
  ls -1 env-* 2>/dev/null | sort -r | tail -n +11 | xargs -r rm -f
  ls -1 unit-* 2>/dev/null | sort -r | tail -n +11 | xargs -r rm -f
  ls -1 device-tokens-* 2>/dev/null | sort -r | tail -n +11 | xargs -r rm -f
  ls -1 enrollment-registry-* 2>/dev/null | sort -r | tail -n +11 | xargs -r rm -f
  echo \"    \$(ls -1d src-* 2>/dev/null | wc -l) backups kept\"" || \
  echo "!! backup prune failed (harmless, deploy stands)" >&2

# Verification and cleanup are complete. An unhealthy lease must make the command
# non-zero because the deploy was not confidently serialized, but must not roll a
# healthy verified service back. Disable both traps, then release explicitly.
trap - ERR
trap - EXIT
# Before the release, not after: the release can fail on its own, and `set -e` then took
# the script out without ever telling the operator that the deploy they were watching
# had in fact succeeded, or how to undo it.
echo "==> done. rollback if needed:"
echo "    ssh $HOST bash $BACKUPS/restore-$STAMP.sh"
release_remote_lock
