#!/usr/bin/env python3
"""Loads the fixture pages (Packages/DocmostKit/Tests/DocmostKitTests/Fixtures/fixture-*.json) into the
"Demo" space of the dev instance. The same files serve as input for the parser tests.

    Tools/seed-fixtures.py            # creates the root node "Fixtures" if it is missing
    Tools/seed-fixtures.py --reset    # deletes the root node first (including subpages)

Placeholders in the JSON files: {{USER_ID}}, {{USER_NAME}}, {{PAGE_ID}}, {{PAGE_SLUGID}}, {{PAGE_SLUG}},
{{PAGE_TITLE}} (page "Handbuch"), {{SELF_ID}} (the fixture page itself), {{IMAGE_*}} and {{FILE_*}}
(uploaded files). The login token is cached in Tools/.cache (server limit: 10 logins/min).
"""
import json
import mimetypes
import os
import struct
import sys
import urllib.request
import uuid
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASE = os.environ.get("DOCMOST_SEED_URL", "http://localhost:3000")
CACHE = ROOT / "Tools/.cache/seed-token.txt"
FIXTURES = ROOT / "Packages/DocmostKit/Tests/DocmostKitTests/Fixtures"
ROOT_TITLE = "Fixtures"


def env_credentials():
    env = {}
    for line in (ROOT / ".env").read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip()
    return env["DEV_ADMIN_EMAIL"], env["DEV_ADMIN_PASSWORD"]


class Api:
    def __init__(self):
        self.token = None

    def request(self, path, body=None, raw=None, headers=None, auth=True):
        data = raw if raw is not None else json.dumps(body if body is not None else {}).encode()
        req = urllib.request.Request(f"{BASE}/api/{path}", data=data, method="POST")
        req.add_header("Content-Type", "application/json" if raw is None else headers["Content-Type"])
        if auth and self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(req) as resp:
                return json.loads(resp.read() or b"{}"), resp
        except urllib.error.HTTPError as error:
            payload = error.read().decode(errors="replace")
            raise SystemExit(f"{path} → HTTP {error.code}: {payload}")

    def post(self, path, body=None):
        return self.request(path, body)[0].get("data")

    def login(self):
        CACHE.parent.mkdir(parents=True, exist_ok=True)
        if CACHE.exists():
            self.token = CACHE.read_text().strip()
            try:
                self.post("users/me")
                return
            except SystemExit:
                self.token = None
        email, password = env_credentials()
        req = urllib.request.Request(f"{BASE}/api/auth/login", data=json.dumps({"email": email, "password": password}).encode(), method="POST")
        req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req) as resp:
            cookies = resp.headers.get_all("Set-Cookie") or []
        for cookie in cookies:
            if cookie.startswith("authToken="):
                self.token = cookie.split(";", 1)[0].split("=", 1)[1]
        if not self.token:
            raise SystemExit("Login failed")
        CACHE.write_text(self.token)

    def upload(self, page_id, filename, data, mime):
        boundary = f"----docmost{uuid.uuid4().hex}"
        parts = [
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"pageId\"\r\n\r\n{page_id}\r\n".encode(),
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{filename}\"\r\nContent-Type: {mime}\r\n\r\n".encode(),
            data,
            f"\r\n--{boundary}--\r\n".encode(),
        ]
        payload, _ = self.request("files/upload", raw=b"".join(parts), headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
        return payload


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
    api = Api()
    api.login()
    me = api.post("users/me")["user"]

    try:
        space = api.post("spaces/info", {"spaceId": "demo"})
    except SystemExit:
        raise SystemExit("Space \"Demo\" missing; run Tools/seed-dev.sh first.")

    root_pages = api.post("pages/sidebar-pages", {"spaceId": space["id"], "limit": 100})["items"]
    existing = next((p for p in root_pages if p["title"] == ROOT_TITLE), None)
    if existing and reset:
        api.post("pages/delete", {"pageId": existing["id"], "permanentlyDelete": True})
        print("Old fixtures deleted.")
        existing = None
    if existing:
        print("Fixtures already exist. Use --reset to recreate them.")
        return

    target = next((p for p in root_pages if p["title"] == "Handbuch"), root_pages[0])
    target_page = api.post("pages/info", {"pageId": target["id"]})
    root = api.post("pages/create", {"spaceId": space["id"], "title": ROOT_TITLE, "icon": "🧪",
                                     "content": "Seiten mit allen Node-Typen für die iOS-App. Angelegt von Tools/seed-fixtures.py.",
                                     "format": "markdown"})
    print(f"Root page \"{ROOT_TITLE}\" created ({root['id']}).")

    for path in sorted(FIXTURES.glob("fixture-*.json")):
        text = path.read_text()
        spec = json.loads(text)
        page = api.post("pages/create", {"spaceId": space["id"], "parentPageId": root["id"], "title": spec["title"], "icon": spec.get("icon")})
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
        api.post("pages/update", {"pageId": page["id"], "content": content, "operation": "replace", "format": "json"})
        print(f"  {spec['title']} → {page['slugId']}")

    # Long page for performance tests.
    blocks = []
    for index in range(1000):
        blocks.append({"type": "paragraph", "content": [{"type": "text", "text": f"Paragraph {index + 1} of a very long page. "},
                                                          {"type": "text", "text": "Bold tail.", "marks": [{"type": "bold"}]}]})
        if index % 50 == 49:
            blocks.append({"type": "heading", "attrs": {"level": 2}, "content": [{"type": "text", "text": f"Section {index // 50 + 1}"}]})
    api.post("pages/create", {"spaceId": space["id"], "parentPageId": root["id"], "title": "Fixture: Long page", "icon": "📜",
                              "content": {"type": "doc", "content": blocks}, "format": "json"})
    print("  Fixture: Long page (1000+ blocks)")
    print("Done.")


if __name__ == "__main__":
    main()
