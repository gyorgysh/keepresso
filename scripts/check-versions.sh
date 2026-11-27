#!/bin/bash
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

versions="$(awk -F'"' '/MARKETING_VERSION:|CFBundleShortVersionString:/ {print $2}' project.yml)"
[ -n "$versions" ] || { echo "error: no version literals found in project.yml" >&2; exit 1; }
distinct_versions="$(printf '%s\n' "$versions" | sort -u)"
if [ "$(printf '%s\n' "$distinct_versions" | wc -l)" -ne 1 ]; then
  echo "error: version literals disagree in project.yml:" >&2
  grep -n 'MARKETING_VERSION:\|CFBundleShortVersionString:' project.yml >&2
  exit 1
fi

builds="$(awk -F'"' '/CURRENT_PROJECT_VERSION:|CFBundleVersion:/ {print $2}' project.yml)"
[ -n "$builds" ] || { echo "error: no build literals found in project.yml" >&2; exit 1; }
distinct_builds="$(printf '%s\n' "$builds" | sort -u)"
if [ "$(printf '%s\n' "$distinct_builds" | wc -l)" -ne 1 ]; then
  echo "error: build-number literals disagree in project.yml:" >&2
  grep -n 'CURRENT_PROJECT_VERSION:\|CFBundleVersion:' project.yml >&2
  exit 1
fi

python3 - "$distinct_versions" "$distinct_builds" <<'PY'
import plistlib
import sys
from pathlib import Path

expected = dict(zip(("CFBundleShortVersionString", "CFBundleVersion"), sys.argv[1:]))
for target in ("Keepresso", "KeepressoWidget", "keepresso-helper"):
    path = Path("Sources") / target / "Info.plist"
    with path.open("rb") as source:
        info = plistlib.load(source)
    for key, value in expected.items():
        if info.get(key) != value:
            sys.exit(f"error: {path} {key} is {info.get(key)!r}; project.yml requires {value!r}")
PY

printf '%s %s\n' "$distinct_versions" "$distinct_builds"
