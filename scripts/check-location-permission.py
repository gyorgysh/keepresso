#!/usr/bin/env python3
"""Verify the metadata required for the macOS Location permission prompt."""
import argparse
import plistlib
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("bundle", nargs="?", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
app = root / "Sources/Pervigil"
info_path = args.bundle / "Contents/Info.plist" if args.bundle else app / "Info.plist"
info = plistlib.loads(info_path.read_bytes())
for key in ("NSLocationUsageDescription", "NSLocationWhenInUseUsageDescription"):
    if not isinstance(info.get(key), str) or not info[key].strip():
        raise SystemExit(f"Missing Location permission description: {key}")

if args.bundle:
    result = subprocess.run(
        ["codesign", "--display", "--entitlements", ":-", str(args.bundle)],
        capture_output=True, check=True,
    )
    entitlements = plistlib.loads(result.stdout)
else:
    entitlements = plistlib.loads((app / "Pervigil.entitlements").read_bytes())
if entitlements.get("com.apple.security.personal-information.location") is not True:
    raise SystemExit("Missing Hardened Runtime Location entitlement")
print("Location permission metadata: OK")
