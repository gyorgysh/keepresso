#!/usr/bin/env bash
# Requirements:
#   - Sparkle's generate_appcast: found on PATH or at $SPARKLE_BIN, otherwise
#     fetched automatically from Sparkle's release tarball (the
#     `brew install --cask sparkle` route was deprecated and disabled in
#     September 2026).
#   - The Sparkle private key already in your Keychain (generate_keys, once).
#   - gh CLI authenticated (gh auth login).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

DIST_DIR="$ROOT_DIR/dist"
REPO="gyorgysh/keepresso"

info() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh CLI not found (brew install gh; gh auth login)"

read -r VERSION _ < <("$SCRIPT_DIR/check-versions.sh") \
  || die "project.yml version literals disagree (see above)"
[ -n "$VERSION" ] || die "Couldn't read MARKETING_VERSION from project.yml"
TAG="v$VERSION"
DMG_PATH="$DIST_DIR/Keepresso-$VERSION.dmg"
[ -f "$DMG_PATH" ] || die "Missing $DMG_PATH — run scripts/build-dmg.sh first"

GENERATE_APPCAST="${SPARKLE_BIN:-}/generate_appcast"
if [ ! -x "$GENERATE_APPCAST" ]; then
  GENERATE_APPCAST="$(command -v generate_appcast || true)"
fi
if [ ! -x "$GENERATE_APPCAST" ]; then
  SPARKLE_VERSION=2.10.1
  SPARKLE_SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
  SPARKLE_DIR="$(mktemp -d)"
  trap 'rm -rf "$SPARKLE_DIR"' EXIT
  info "Downloading Sparkle ${SPARKLE_VERSION} tools"
  curl -fsSL -o "$SPARKLE_DIR/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
  echo "$SPARKLE_SHA256  $SPARKLE_DIR/sparkle.tar.xz" | shasum -a 256 -c -
  mkdir -p "$SPARKLE_DIR/tools"
  tar -xJf "$SPARKLE_DIR/sparkle.tar.xz" -C "$SPARKLE_DIR/tools"
  GENERATE_APPCAST="$(find "$SPARKLE_DIR/tools" -path '*/bin/generate_appcast' -type f | head -1)"
fi
[ -x "$GENERATE_APPCAST" ] || die "generate_appcast not found — set SPARKLE_BIN to Sparkle's bin/ dir"

info "Signing appcast with Sparkle ($VERSION)"
"$GENERATE_APPCAST" "$DIST_DIR" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/"

APPCAST="$DIST_DIR/appcast.xml"
[ -f "$APPCAST" ] || die "generate_appcast did not produce appcast.xml"

info "Adding release notes (embedded changelog)"
"$SCRIPT_DIR/appcast-notes.sh" "$VERSION" "$REPO" "$TAG"

info "Publishing GitHub Release $TAG"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG_PATH" "$APPCAST" --repo "$REPO" --clobber
else
  gh release create "$TAG" "$DMG_PATH" "$APPCAST" \
    --repo "$REPO" \
    --title "Keepresso $VERSION" \
    --notes-file "$ROOT_DIR/build/RELEASE_NOTES.md" --generate-notes
fi

info "Done. Released $TAG with the DMG and signed appcast.xml."
