#!/usr/bin/env python3
"""Validate one overlay language against the catalogs.

Usage: python3 tools/localization/check_extra.py <lang>   (e.g. it, pt-BR)

Checks that the overlay files (extra/<stem>_app.py, extra/<stem>_core.py)
cover exactly the catalog key sets, that every format specifier survives
translation, and that no em dash crept into the copy (project style rule).
Exits nonzero on any finding, so it can gate gen_strings.py runs.
"""
import importlib
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "extra"))

from catalog_app import APP
from catalog_core import CORE
from catalog_widget import WIDGET

# %@ / %d / %02d / %% and positional forms like %1$@.
FMT = re.compile(r"%(?:\d+\$)?(?:0\d)?[@d]|%%")


def specs(s: str) -> list:
    """Specifiers in s, with positional prefixes normalized away, so a
    translation may reorder via %1$@/%2$@ without tripping the check."""
    return sorted(re.sub(r"^%\d+\$", "%", m) for m in FMT.findall(s))


def check(name: str, src: dict, out: dict) -> bool:
    ok = True
    missing = [k for k in src if k not in out]
    unknown = [k for k in out if k not in src]
    for label, keys in (("missing", missing), ("unknown", unknown)):
        if keys:
            ok = False
            print(f"{name}: {len(keys)} {label} key(s):")
            for k in keys[:10]:
                print(f"  {k!r}")
    for k, v in out.items():
        if k not in src:
            continue
        if specs(k) != specs(v):
            ok = False
            print(f"{name}: format specifiers differ:\n  {k!r}\n  {v!r}")
        if "—" in v:
            ok = False
            print(f"{name}: em dash in translation of {k!r}")
        if not v.strip():
            ok = False
            print(f"{name}: empty translation for {k!r}")
    return ok


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    stem = sys.argv[1].replace("-", "_")
    app = importlib.import_module(f"{stem}_app")
    core = importlib.import_module(f"{stem}_core")
    results = [
        check("APP", APP, app.APP),
        check("CORE", CORE, core.CORE),
        check("WIDGET", WIDGET, core.WIDGET),
    ]
    counts = f"APP {len(app.APP)}/{len(APP)}, CORE {len(core.CORE)}/{len(CORE)}, WIDGET {len(core.WIDGET)}/{len(WIDGET)}"
    if all(results):
        print(f"{sys.argv[1]}: OK ({counts})")
        return 0
    print(f"{sys.argv[1]}: FAILED ({counts})")
    return 1


if __name__ == "__main__":
    sys.exit(main())
