#!/bin/bash
# Fail unless every version literal in project.yml agrees: all
# MARKETING_VERSION + CFBundleShortVersionString lines must carry one
# distinct version, and all CURRENT_PROJECT_VERSION + CFBundleVersion lines
# one distinct build number. The old awk read only the first
# MARKETING_VERSION, so a drifted widget/helper literal shipped silently.
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
if [ "$(printf '%s\n' "$builds" | sort -u | wc -l)" -ne 1 ]; then
  echo "error: build-number literals disagree in project.yml:" >&2
  grep -n 'CURRENT_PROJECT_VERSION:\|CFBundleVersion:' project.yml >&2
  exit 1
fi

# Print "version build" for callers (release.sh, CI).
printf '%s %s\n' "$distinct_versions" "$(printf '%s\n' "$builds" | sort -u)"
