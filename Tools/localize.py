#!/usr/bin/env python3
"""Maintains German translations in the String Catalog.

    Tools/localize.py --import <export>/de.xcloc/Localized\\ Contents/de.xliff   # add new keys from an export
    Tools/localize.py --apply translations.json                                    # apply {"Key": "Translation", …}
    Tools/localize.py --missing                                                    # list keys without a German translation
                                                                                   # (exits 1 if any; mark keys that need none, such as
                                                                                   # numbers or URLs, "Don't Translate" in Xcode)

Create an export: xcodebuild -exportLocalizations -project Diderot.xcodeproj -localizationPath <dir> -exportLanguage de
"""
import argparse
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Diderot/Resources/Localizable.xcstrings"
NS = {"x": "urn:oasis:names:tc:xliff:document:1.2"}


def load():
    return json.loads(CATALOG.read_text())


def save(catalog):
    CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


def german(entry):
    de = entry.get("localizations", {}).get("de", {})
    if "variations" in de:  # e.g. singular/plural
        return de["variations"]
    return de.get("stringUnit", {}).get("value")


def import_keys(catalog, xliff_path):
    """Adds the source texts of this catalog's section in an XLIFF export as keys (without translation)."""
    tree = ET.parse(xliff_path)
    added = 0
    # The export holds one <file> section per catalog; InfoPlist.xcstrings keys must not land in this one.
    for unit in tree.getroot().iterfind(f"x:file[@original='{CATALOG.relative_to(ROOT)}']//x:trans-unit", NS):
        source = unit.find("x:source", NS)
        if source is None or not source.text:
            continue
        key = unit.get("id") or source.text
        if "|==|" in key:  # singular/plural variant of an existing key, not a key of its own
            continue
        if key not in catalog["strings"]:
            catalog["strings"][key] = {}
            added += 1
    return added


def apply(catalog, translations):
    applied, unknown = 0, []
    for key, value in translations.items():
        entry = catalog["strings"].get(key)
        if entry is None:
            unknown.append(key)
            continue
        entry.setdefault("localizations", {})["de"] = {"stringUnit": {"state": "translated", "value": value}}
        applied += 1
    return applied, unknown


def missing(catalog):
    return sorted(k for k, v in catalog["strings"].items() if not german(v) and not v.get("shouldTranslate") is False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--import", dest="xliff")
    parser.add_argument("--apply")
    parser.add_argument("--missing", action="store_true")
    args = parser.parse_args()
    catalog = load()
    if args.xliff:
        print(f"{import_keys(catalog, args.xliff)} new keys added")
        save(catalog)
    if args.apply:
        applied, unknown = apply(catalog, json.loads(Path(args.apply).read_text()))
        print(f"{applied} translations applied")
        if unknown:
            print("Unknown keys (not in the catalog):", *unknown, sep="\n  ")
        save(catalog)
    if args.missing or not (args.xliff or args.apply):
        keys = missing(catalog)
        print(f"{len(keys)} keys without a German translation")
        for key in keys:
            print("  " + repr(key))
        return 1 if keys else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
