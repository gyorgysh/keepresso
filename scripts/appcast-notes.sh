#!/usr/bin/env bash
#
# appcast-notes.sh — wire the changelog into a release's update metadata.
#
# 1. Extracts this version's section from CHANGELOG.md into
#    build/RELEASE_NOTES.md, which becomes the GitHub release body.
# 2. Injects a sparkle:releaseNotesLink pointing at the GitHub release page
#    into dist/appcast.xml, so Sparkle's update dialog shows that page.
#
# Run after generate_appcast has written dist/appcast.xml.
#
# Usage: appcast-notes.sh <version> [owner/repo] [tag]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

VERSION="${1:?usage: appcast-notes.sh <version> [owner/repo] [tag]}"
REPO="${2:-gyorgysh/keepresso}"
TAG="${3:-v$VERSION}"
APPCAST="dist/appcast.xml"

mkdir -p build
awk -v ver="$VERSION" '
  $0 ~ "^## \\[" ver "\\]" {grab=1; next}
  grab && /^## \[/ {exit}
  grab {print}
' CHANGELOG.md > build/RELEASE_NOTES.md

if ! grep -q '[^[:space:]]' build/RELEASE_NOTES.md; then
  echo "Warning: CHANGELOG.md has no [$VERSION] section, the release body will only have auto-generated notes" >&2
fi

[ -f "$APPCAST" ] || { echo "Error: $APPCAST not found, run generate_appcast first" >&2; exit 1; }

export RELEASE_URL="https://github.com/$REPO/releases/tag/$TAG"
python3 - "$APPCAST" <<'PY'
import os, sys, pathlib

path = pathlib.Path(sys.argv[1])
xml = path.read_text()
link = f"<sparkle:releaseNotesLink>{os.environ['RELEASE_URL']}</sparkle:releaseNotesLink>"
if "releaseNotesLink" in xml:
    sys.exit(0)
if "<enclosure" not in xml:
    sys.exit("Error: no <enclosure> in appcast.xml")
head, tail = xml.split("<enclosure", 1)
indent = head[head.rfind("\n") + 1:]
path.write_text(head + link + "\n" + indent + "<enclosure" + tail)
PY

echo "Wrote build/RELEASE_NOTES.md and linked $RELEASE_URL in $APPCAST"
