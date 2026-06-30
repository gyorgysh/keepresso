#!/usr/bin/env bash
#
# run.sh — one-shot dev launcher for Keepresso.
#
# Ensures XcodeGen is installed (via Homebrew), regenerates the Xcode project
# from project.yml, and opens it in Xcode ready to ⌘R.
#
#   ./scripts/run.sh            # generate + open Xcode
#   ./scripts/run.sh --build    # also build from the CLI before opening
#   ./scripts/run.sh --no-open  # generate (and optionally build) only
#
set -euo pipefail

# Resolve the repo root regardless of where the script is called from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

PROJECT="Keepresso.xcodeproj"
SCHEME="Keepresso"
DO_BUILD=false
DO_OPEN=true

for arg in "$@"; do
  case "$arg" in
    --build)   DO_BUILD=true ;;
    --no-open) DO_OPEN=false ;;
    -h|--help)
      grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "Unknown option: $arg (try --help)" >&2
      exit 2 ;;
  esac
done

info()  { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
warn()  { printf '\033[1;33m==>\033[0m %s\n' "$1" >&2; }
die()   { printf '\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }

# --- Preconditions -----------------------------------------------------------

# A full Xcode (not just Command Line Tools) is required to build/open the app.
if ! xcodebuild -version >/dev/null 2>&1; then
  die "Full Xcode is required (Command Line Tools alone can't build the app).
       Install Xcode from the App Store, then:
         sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
         sudo xcodebuild -license accept"
fi

# --- Ensure XcodeGen ---------------------------------------------------------

if ! command -v xcodegen >/dev/null 2>&1; then
  warn "XcodeGen not found."
  if command -v brew >/dev/null 2>&1; then
    info "Installing XcodeGen via Homebrew..."
    brew install xcodegen
  else
    die "Homebrew not found. Install it from https://brew.sh and re-run, or
         install XcodeGen manually: https://github.com/yonaskolb/XcodeGen"
  fi
fi

# --- Generate ----------------------------------------------------------------

info "Generating $PROJECT from project.yml..."
xcodegen generate

# --- Optional CLI build ------------------------------------------------------

if [ "$DO_BUILD" = true ]; then
  info "Building $SCHEME..."
  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO
fi

# --- Open --------------------------------------------------------------------

if [ "$DO_OPEN" = true ]; then
  info "Opening $PROJECT in Xcode (press ⌘R to run)..."
  open "$PROJECT"
else
  info "Done. Project generated at $PROJECT."
fi
