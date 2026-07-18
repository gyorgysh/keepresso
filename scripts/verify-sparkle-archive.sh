#!/usr/bin/env bash
# Verify the pinned Sparkle release archive before any bundled tool is used.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sparkle-release-config.sh
source "$SCRIPT_DIR/sparkle-release-config.sh"

ARCHIVE="${1:-}"
[ -n "$ARCHIVE" ] || { echo "Usage: $0 <Sparkle archive>" >&2; exit 2; }
[ -f "$ARCHIVE" ] || { echo "Error: Sparkle archive not found: $ARCHIVE" >&2; exit 1; }

ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$SPARKLE_ARCHIVE_SHA256" ]; then
  echo "Error: Sparkle archive SHA-256 mismatch" >&2
  exit 1
fi

printf 'Sparkle %s archive SHA-256 verified\n' "$SPARKLE_VERSION"
