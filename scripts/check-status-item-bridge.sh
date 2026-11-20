#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/pervigil-status-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library \
    "$repo_root/Tests/PervigilAppChecks/StatusItemBridgeChecks.swift" \
    "$repo_root/Sources/Pervigil/StatusItemBridge.swift" \
    -o "$check_dir/check"
"$check_dir/check"
