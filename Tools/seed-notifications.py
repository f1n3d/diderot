#!/usr/bin/env python3
"""Creates notifications for the dev admin: a second user ("Test-Kollegin") mentions them in a comment
on the test page. She is created via invitation if needed and added to the page's space; her older
comments on the page are deleted first so nothing piles up. She also replies to her last comment without
a mention, which notifies nobody (someone else's reply for EditorUITests test33, its link for test64). Dev instance only.

    Tools/seed-notifications.py <pageId>              # one comment with a mention
    Tools/seed-notifications.py <pageId> --count 3    # several (e.g. for screenshots)
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASE = os.environ.get("DOCMOST_SEED_URL", "http://localhost:3000")
# The second user gets a fixed password: only ever on a dev instance on this Mac.
if urllib.parse.urlsplit(BASE).hostname not in ("localhost", "127.0.0.1", "::1"):
    sys.exit(f"{BASE} is no local dev instance: this script creates a user with a fixed password there.")
TESTER_EMAIL = "kollegin@docmost.local"
TESTER_PASSWORD = "kollegin-dev-123"
TESTER_NAME = "Test-Kollegin"


def env_credentials():
    env = {}
    for line in (ROOT / ".env").read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip().strip('"').strip("'")
    return env["DEV_ADMIN_EMAIL"], env["DEV_ADMIN_PASSWORD"]


def call(path, body=None, token=None):
    """POST to the API; returns (data, authToken cookie or None)."""
    request = urllib.request.Request(BASE + "/api/" + path, data=json.dumps(body or {}).encode(), method="POST")
    request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(request) as response:
        payload = json.loads(response.read() or b"{}")
        cookie = None
        for header in response.headers.get_all("Set-Cookie") or []:
            match = re.match(r"authToken=([^;]+)", header)
            if match:
                cookie = match.group(1)
        return payload.get("data", payload), cookie


def login(email, password):
    _, token = call("auth/login", {"email": email, "password": password})
    if not token:
        sys.exit(f"Login for {email} returned no token")
    return token


def ensure_tester(admin):
    try:
        return login(TESTER_EMAIL, TESTER_PASSWORD)
    except urllib.error.HTTPError as error:
        if error.code != 401:
            raise
    call("workspace/invites/create", {"emails": [TESTER_EMAIL], "role": "member", "groupIds": []}, admin)
    invites, _ = call("workspace/invites", {"limit": 50}, admin)
    invite = next(i for i in invites["items"] if i["email"] == TESTER_EMAIL)
    link, _ = call("workspace/invites/link", {"invitationId": invite["id"]}, admin)
    token = re.search(r"token=([^&]+)", link["inviteLink"]).group(1)
    _, cookie = call("workspace/invites/accept", {
        "invitationId": invite["id"], "token": token, "name": TESTER_NAME, "password": TESTER_PASSWORD,
    })
    print(f"{TESTER_NAME} created")
    return cookie or login(TESTER_EMAIL, TESTER_PASSWORD)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("page_id")
    parser.add_argument("--count", type=int, default=1)
    args = parser.parse_args()

    admin = login(*env_credentials())
    admin_user = call("users/me", token=admin)[0]["user"]
    tester = ensure_tester(admin)
    tester_user = call("users/me", token=tester)[0]["user"]

    page, _ = call("pages/info", {"pageId": args.page_id}, admin)
    members, _ = call("spaces/members", {"spaceId": page["spaceId"], "limit": 100}, admin)
    if not any((m.get("id") == tester_user["id"]) for m in members.get("items", [])):
        call("spaces/members/add", {"spaceId": page["spaceId"], "role": "writer", "userIds": [tester_user["id"]], "groupIds": []}, admin)

    comments, _ = call("comments", {"pageId": args.page_id, "limit": 100}, tester)
    for comment in comments.get("items", []):
        # Her replies hang under her own comments and are deleted with them.
        if comment.get("creatorId") == tester_user["id"] and not comment.get("parentCommentId"):
            call("comments/delete", {"commentId": comment["id"]}, tester)

    for number in range(args.count):
        mention = {"type": "mention", "attrs": {
            "id": str(uuid.uuid4()), "label": admin_user["name"], "entityType": "user",
            "entityId": admin_user["id"], "creatorId": tester_user["id"],
        }}
        doc = {"type": "doc", "content": [{"type": "paragraph", "content": [
            {"type": "text", "text": "Hallo "}, mention, {"type": "text", "text": f", schau dir bitte die Tabelle an ({number + 1})."},
        ]}]}
        thread, _ = call("comments/create", {"pageId": args.page_id, "content": json.dumps(doc), "type": "page"}, tester)
    source = {"type": "link", "attrs": {"href": "https://example.com/diderot-uitest-quelle", "target": "_blank", "internal": False}}
    reply = {"type": "doc", "content": [
        {"type": "paragraph", "content": [{"type": "text", "text": "Nachtrag der Kollegin"}]},
        {"type": "paragraph", "content": [{"type": "text", "text": "Siehe "}, {"type": "text", "text": "Quelle", "marks": [source]}]},
    ]}
    call("comments/create", {"pageId": args.page_id, "content": json.dumps(reply), "parentCommentId": thread["id"]}, tester)
    # The server creates notifications through a queue, so poll briefly until they exist.
    for _ in range(20):
        unread, _ = call("notifications/unread-count", token=admin)
        if unread.get("count", 0) >= args.count:
            break
        time.sleep(0.25)
    print(f"{args.count} mention(s) created, unread for the admin: {unread.get('count')}")


if __name__ == "__main__":
    main()
