#!/usr/bin/env bash
#
# release.sh — sign the Sparkle appcast and publish a GitHub Release.
#
# Run scripts/build-dmg.sh first to produce dist/Keepresso-<version>.dmg, then:
#
#   ./scripts/release.sh
#
# What it does:
#   1. Runs Sparkle's generate_appcast over dist/, which EdDSA-signs the DMG
#      (using the private key in your Keychain) and writes dist/appcast.xml with
#      enclosure URLs pointing at this release's GitHub download.
#   2. Runs appcast-notes.sh, which embeds this version's CHANGELOG.md
#      section into the appcast (shown in the Sparkle update dialog) and
#      extracts it for the release body.
#   3. Creates (or updates) the GitHub Release vX.Y.Z and uploads the DMG plus
#      appcast.xml as assets.
#
# Because SUFeedURL is .../releases/latest/download/appcast.xml, the newest
# release's appcast.xml is always what running copies fetch.
#
# Requirements:
#   - Sparkle's generate_appcast: found on PATH or at $SPARKLE_BIN, otherwise
#     fetched automatically from Sparkle's release tarball (the
#     `brew install --cask sparkle` route was deprecated and disabled in
#     September 2026).
#   - The Sparkle private key already in your Keychain (generate_keys, once).
#   - gh CLI authenticated (gh auth login).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

DIST_DIR="$ROOT_DIR/dist"
REPO="gyorgysh/keepresso"   # update if the repo moves

info() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh CLI not found (brew install gh; gh auth login)"

read -r VERSION _ < <("$SCRIPT_DIR/check-versions.sh") \
  || die "project.yml version literals disagree (see above)"
[ -n "$VERSION" ] || die "Couldn't read MARKETING_VERSION from project.yml"
TAG="v$VERSION"
DMG_PATH="$DIST_DIR/Keepresso-$VERSION.dmg"
[ -f "$DMG_PATH" ] || die "Missing $DMG_PATH — run scripts/build-dmg.sh first"

# Locate generate_appcast.
GENERATE_APPCAST="${SPARKLE_BIN:-}/generate_appcast"
if [ ! -x "$GENERATE_APPCAST" ]; then
  GENERATE_APPCAST="$(command -v generate_appcast || true)"
fi
if [ ! -x "$GENERATE_APPCAST" ]; then
  # Same pinned tarball and hash as .github/workflows/release.yml.
  SPARKLE_VERSION=2.10.0
  SPARKLE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
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
# Enclosure URLs must point at THIS release's download path on GitHub.
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
