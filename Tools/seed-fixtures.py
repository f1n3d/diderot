#!/usr/bin/env python3
"""Loads the fixture pages (Packages/DocmostKit/Tests/DocmostKitTests/Fixtures/fixture-*.json) into the
"Demo" space of the dev instance. The same files serve as input for the parser tests.

    Tools/seed-fixtures.py            # creates the root node "Fixtures" if it is missing
    Tools/seed-fixtures.py --reset    # deletes the root node first (including subpages)

Fixtures named `fixture-docmost-097*.json` hold content Docmost 0.97 introduced (tabs, integration links) and are
left out on older servers, which would drop it; they get three child pages (Banana, apple, Cherry) for sorting.

    DOCMOST_SEED_URL=http://localhost:3001 Tools/seed-fixtures.py --reset    # the 0.97 dev instance

Placeholders in the JSON files: {{USER_ID}}, {{USER_NAME}}, {{PAGE_ID}}, {{PAGE_SLUGID}}, {{PAGE_SLUG}},
{{PAGE_TITLE}} (page "Handbuch"), {{SELF_ID}} (the fixture page itself), {{IMAGE_*}} and {{FILE_*}}
(uploaded files). Signs in as the admin from .env through Tools/dev_api.py, which caches the token (server limit:
10 sign-ins/min).
"""
import json
import struct
import sys
import zlib
from pathlib import Path

import dev_api

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "Packages/DocmostKit/Tests/DocmostKitTests/Fixtures"
ROOT_TITLE = "Fixtures"


def gradient_png(width=600, height=400):
    """Small test PNG (RGB gradient) without external dependencies."""
    rows = []
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            row += bytes((int(255 * x / width), int(255 * y / height), 160))
        rows.append(bytes(row))
    def chunk(tag, body):
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b"")


def main():
    reset = "--reset" in sys.argv
    api = dev_api.session(*dev_api.admin())
    me = api.call("users/me")["user"]

    try:
        space = api.call("spaces/info", {"spaceId": "demo"})
    except dev_api.ApiError:
        sys.exit("Space \"Demo\" missing; run Tools/seed-dev.sh first.")

    root_pages = api.call("pages/sidebar-pages", {"spaceId": space["id"], "limit": 100})["items"]
    existing = next((p for p in root_pages if p["title"] == ROOT_TITLE), None)
    if existing and reset:
        api.call("pages/delete", {"pageId": existing["id"], "permanentlyDelete": True})
        print("Old fixtures deleted.")
        existing = None
    if existing:
        print("Fixtures already exist. Use --reset to recreate them.")
        return

    version = api.call("version").get("currentVersion") or "0.0"
    docmost_097 = tuple(int(part) for part in version.lstrip("v").split(".")[:2]) >= (0, 97)

    target = next((p for p in root_pages if p["title"] == "Handbuch"), root_pages[0])
    target_page = api.call("pages/info", {"pageId": target["id"]})
    root = api.call("pages/create", {"spaceId": space["id"], "title": ROOT_TITLE, "icon": "🧪",
                                     "content": "Seiten mit allen Node-Typen für die iOS-App. Angelegt von Tools/seed-fixtures.py.",
                                     "format": "markdown"})
    print(f"Root page \"{ROOT_TITLE}\" created ({root['id']}).")

    for path in sorted(FIXTURES.glob("fixture-*.json")):
        if path.name.startswith("fixture-docmost-097") and not docmost_097:
            print(f"  {path.name} left out: Docmost {version} is older than 0.97")
            continue
        text = path.read_text()
        spec = json.loads(text)
        page = api.call("pages/create", {"spaceId": space["id"], "parentPageId": root["id"], "title": spec["title"], "icon": spec.get("icon")})
        values = {
            "USER_ID": me["id"], "USER_NAME": me["name"] or me["email"],
            "PAGE_ID": target_page["id"], "PAGE_SLUGID": target_page["slugId"], "PAGE_TITLE": target_page["title"],
            "PAGE_SLUG": f"{target_page['title'].lower().replace(' ', '-')}-{target_page['slugId']}",
            "SELF_ID": page["id"],
        }
        if "{{IMAGE_SRC}}" in text:
            image = api.upload(page["id"], "gradient.png", gradient_png(), "image/png")
            text_file = api.upload(page["id"], "notes.txt", b"Fixture attachment from seed-fixtures.py\n", "text/plain")
            values.update({
                "IMAGE_SRC": f"/api/files/{image['id']}/{image['fileName']}", "IMAGE_ID": image["id"], "IMAGE_SIZE": str(image["fileSize"]),
                "FILE_URL": f"/api/files/{text_file['id']}/{text_file['fileName']}", "FILE_ID": text_file["id"], "FILE_SIZE": str(text_file["fileSize"]),
            })
        for key, value in values.items():
            if key.endswith("_SIZE"):
                # Numbers appear as quoted placeholders in the fixture so the file stays valid JSON.
                text = text.replace('"{{' + key + '}}"', value)
            else:
                text = text.replace("{{" + key + "}}", json.dumps(value)[1:-1])
        content = json.loads(text)["content"]
        api.call("pages/update", {"pageId": page["id"], "content": content, "operation": "replace", "format": "json"})
        print(f"  {spec['title']} → {page['slugId']}")
        if path.name.startswith("fixture-docmost-097"):
            # Out of alphabetical order, so the sub-pages block's A–Z shows: apple, Banana, Cherry.
            for title in ("Banana", "apple", "Cherry"):
                api.call("pages/create", {"spaceId": space["id"], "parentPageId": page["id"], "title": title})

    # Long page for performance tests.
    blocks = []
    for index in range(1000):
        blocks.append({"type": "paragraph", "content": [{"type": "text", "text": f"Paragraph {index + 1} of a very long page. "},
                                                          {"type": "text", "text": "Bold tail.", "marks": [{"type": "bold"}]}]})
        if index % 50 == 49:
            blocks.append({"type": "heading", "attrs": {"level": 2}, "content": [{"type": "text", "text": f"Section {index // 50 + 1}"}]})
    api.call("pages/create", {"spaceId": space["id"], "parentPageId": root["id"], "title": "Fixture: Long page", "icon": "📜",
                              "content": {"type": "doc", "content": blocks}, "format": "json"})
    print("  Fixture: Long page (1000+ blocks)")
    print("Done.")


if __name__ == "__main__":
    dev_api.run(main)
