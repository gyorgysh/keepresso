#!/usr/bin/env bash
#
# appcast-notes.sh — embed the changelog in a release's appcast.
#
# 1. Extracts this version's section from CHANGELOG.md into
#    build/RELEASE_NOTES.md, which becomes the GitHub release body.
# 2. Renders that section to HTML (GitHub's markdown API) and embeds it as
#    the appcast item's <description>, which Sparkle displays directly in
#    the update dialog. A link to the GitHub release page is appended.
#
# A releaseNotesLink is deliberately not used: Sparkle would load the full
# GitHub release page, header and navigation included, into the dialog.
#
# Run after generate_appcast has written dist/appcast.xml. Requires gh.
#
# Usage: appcast-notes.sh <version> [owner/repo] [tag]
# Env: APPCAST overrides the appcast path (default dist/appcast.xml).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

VERSION="${1:?usage: appcast-notes.sh <version> [owner/repo] [tag]}"
REPO="${2:-gyorgysh/keepresso}"
TAG="${3:-v$VERSION}"
APPCAST="${APPCAST:-dist/appcast.xml}"
RELEASE_URL="https://github.com/$REPO/releases/tag/$TAG"

mkdir -p build
awk -v ver="$VERSION" '
  $0 ~ "^## \\[" ver "\\]" {grab=1; next}
  grab && /^## \[/ {exit}
  grab {print}
' CHANGELOG.md > build/RELEASE_NOTES.md

if ! grep -q '[^[:space:]]' build/RELEASE_NOTES.md; then
  echo "Warning: CHANGELOG.md has no [$VERSION] section, the notes will only carry a link" >&2
fi

[ -f "$APPCAST" ] || { echo "Error: $APPCAST not found, run generate_appcast first" >&2; exit 1; }

# Unwrap soft-wrapped continuation lines for the HTML description only. GitHub's
# GFM renderer turns every newline inside a bullet into a <br>, so the hard
# wrapping in CHANGELOG.md would break sentences mid-line in the Sparkle dialog.
# Joining each bullet/paragraph onto one physical line avoids that while keeping
# blank lines and list markers as boundaries (and #/@ autolinks intact). The
# GitHub release body (build/RELEASE_NOTES.md) keeps its original wrapping.
python3 - build/RELEASE_NOTES.md > build/RELEASE_NOTES.unwrapped.md <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split("\n")
out, cur = [], None
def flush():
    global cur
    if cur is not None:
        out.append(cur); cur = None
for ln in lines:
    if ln.strip() == "":
        flush(); out.append(""); continue
    if re.match(r"^\s*([-*+]|\d+\.)\s", ln) or re.match(r"^#{1,6}\s", ln):
        flush(); cur = ln.rstrip()
    elif cur is None:
        cur = ln.rstrip()
    else:
        cur = cur + " " + ln.strip()
flush()
sys.stdout.write("\n".join(out))
PY

{
  printf '<style>body { font: 13px -apple-system, sans-serif; margin: 12px; } :root { color-scheme: light dark; } h3 { font-size: 14px; }</style>\n'
  gh api /markdown -f mode=gfm -f context="$REPO" -F "text=@build/RELEASE_NOTES.unwrapped.md"
  printf '\n<p><a href="%s">Full release notes on GitHub</a></p>\n' "$RELEASE_URL"
} > build/RELEASE_NOTES.html

python3 - "$APPCAST" build/RELEASE_NOTES.html <<'PY'
import re, sys, pathlib

path = pathlib.Path(sys.argv[1])
html = pathlib.Path(sys.argv[2]).read_text()
xml = path.read_text()

# Drop notes elements from any earlier run so this stays idempotent. The
# appcast holds a single item in this setup.
xml = re.sub(r"[ \t]*<sparkle:releaseNotesLink>.*?</sparkle:releaseNotesLink>\n", "", xml, flags=re.S)
xml = re.sub(r"[ \t]*<description><!\[CDATA\[.*?\]\]></description>\n", "", xml, flags=re.S)

if "<enclosure" not in xml:
    sys.exit("Error: no <enclosure> in appcast")
head, tail = xml.split("<enclosure", 1)
indent = head[head.rfind("\n") + 1:]
cdata = html.replace("]]>", "]]]]><![CDATA[>")
desc = f"<description><![CDATA[{cdata}]]></description>"
path.write_text(head + desc + "\n" + indent + "<enclosure" + tail)
PY

echo "Wrote build/RELEASE_NOTES.md and embedded the notes in $APPCAST"
