#!/usr/bin/env bash
# Publishes the already-reviewed, committed version as a signed Sparkle update.
#
# The order is intentional: source first, then the downloadable release asset, and the
# appcast last. A failure can leave an unused GitHub Release behind, but can never point
# running apps at an asset that is not publicly downloadable yet.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/update_common.sh"
REPOSITORY="limingyi1225/whisper-ml"
BRANCH="main"
LIVE_APPCAST="$ROOT_DIR/updates/appcast.xml"
LIVE_APPCAST_RELATIVE="updates/appcast.xml"
NOTES_FILE="${1:-}"

if [ "$#" -gt 1 ] || { [ -n "$NOTES_FILE" ] && [ ! -f "$NOTES_FILE" ]; }; then
  echo "usage: $0 [release-notes.md]" >&2
  exit 2
fi
if [ -n "$NOTES_FILE" ]; then
  NOTES_FILE="$(cd "$(dirname "$NOTES_FILE")" && pwd)/$(basename "$NOTES_FILE")"
fi

for command in git gh curl xmllint; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "!! required command is missing: $command" >&2
    exit 1
  fi
done
if ! gh auth status >/dev/null 2>&1; then
  echo "!! GitHub CLI is not authenticated; run: gh auth login" >&2
  exit 1
fi

cd "$ROOT_DIR"
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
  echo "!! updates may only be published from '$BRANCH' (currently '$CURRENT_BRANCH')" >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "!! the worktree is not clean" >&2
  echo "   Review and commit only the intended release changes before publishing." >&2
  git status --short >&2
  exit 1
fi

echo "==> checking release branch"
git fetch origin "$BRANCH"
BEHIND=$(git rev-list --count "HEAD..origin/$BRANCH")
if [ "$BEHIND" -ne 0 ]; then
  echo "!! local '$BRANCH' is behind origin by $BEHIND commit(s); reconcile it first" >&2
  exit 1
fi

BUILD_SETTINGS=$(xcodebuild -project Whisper.xcodeproj -scheme Whisper \
  -configuration Release -showBuildSettings 2>/dev/null)
VERSION=$(printf '%s\n' "$BUILD_SETTINGS" \
  | sed -n 's/^ *MARKETING_VERSION = //p' | sort -u)
BUILD=$(printf '%s\n' "$BUILD_SETTINGS" \
  | sed -n 's/^ *CURRENT_PROJECT_VERSION = //p' | sort -u)
if [ -z "$VERSION" ] || [ "$(printf '%s\n' "$VERSION" | wc -l | tr -d ' ')" -ne 1 ]; then
  echo "!! could not read one unambiguous Whisper marketing version" >&2
  exit 1
fi
if [ -z "$BUILD" ] || [ "$(printf '%s\n' "$BUILD" | wc -l | tr -d ' ')" -ne 1 ]; then
  echo "!! could not read one unambiguous Whisper build number" >&2
  exit 1
fi
case "$VERSION" in ''|*[!0-9A-Za-z.-]*) echo "!! unsafe version: $VERSION" >&2; exit 1 ;; esac
case "$BUILD" in ''|*[!0-9]*) echo "!! build must contain only digits: $BUILD" >&2; exit 1 ;; esac

TAG="v$VERSION"
ASSET_NAME="Whisper-$VERSION-$BUILD.dmg"
ASSET="$ROOT_DIR/dist/update/$ASSET_NAME"
STAGED_APPCAST="$ROOT_DIR/dist/update/appcast.xml"
EXPECTED_URL="https://github.com/$REPOSITORY/releases/download/$TAG/$ASSET_NAME"
FEED_URL="https://raw.githubusercontent.com/$REPOSITORY/$BRANCH/updates/appcast.xml"
HEAD_SHA=$(git rev-parse HEAD)
SOURCE_WORKTREE_PARENT=""
SOURCE_WORKTREE=""
SOURCE_WORKTREE_ADDED=0
RETRY_DIR=""
PUBLISH_LOCK="$ROOT_DIR/build/publish.lock"
PUBLISH_LOCK_ACQUIRED=0

cleanup() {
  local status=$?
  if [ "$SOURCE_WORKTREE_ADDED" -eq 1 ]; then
    git -C "$ROOT_DIR" worktree remove --force "$SOURCE_WORKTREE" >/dev/null 2>&1 || true
  fi
  if [ -n "$SOURCE_WORKTREE_PARENT" ]; then rm -rf "$SOURCE_WORKTREE_PARENT"; fi
  if [ -n "$RETRY_DIR" ]; then rm -rf "$RETRY_DIR"; fi
  if [ "$PUBLISH_LOCK_ACQUIRED" -eq 1 ] \
      && [ "$(cat "$PUBLISH_LOCK/pid" 2>/dev/null || true)" = "$$" ]; then
    rm -rf "$PUBLISH_LOCK"
  fi
  return "$status"
}
trap cleanup EXIT

acquire_publish_lock() {
  local holder=""
  mkdir -p "$(dirname "$PUBLISH_LOCK")"
  if ! mkdir "$PUBLISH_LOCK" 2>/dev/null; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      holder=$(cat "$PUBLISH_LOCK/pid" 2>/dev/null || true)
      [ -n "$holder" ] && break
      sleep 0.2
    done
    case "$holder" in
      ''|*[!0-9]*)
        echo "!! publishing is locked without a valid owner; if no publish is active:" >&2
        echo "   rm -rf '$PUBLISH_LOCK'" >&2
        return 1
        ;;
    esac
    if kill -0 "$holder" 2>/dev/null; then
      echo "!! another update publication (pid $holder) is already running" >&2
      return 1
    fi
    rm -rf "$PUBLISH_LOCK"
    if ! mkdir "$PUBLISH_LOCK" 2>/dev/null; then
      echo "!! another publisher claimed the release lock first" >&2
      return 1
    fi
  fi
  PUBLISH_LOCK_ACQUIRED=1
  printf '%s\n' "$$" > "$PUBLISH_LOCK/pid"
}

assert_release_checkout_unchanged() {
  local current_head status
  current_head=$(git -C "$ROOT_DIR" rev-parse HEAD)
  status=$(git -C "$ROOT_DIR" status --porcelain)
  if [ "$current_head" != "$HEAD_SHA" ] || [ -n "$status" ]; then
    echo "!! the primary checkout changed while the release was being prepared" >&2
    echo "   No release metadata or appcast will be published from a dirty checkout." >&2
    git -C "$ROOT_DIR" status --short >&2
    return 1
  fi
}

checkout_release_source() {
  local commit="$1"
  if [ "$SOURCE_WORKTREE_ADDED" -eq 1 ]; then
    echo "!! immutable release worktree was requested more than once" >&2
    return 1
  fi
  SOURCE_WORKTREE_PARENT=$(mktemp -d "${TMPDIR:-/tmp}/whisper-source.XXXXXX")
  SOURCE_WORKTREE="$SOURCE_WORKTREE_PARENT/source"
  echo "==> checking out immutable release source ($commit)"
  git -C "$ROOT_DIR" worktree add --detach --quiet "$SOURCE_WORKTREE" "$commit"
  SOURCE_WORKTREE_ADDED=1
}

verify_retained_release_artifacts() {
  local asset="${1:-$ASSET}"
  local appcast="${2:-$STAGED_APPCAST}"
  local source_public_key source_feed_url
  source_public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' \
    "$SOURCE_WORKTREE/Whisper-Info.plist" 2>/dev/null || true)
  source_feed_url=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' \
    "$SOURCE_WORKTREE/Whisper-Info.plist" 2>/dev/null || true)
  if [ -z "$source_public_key" ] || [ "$source_feed_url" != "$FEED_URL" ]; then
    echo "!! released source has invalid Sparkle key or feed configuration" >&2
    return 1
  fi
  resolve_sparkle_tools "$SOURCE_WORKTREE/Whisper.xcodeproj" Whisper
  verify_sparkle_signing_key "$source_public_key"
  verify_update_artifacts \
    "$asset" "$appcast" "$EXPECTED_URL" "$VERSION" "$BUILD"
}

resolve_release_tag_commit() {
  local object_type object_sha object
  object=$(gh api "repos/$REPOSITORY/git/ref/tags/$TAG" \
    --jq '.object.type + " " + .object.sha')
  read -r object_type object_sha <<< "$object"

  # GitHub Releases normally create lightweight tags, but handle annotated tags too.
  for _ in 1 2 3 4 5; do
    case "$object_type" in
      commit)
        printf '%s\n' "$object_sha"
        return 0
        ;;
      tag)
        object=$(gh api "repos/$REPOSITORY/git/tags/$object_sha" \
          --jq '.object.type + " " + .object.sha')
        read -r object_type object_sha <<< "$object"
        ;;
      *)
        echo "!! release tag points to unsupported object type: $object_type" >&2
        return 1
        ;;
    esac
  done
  echo "!! release tag nesting is unexpectedly deep" >&2
  return 1
}

authoritative_appcast_matches() {
  local commit="$1"
  local remote_appcast
  remote_appcast=$(mktemp "${TMPDIR:-/tmp}/whisper-appcast-api.XXXXXX")
  if gh api -H 'Accept: application/vnd.github.raw+json' \
      "repos/$REPOSITORY/contents/updates/appcast.xml?ref=$commit" \
      > "$remote_appcast" 2>/dev/null \
      && cmp -s "$LIVE_APPCAST" "$remote_appcast"; then
    rm -f "$remote_appcast"
    return 0
  fi
  rm -f "$remote_appcast"
  return 1
}

verify_raw_feed() {
  local remote_appcast deadline
  remote_appcast=$(mktemp "${TMPDIR:-/tmp}/whisper-appcast-raw.XXXXXX")
  deadline=$((SECONDS + 330))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if curl -fsSL --connect-timeout 3 --max-time 5 \
        -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
        "$FEED_URL" > "$remote_appcast" \
        && cmp -s "$LIVE_APPCAST" "$remote_appcast"; then
      rm -f "$remote_appcast"
      return 0
    fi
    sleep 5
  done
  rm -f "$remote_appcast"
  echo "!! GitHub accepted the appcast commit, but the raw feed still does not match" >&2
  echo "   after its 5-minute CDN TTL. The authoritative commit and release asset" >&2
  echo "   are already verified, so publication succeeded. Re-run this same command" >&2
  echo "   later to verify propagation; do not create another version or replace" >&2
  echo "   the release asset." >&2
  return 0
}

acquire_publish_lock

BUILD_IS_PUBLISHED=0
VERSION_IS_PUBLISHED=0
grep -Fq "<sparkle:version>$BUILD</sparkle:version>" "$LIVE_APPCAST" \
  && BUILD_IS_PUBLISHED=1
grep -Fq "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$LIVE_APPCAST" \
  && VERSION_IS_PUBLISHED=1

if [ "$BUILD_IS_PUBLISHED" -ne "$VERSION_IS_PUBLISHED" ]; then
  echo "!! either version $VERSION or build $BUILD has already been published" >&2
  echo "   Increment both MARKETING_VERSION and CURRENT_PROJECT_VERSION." >&2
  exit 1
fi

if [ "$BUILD_IS_PUBLISHED" -eq 1 ]; then
  echo "==> verifying already-published Whisper $VERSION ($BUILD)"
  if ! gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
    echo "!! appcast contains this version, but GitHub Release $TAG is missing" >&2
    exit 1
  fi
  RELEASE_COMMIT=$(resolve_release_tag_commit)
  APPCAST_COMMIT=$(git log -n 1 --format=%H -- updates/appcast.xml)
  if [ -z "$APPCAST_COMMIT" ] || [ "$HEAD_SHA" != "$APPCAST_COMMIT" ]; then
    echo "!! this version is already published, but HEAD contains later source changes" >&2
    echo "   Increment MARKETING_VERSION and CURRENT_PROJECT_VERSION for a new update." >&2
    exit 1
  fi
  APPCAST_PARENT=$(git rev-parse "$APPCAST_COMMIT^")
  if [ "$APPCAST_PARENT" != "$RELEASE_COMMIT" ]; then
    echo "!! published appcast commit is not directly based on the released source" >&2
    exit 1
  fi

  checkout_release_source "$RELEASE_COMMIT"
  RETRY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/whisper-release.XXXXXX")
  if ! gh release download "$TAG" --repo "$REPOSITORY" \
      --pattern "$ASSET_NAME" --dir "$RETRY_DIR" >/dev/null 2>&1; then
    echo "!! published release asset could not be downloaded for verification" >&2
    exit 1
  fi
  verify_retained_release_artifacts "$RETRY_DIR/$ASSET_NAME" "$LIVE_APPCAST"

  # This is the recovery path for an interruption during the final appcast push.
  git push origin "HEAD:$BRANCH"
  if ! authoritative_appcast_matches "$APPCAST_COMMIT"; then
    echo "!! GitHub Contents API does not return the appcast from $APPCAST_COMMIT" >&2
    exit 1
  fi
  curl -fsSL --max-time 60 --range 0-0 --output /dev/null "$EXPECTED_URL"
  verify_raw_feed
  echo "==> already published and verified: Whisper $VERSION ($BUILD)"
  echo "    release: https://github.com/$REPOSITORY/releases/tag/$TAG"
  echo "    appcast: $FEED_URL"
  exit 0
fi

echo "==> pushing reviewed source ($HEAD_SHA)"
git push origin "HEAD:$BRANCH"

# Build and install from an immutable detached checkout. Edits made in the primary
# worktree during notarization cannot change the bytes attached to HEAD_SHA.
checkout_release_source "$HEAD_SHA"

if gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
  echo "==> resuming GitHub Release $TAG"
  # Safe retry after an interruption: use the artifacts retained by the original run
  # and continue only when its published asset is byte-for-byte identical. Rebuilding
  # here would create a different notarized DMG even from unchanged source.
  RELEASE_COMMIT=$(resolve_release_tag_commit)
  if [ "$RELEASE_COMMIT" != "$HEAD_SHA" ]; then
    echo "!! release $TAG belongs to a different source commit" >&2
    echo "   release: $RELEASE_COMMIT" >&2
    echo "   current: $HEAD_SHA" >&2
    echo "   Increment the version/build; never attach new source to an old binary." >&2
    exit 1
  fi
  if [ ! -f "$ASSET" ] || [ ! -f "$STAGED_APPCAST" ]; then
    echo "!! release $TAG exists, but its retained local publishing artifacts do not" >&2
    echo "   Inspect the existing release; never rebuild and replace its public binary." >&2
    exit 1
  fi
  verify_retained_release_artifacts

  RETRY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/whisper-release.XXXXXX")
  if ! gh release download "$TAG" --repo "$REPOSITORY" \
      --pattern "$ASSET_NAME" --dir "$RETRY_DIR" >/dev/null 2>&1 \
      || ! cmp -s "$ASSET" "$RETRY_DIR/$ASSET_NAME"; then
    echo "!! release $TAG already exists with a missing or different asset" >&2
    echo "   Refusing to replace a binary users may already have downloaded." >&2
    exit 1
  fi
  echo "    existing release contains the identical asset; resuming"
else
  echo "==> building, signing and notarizing Whisper $VERSION ($BUILD)"
  "$SOURCE_WORKTREE/script/package_release.sh" --public
  if [ -n "$NOTES_FILE" ]; then
    WHISPER_UPDATE_DMG="$SOURCE_WORKTREE/dist/Whisper-public.dmg" \
      WHISPER_UPDATE_APP="$SOURCE_WORKTREE/build/public/developer-id/Whisper.app" \
      WHISPER_UPDATE_APPCAST="$SOURCE_WORKTREE/updates/appcast.xml" \
      WHISPER_UPDATE_OUTPUT_DIR="$ROOT_DIR/dist/update" \
      "$SOURCE_WORKTREE/script/prepare_update.sh" "$NOTES_FILE"
  else
    WHISPER_UPDATE_DMG="$SOURCE_WORKTREE/dist/Whisper-public.dmg" \
      WHISPER_UPDATE_APP="$SOURCE_WORKTREE/build/public/developer-id/Whisper.app" \
      WHISPER_UPDATE_APPCAST="$SOURCE_WORKTREE/updates/appcast.xml" \
      WHISPER_UPDATE_OUTPUT_DIR="$ROOT_DIR/dist/update" \
      "$SOURCE_WORKTREE/script/prepare_update.sh"
  fi
  if [ ! -f "$ASSET" ] || [ ! -f "$STAGED_APPCAST" ]; then
    echo "!! update preparation did not produce the expected asset and appcast" >&2
    exit 1
  fi
  verify_retained_release_artifacts

  assert_release_checkout_unchanged
  echo "==> publishing GitHub Release $TAG"
  if [ -n "$NOTES_FILE" ]; then
    gh release create "$TAG" "$ASSET" --repo "$REPOSITORY" \
      --target "$HEAD_SHA" --title "Whisper $VERSION" --notes-file "$NOTES_FILE"
  else
    gh release create "$TAG" "$ASSET" --repo "$REPOSITORY" \
      --target "$HEAD_SHA" --title "Whisper $VERSION" --generate-notes
  fi
fi

assert_release_checkout_unchanged
echo "==> verifying public download"
curl -fsSL --max-time 60 --range 0-0 --output /dev/null "$EXPECTED_URL"

echo "==> installing the released source locally"
"$SOURCE_WORKTREE/script/install_local.sh"

echo "==> publishing signed appcast last"
assert_release_checkout_unchanged
if [ -n "$(git diff --cached --name-only)" ]; then
  echo "!! unrelated staged changes appeared during publication" >&2
  git diff --cached --name-only >&2
  exit 1
fi
cp "$STAGED_APPCAST" "$LIVE_APPCAST"
if git diff --quiet -- "$LIVE_APPCAST_RELATIVE"; then
  echo "!! generated appcast did not change" >&2
  exit 1
fi
git commit --only -m "Publish Whisper $VERSION ($BUILD) update" -- "$LIVE_APPCAST_RELATIVE"
COMMITTED_PATHS=$(git diff-tree --no-commit-id --name-only -r HEAD)
if [ "$COMMITTED_PATHS" != "$LIVE_APPCAST_RELATIVE" ]; then
  echo "!! appcast commit contains an unexpected path; refusing to push" >&2
  printf '%s\n' "$COMMITTED_PATHS" >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "!! the checkout changed before the appcast push; refusing to publish" >&2
  git status --short >&2
  exit 1
fi
git push origin "HEAD:$BRANCH"

APPCAST_COMMIT=$(git rev-parse HEAD)
if ! authoritative_appcast_matches "$APPCAST_COMMIT"; then
  echo "!! GitHub Contents API does not return the appcast from $APPCAST_COMMIT" >&2
  exit 1
fi
verify_raw_feed

echo "==> published Whisper $VERSION ($BUILD)"
echo "    release: https://github.com/$REPOSITORY/releases/tag/$TAG"
echo "    appcast: $FEED_URL"
