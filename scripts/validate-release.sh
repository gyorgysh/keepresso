#!/usr/bin/env bash
#
# Fail-closed release metadata and exported bundle validation.
#
# Usage:
#   ./scripts/validate-release.sh v1.17.0
#   ./scripts/validate-release.sh v1.17.0 build/export/Keepresso.app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

equal() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  [ "$actual" = "$expected" ] || die "$label is '$actual', expected '$expected'"
}

plist_value() {
  local file="$1"
  local key="$2"
  /usr/bin/plutil -extract "$key" raw -o - "$file" 2>/dev/null \
    || die "$file has no $key"
}

project_values() {
  local key="$1"
  awk -v wanted="$key:" '
    $1 == wanted {
      value = $2
      sub(/^"/, "", value)
      sub(/"$/, "", value)
      print value
    }
  ' project.yml
}

project_values_equal() {
  local key="$1"
  local expected_count="$2"
  local expected_value="$3"
  local values
  local count
  local value
  values="$(project_values "$key")"
  count="$(printf '%s\n' "$values" | awk 'NF { count += 1 } END { print count + 0 }')"
  equal "project.yml $key count" "$count" "$expected_count"
  while IFS= read -r value; do
    [ -n "$value" ] || continue
    equal "project.yml $key" "$value" "$expected_value"
  done <<< "$values"
}

TAG="${1:-${GITHUB_REF_NAME:-}}"
APP_PATH="${2:-}"

[ -n "$TAG" ] || die "pass a release tag such as v1.17.0"
if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  die "release tag '$TAG' must match v<major>.<minor>.<patch>"
fi
VERSION="${TAG#v}"

APP_INFO="Sources/Keepresso/Info.plist"
WIDGET_INFO="Sources/KeepressoWidget/Info.plist"
APP_VERSION="$(plist_value "$APP_INFO" CFBundleShortVersionString)"
APP_BUILD="$(plist_value "$APP_INFO" CFBundleVersion)"
WIDGET_VERSION="$(plist_value "$WIDGET_INFO" CFBundleShortVersionString)"
WIDGET_BUILD="$(plist_value "$WIDGET_INFO" CFBundleVersion)"

equal "App marketing version" "$APP_VERSION" "$VERSION"
[[ "$APP_BUILD" =~ ^[1-9][0-9]*$ ]] || die "App build '$APP_BUILD' must be a positive integer"
equal "Widget marketing version" "$WIDGET_VERSION" "$APP_VERSION"
equal "Widget build" "$WIDGET_BUILD" "$APP_BUILD"

project_values_equal CFBundleShortVersionString 2 "$APP_VERSION"
project_values_equal CFBundleVersion 2 "$APP_BUILD"
project_values_equal MARKETING_VERSION 2 "$APP_VERSION"
project_values_equal CURRENT_PROJECT_VERSION 2 "$APP_BUILD"

HEADER_PREFIX="## [$VERSION] - "
HEADER_COUNT="$(awk -v prefix="$HEADER_PREFIX" '
  index($0, prefix) == 1 { count += 1 }
  END { print count + 0 }
' CHANGELOG.md)"
equal "CHANGELOG.md release section count" "$HEADER_COUNT" "1"

RELEASE_HEADER="$(awk -v prefix="$HEADER_PREFIX" '
  index($0, prefix) == 1 { print; exit }
' CHANGELOG.md)"
RELEASE_DATE="${RELEASE_HEADER#"$HEADER_PREFIX"}"
if [[ ! "$RELEASE_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  die "CHANGELOG.md [$VERSION] date '$RELEASE_DATE' must use YYYY-MM-DD"
fi

RELEASE_NOTES="$(awk -v prefix="$HEADER_PREFIX" '
  index($0, prefix) == 1 { capture = 1; next }
  capture && /^## / { exit }
  capture { print }
' CHANGELOG.md)"
grep -q '^- ' <<< "$RELEASE_NOTES" \
  || die "CHANGELOG.md [$VERSION] section must contain release notes"

if awk '
  /^## Unreleased$/ { capture = 1; next }
  capture && /^## / { exit }
  capture && NF { found = 1 }
  END { exit(found ? 0 : 1) }
' CHANGELOG.md; then
  die "CHANGELOG.md Unreleased section must be empty when a release is tagged"
fi

if [ -n "$APP_PATH" ]; then
  [ -d "$APP_PATH" ] || die "exported app not found at $APP_PATH"
  BUILT_APP_INFO="$APP_PATH/Contents/Info.plist"
  BUILT_WIDGET_INFO="$APP_PATH/Contents/PlugIns/KeepressoWidget.appex/Contents/Info.plist"
  equal "Exported App marketing version" \
    "$(plist_value "$BUILT_APP_INFO" CFBundleShortVersionString)" "$APP_VERSION"
  equal "Exported App build" \
    "$(plist_value "$BUILT_APP_INFO" CFBundleVersion)" "$APP_BUILD"
  equal "Exported Widget marketing version" \
    "$(plist_value "$BUILT_WIDGET_INFO" CFBundleShortVersionString)" "$APP_VERSION"
  equal "Exported Widget build" \
    "$(plist_value "$BUILT_WIDGET_INFO" CFBundleVersion)" "$APP_BUILD"

  for executable in \
    "$APP_PATH/Contents/Helpers/keepresso" \
    "$APP_PATH/Contents/Helpers/keepresso-mcp" \
    "$APP_PATH/Contents/MacOS/keepresso-helper"; do
    [ -x "$executable" ] || die "required executable is missing: $executable"
  done
  for resource in \
    "$APP_PATH/Contents/Resources/keepresso-power/SKILL.md" \
    "$APP_PATH/Contents/Resources/keepresso-power/agents/openai.yaml" \
    "$APP_PATH/Contents/Library/LaunchDaemons/sh.gyorgy.keepresso.helper.plist"; do
    [ -f "$resource" ] || die "required resource is missing: $resource"
  done
fi

printf 'Release metadata valid: %s, build %s\n' "$TAG" "$APP_BUILD"
