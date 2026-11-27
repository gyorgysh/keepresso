#!/usr/bin/env bash
# The window carries the background in tools/dmg, with the app and an
# Applications shortcut fixed where its arrow points, and the app icon on the
# volume. dmgbuild writes that layout straight into the image's .DS_Store, so
# it works on a headless runner where scripting Finder does not. It installs
# into .build/ from the pinned, hashed requirements on first use, and needs
# Python 3.10 or newer (the system python3 is older; brew install python).
set -euo pipefail

APP="${1:?usage: package-dmg.sh <app-bundle> <output.dmg> [volume-name]}"
DMG="${2:?usage: package-dmg.sh <app-bundle> <output.dmg> [volume-name]}"
VOLUME="${3:-Keepresso}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DMG_DIR="$ROOT_DIR/tools/dmg"

die() { printf '\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }

[ -d "$APP" ] || die "no app bundle at $APP"
VOLUME_ICON="$APP/Contents/Resources/AppIcon.icns"
[ -f "$VOLUME_ICON" ] || die "no AppIcon.icns in $APP"

find_python() {
  local candidate
  for candidate in "$(command -v python3 || true)" /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# Rebuilt when the pins change or its interpreter has gone (a Python upgrade
# removes the one the venv links to), not just when it is missing.
VENV="$ROOT_DIR/.build/dmgbuild-venv"
if ! cmp -s "$DMG_DIR/requirements.txt" "$VENV/requirements.txt" \
  || ! "$VENV/bin/python" -c 'import dmgbuild' 2>/dev/null; then
  PYTHON="$(find_python)" || die "dmgbuild needs Python 3.10 or newer (brew install python)"
  rm -rf "$VENV"
  "$PYTHON" -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --disable-pip-version-check \
    --require-hashes --only-binary :all: -r "$DMG_DIR/requirements.txt"
  cp "$DMG_DIR/requirements.txt" "$VENV/requirements.txt"
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# ditto, not cp -R: it preserves the extended attributes a signed bundle
# carries, so the copy still passes codesign --verify.
ditto "$APP" "$STAGE/$(basename "$APP")"

# One TIFF holding both resolutions, so Finder picks the sharp one on Retina.
tiffutil -cathidpicheck "$DMG_DIR/background.png" "$DMG_DIR/background@2x.png" \
  -out "$STAGE/background.tiff" > /dev/null 2>&1 || die "tiffutil could not build the background"

rm -f "$DMG"
set +e
"$VENV/bin/dmgbuild" \
  -s "$DMG_DIR/dmg-settings.py" \
  -D app="$STAGE/$(basename "$APP")" \
  -D background="$STAGE/background.tiff" \
  -D volume_icon="$VOLUME_ICON" \
  "$VOLUME" "$DMG" 2>&1 | grep -v "is deprecated"
status="${PIPESTATUS[0]}"
set -e
if [ "$status" -ne 0 ] || [ ! -f "$DMG" ]; then
  die "dmgbuild failed to write $DMG"
fi

echo "Wrote $DMG"
