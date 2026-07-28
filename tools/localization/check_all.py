#!/usr/bin/env python3
"""Gate a release on complete, in-sync localization.

Usage: python3 tools/localization/check_all.py

``check_extra.py`` validates one overlay language against the catalogs. This
checks every language the app ships, including the five whose translations sit
inline in the catalogs (hu, es, fr, de, zh-Hans) and so were never covered.
That gap matters because ``gen_strings.emit`` falls back to the English key for
a missing translation: an untranslated string ships silently as English rather
than failing anything.

For every shipping language it checks that:
  - every catalog key has a translation, and none is empty
  - format specifiers survive translation (a dropped %@ crashes at runtime)
  - no em dash crept into the copy (project style rule)

Then it checks that the committed ``.strings`` are exactly what the catalogs
generate, which catches a hand-edited file and a catalog change that was never
regenerated. Nothing is written, so this is safe to run in CI.

Exits nonzero on any finding, with every finding listed rather than just the
first, so one run tells you the whole story.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "extra"))

from check_extra import specs
from gen_strings import (
    APP,
    APP_DIR,
    CORE,
    CORE_DIR,
    LANGS,
    WIDGET,
    WIDGET_DIR,
    merge_extra_langs,
    render_table,
    table_for,
)

CATALOGS = [("APP", APP, APP_DIR), ("CORE", CORE, CORE_DIR), ("WIDGET", WIDGET, WIDGET_DIR)]


def check_translations(problems: list):
    """Every language has a real translation for every key."""
    for name, catalog, _ in CATALOGS:
        for lang in LANGS:
            for key, translations in catalog.items():
                if lang not in translations:
                    problems.append(f"{name} {lang}: missing translation, ships as English: {key!r}")
                    continue
                value = translations[lang]
                if not str(value).strip():
                    problems.append(f"{name} {lang}: empty translation for {key!r}")
                    continue
                if specs(key) != specs(value):
                    problems.append(
                        f"{name} {lang}: format specifiers differ\n    {key!r}\n    {value!r}"
                    )
                if "—" in value:
                    problems.append(f"{name} {lang}: em dash in translation of {key!r}")


def check_generated_files(problems: list):
    """What is committed matches what the catalogs would emit."""
    for name, catalog, base_dir in CATALOGS:
        for lang in ["en"] + LANGS:
            path = os.path.join(base_dir, f"{lang}.lproj", "Localizable.strings")
            expected = render_table(table_for(catalog, lang))
            if not os.path.exists(path):
                problems.append(f"{name} {lang}: {path} is missing, run gen_strings.py")
                continue
            with open(path, encoding="utf-8") as f:
                actual = f.read()
            if actual != expected:
                problems.append(
                    f"{name} {lang}: {os.path.relpath(path)} is out of date, run gen_strings.py"
                )


def main() -> int:
    # Overlay languages live in separate files; fold them in so every language
    # is checked the same way. A malformed overlay raises here, which is the
    # same failure gen_strings.py would hit.
    merge_extra_langs()
    problems: list = []
    check_translations(problems)
    check_generated_files(problems)
    if problems:
        for problem in problems:
            print(problem)
        print(f"\nlocalization: FAILED ({len(problems)} problem(s))")
        return 1
    keys = sum(len(catalog) for _, catalog, _ in CATALOGS)
    print(f"localization: OK ({len(LANGS) + 1} languages, {keys} keys each run)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
