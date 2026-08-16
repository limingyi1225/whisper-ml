#!/usr/bin/env bash
# Test harness for the decision logic in script/deploy_relay.sh.
#
# The functions are lifted verbatim out of the deploy script and executed here, so the
# assertions in relay.test.js are about what that shell *does*. They used to be regexes
# over its source text, which is how a one-way latch survived review: the rule was that
# any single inconclusive attempt cleared the "every failure agreed" flag for good, so
# "inconclusive, rollback:http-404, rollback:http-404" kept a deployment two probes had
# proved broken — and every regex over the source still matched.
#
#   deploy_decisions.sh retry      < lines of "verdict:reason verdict:reason verdict:reason"
#   deploy_decisions.sh body       (no input; prints the body the last attempt returned)
#   deploy_decisions.sh attempt    < lines of "code<TAB>body"
#   deploy_decisions.sh rollback   with-modules | without-modules
#   deploy_decisions.sh roundtrip
set -Eeuo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/script/deploy_relay.sh"

lift() {
  # Everything from "name() {" to the next line that is exactly "}".
  awk -v fn="$1" '
    $0 == fn "() {" { inside = 1 }
    inside { print }
    inside && $0 == "}" { exit }
  ' "$SCRIPT"
}

for fn in probe_with_retries probe_attempt_verdict capture_backup restore_script restore_backup; do
  eval "$(lift "$fn")"
  [ "$(type -t "$fn")" = function ] || { echo "could not lift $fn" >&2; exit 1; }
done

sleep() { :; }   # the retries are the subject, not the waiting

# A classifier runs inside a command substitution, so its cursor has to live in a file.
# That is the same subshell boundary that makes the shipped classifiers hand their
# response body back through stdout instead of setting a variable.
IDXFILE=$(mktemp)
WORK=""
cleanup() { rm -f "$IDXFILE"; [ -z "$WORK" ] || rm -rf "$WORK"; }
trap cleanup EXIT

scripted() {
  local i item
  i=$(cat "$IDXFILE")
  printf '%s' "$((i + 1))" > "$IDXFILE"
  item=${SEQ[$i]}
  printf '%s\t%s\tbody-%s' "${item%%:*}" "${item#*:}" "$((i + 1))"
}

# A throwaway stand-in for the relay host: the paths capture_backup and restore_backup
# read and write, with ssh, systemctl and npm replaced by stubs. Sets the globals both
# functions close over.
setup_fake_remote() {
  WORK=$(mktemp -d)
  REMOTE_DIR="$WORK/remote"
  BACKUPS="$WORK/backups"
  ENV_FILE="$WORK/relay.env"
  UNIT_FILE="$WORK/whisper-relay.service"
  TOKEN_FILE="$WORK/device-tokens"
  REGISTRY_FILE="$WORK/registry.json"
  CREATED_TOKEN_FILE=0

  mkdir -p "$REMOTE_DIR/src" "$REMOTE_DIR/scripts" "$REMOTE_DIR/node_modules" "$BACKUPS"
  printf 'old\n' > "$REMOTE_DIR/src/index.js"
  printf '{"name":"relay"}\n' > "$REMOTE_DIR/package.json"
  printf '{"lockfileVersion":3}\n' > "$REMOTE_DIR/package-lock.json"
  printf 'PORT=8787\n' > "$REMOTE_DIR/.env.example"
  printf 'old env\n' > "$ENV_FILE"
  printf 'old unit\n' > "$UNIT_FILE"

  local stubs="$WORK/bin"
  mkdir -p "$stubs"
  printf '#!/bin/sh\nexit 0\n' > "$stubs/systemctl"
  # The stub reproduces the part that matters: npm ci starts by throwing the tree away.
  printf '#!/bin/sh\necho ran >> "%s"\nrm -rf node_modules\nmkdir -p node_modules\n: > node_modules/from-npm\n' \
    "$WORK/npm.log" > "$stubs/npm"
  chmod +x "$stubs/systemctl" "$stubs/npm"
  PATH="$stubs:$PATH"

  remote_ssh() { bash -c "$1"; }
}

report_modules() {
  local marker
  for marker in from-the-backup from-before-the-deploy from-npm; do
    if [ -e "$REMOTE_DIR/node_modules/$marker" ]; then echo "modules: $marker"; return; fi
  done
  echo "modules: missing"
}

report_npm() {
  if [ -f "$WORK/npm.log" ]; then echo "npm: ran"; else echo "npm: not-run"; fi
}

case "${1:-}" in
  retry)
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      read -r -a SEQ <<< "$line"
      printf 0 > "$IDXFILE"
      probe_with_retries scripted 2>/dev/null
      if [ "$PROBE_DECISION" = rollback ]; then
        printf '%s %s\n' "$PROBE_DECISION" "$PROBE_ROLLBACK_REASON"
      else
        printf '%s\n' "$PROBE_DECISION"
      fi
    done
    ;;

  body)
    always_inconclusive() { printf 'inconclusive\thttp-502\t<html>bad gateway</html>'; }
    probe_with_retries always_inconclusive 2>/dev/null
    printf '%s' "$PROBE_BODY"
    ;;

  attempt)
    while IFS=$'\t' read -r code body; do
      verdict=$(probe_attempt_verdict "$code" "$body")
      printf '%s\n' "${verdict%%$'\t'*}"
    done
    ;;

  rollback)
    # Runs the real restore_backup against a prepared set of backups. The question is
    # what a rollback does for dependencies: npm ci *deletes* node_modules before it
    # installs, so a forward install that died halfway leaves the box with nothing, and
    # a rollback that answers by running npm ci again has to succeed over the same
    # network that just failed.
    setup_fake_remote
    STAMP=20260816-120000
    printf 'half-installed\n' > "$REMOTE_DIR/node_modules/from-the-failed-deploy"
    printf 'new\n' > "$REMOTE_DIR/src/index.js"
    printf 'new env\n' > "$ENV_FILE"
    printf 'new unit\n' > "$UNIT_FILE"
    mkdir -p "$BACKUPS/manifests-$STAMP" "$BACKUPS/src-$STAMP" "$BACKUPS/scripts-$STAMP"
    printf 'old\n' > "$BACKUPS/src-$STAMP/index.js"
    printf 'old env\n' > "$BACKUPS/env-$STAMP"
    printf 'old unit\n' > "$BACKUPS/unit-$STAMP"
    printf '{"name":"old"}\n' > "$BACKUPS/manifests-$STAMP/package.json"
    if [ "${2:-}" = with-modules ]; then
      mkdir -p "$BACKUPS/modules-$STAMP"
      printf 'paired with the old lockfile\n' > "$BACKUPS/modules-$STAMP/from-the-backup"
    fi

    restore_backup
    printf 'src: %s\n' "$(cat "$REMOTE_DIR/src/index.js")"
    printf 'unit: %s\n' "$(cat "$UNIT_FILE")"
    report_modules
    report_npm
    ;;

  roundtrip)
    # Backup and rollback are two halves of one promise, written a few hundred lines
    # apart, and the second can only restore what the first thought to save. This runs
    # both, with the deploy's own destruction in between.
    setup_fake_remote
    printf 'the dependencies this deploy was running with\n' \
      > "$REMOTE_DIR/node_modules/from-before-the-deploy"

    STAMP=$(capture_backup)
    [ -n "$STAMP" ] || { echo "capture_backup returned no stamp" >&2; exit 1; }

    printf 'new\n' > "$REMOTE_DIR/src/index.js"
    rm -rf "$REMOTE_DIR/node_modules"   # what npm ci does before it installs

    restore_backup
    printf 'src: %s\n' "$(cat "$REMOTE_DIR/src/index.js")"
    report_modules
    report_npm
    ;;

  *)
    echo "usage: $0 retry|body|attempt|rollback|roundtrip" >&2
    exit 2
    ;;
esac
