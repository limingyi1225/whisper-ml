#!/usr/bin/env bash
# Shared Sparkle-tool discovery and artifact verification for packaging and publishing.
# Callers must enable their own shell safety flags before sourcing this file.

resolve_sparkle_tools() {
  local project="$1"
  local scheme="$2"
  local build_dir derived_data

  echo "==> locating Sparkle tools"
  xcodebuild -resolvePackageDependencies -project "$project" -scheme "$scheme" >/dev/null
  build_dir=$(xcodebuild -project "$project" -scheme "$scheme" \
    -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
    | sed -n 's/^ *BUILD_DIR = //p')
  if [ -z "$build_dir" ] \
      || [ "$(printf '%s\n' "$build_dir" | wc -l | tr -d ' ')" != 1 ]; then
    echo "!! could not resolve one unambiguous Xcode BUILD_DIR" >&2
    return 1
  fi

  derived_data="${build_dir%/Build/Products}"
  SPARKLE_GENERATE_APPCAST="$derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
  SPARKLE_SIGN_UPDATE="$derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
  SPARKLE_GENERATE_KEYS="$derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys"
  if [ ! -x "$SPARKLE_GENERATE_APPCAST" ] \
      || [ ! -x "$SPARKLE_SIGN_UPDATE" ] \
      || [ ! -x "$SPARKLE_GENERATE_KEYS" ]; then
    echo "!! Sparkle's signing tools were not resolved under:" >&2
    echo "   $(dirname "$SPARKLE_GENERATE_APPCAST")" >&2
    return 1
  fi
}

verify_sparkle_signing_key() {
  local expected_public_key="$1"
  local keychain_public_key

  keychain_public_key=$("$SPARKLE_GENERATE_KEYS" -p 2>/dev/null || true)
  if [ -z "$keychain_public_key" ] || [ "$keychain_public_key" != "$expected_public_key" ]; then
    echo "!! Sparkle signing key does not match the public key embedded in the app" >&2
    echo "   Refusing to create a build that installed clients would be unable to update." >&2
    return 1
  fi
  echo "    Sparkle signing key matches the app"
}

verify_update_artifacts() {
  local asset="$1"
  local appcast="$2"
  local expected_url="$3"
  local expected_version="$4"
  local expected_build="$5"
  local item_xpath enclosure_xpath item_count actual_url actual_version actual_build
  local signature declared_length actual_length

  if [ ! -f "$asset" ] || [ ! -f "$appcast" ]; then
    echo "!! update asset or appcast is missing" >&2
    return 1
  fi
  if ! xmllint --noout "$appcast" 2>/dev/null; then
    echo "!! appcast is not valid XML" >&2
    return 1
  fi

  item_xpath="//*[local-name()='item'][*[local-name()='enclosure' and @url='$expected_url']]"
  enclosure_xpath="$item_xpath/*[local-name()='enclosure' and @url='$expected_url']"
  item_count=$(xmllint --xpath "count($item_xpath)" "$appcast" 2>/dev/null || true)
  actual_url=$(xmllint --xpath "string($enclosure_xpath/@url)" "$appcast" 2>/dev/null || true)
  actual_version=$(xmllint --xpath \
    "string($item_xpath/*[local-name()='shortVersionString'])" "$appcast" 2>/dev/null || true)
  actual_build=$(xmllint --xpath \
    "string($item_xpath/*[local-name()='version'])" "$appcast" 2>/dev/null || true)
  signature=$(xmllint --xpath \
    "string($enclosure_xpath/@*[local-name()='edSignature'])" "$appcast" 2>/dev/null || true)
  declared_length=$(xmllint --xpath \
    "string($enclosure_xpath/@length)" "$appcast" 2>/dev/null || true)
  actual_length=$(stat -f '%z' "$asset")

  if [ "$item_count" != 1 ] || [ "$actual_url" != "$expected_url" ] \
      || [ "$actual_version" != "$expected_version" ] \
      || [ "$actual_build" != "$expected_build" ]; then
    echo "!! appcast does not describe exactly $expected_version ($expected_build) at:" >&2
    echo "   $expected_url" >&2
    return 1
  fi
  if [ -z "$signature" ] || [ "$declared_length" != "$actual_length" ]; then
    echo "!! appcast enclosure signature or byte length is missing/incorrect" >&2
    return 1
  fi
  if ! "$SPARKLE_SIGN_UPDATE" --verify "$asset" "$signature" >/dev/null; then
    echo "!! the appcast signature does not verify this exact DMG" >&2
    return 1
  fi
  if ! "$SPARKLE_SIGN_UPDATE" --verify "$appcast" >/dev/null; then
    echo "!! the appcast feed signature is invalid" >&2
    return 1
  fi
  echo "    signed appcast and exact DMG verified"
}
