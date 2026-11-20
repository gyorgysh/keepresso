#!/usr/bin/env bash
#
# render-dmg-background.sh: render the disk image background at 1x and 2x.
#
#   ./scripts/render-dmg-background.sh
#
# Run it after editing tools/dmg/background.html and commit both PNGs. They are
# committed rather than rendered at release time so the release runner needs no
# browser, and so the image people download is the one that was reviewed.
#
# Needs Google Chrome. The page uses the system font, so no font files.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DMG_DIR="$ROOT_DIR/tools/dmg"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

die() { printf '\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }

[ -x "$CHROME" ] || die "Google Chrome not found at $CHROME (set CHROME to override)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$DMG_DIR/background.html" "$WORK/"

render() {
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
    --window-size=660,400 --force-device-scale-factor="$1" \
    --screenshot="$2" "file://$WORK/background.html" 2>/dev/null
}

render 1 "$DMG_DIR/background.png"
render 2 "$DMG_DIR/background@2x.png"

echo "Wrote tools/dmg/background.png and background@2x.png"
