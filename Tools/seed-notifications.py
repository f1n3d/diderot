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
import re
import sys
import time
import urllib.parse
import uuid

import dev_api

# Only ever on a dev instance on this Mac: the script creates a test user and deletes comments.
if not dev_api.is_local(dev_api.base_url()):
    sys.exit(f"{dev_api.base_url()} is no local dev instance: this script creates a test user there.")
TESTER_EMAIL = "kollegin@docmost.local"
TESTER_NAME = "Test-Kollegin"


def ensure_tester(admin):
    """Her session, after creating her through an invitation if she can't sign in."""
    password = dev_api.dev_password(TESTER_EMAIL)
    dev_api.replace_fixed_password(TESTER_EMAIL)
    try:
        tester = dev_api.session(TESTER_EMAIL, password)
        tester.call("users/me")  # a token of hers from before the dev data was reset fails here
        return tester
    except dev_api.ApiError as error:
        if error.status != 401:
            raise
    # Her fixed password back (the dev data restored from before), or no account yet.
    if dev_api.replace_fixed_password(TESTER_EMAIL, again=True):
        return dev_api.session(TESTER_EMAIL, password)
    admin.call("workspace/invites/create", {"emails": [TESTER_EMAIL], "role": "member", "groupIds": []})
    invites = admin.call("workspace/invites", {"limit": 50})
    invite = next((i for i in invites["items"] if i["email"] == TESTER_EMAIL), None)
    if invite is None:
        # Docmost doesn't invite members: she exists, with a password other than hers (the admin's in .env changed).
        sys.exit(f"{TESTER_EMAIL} exists but doesn't take her password: remove her from the workspace "
                 "(Settings › Members) and run this again.")
    link = admin.call("workspace/invites/link", {"invitationId": invite["id"]})
    token = re.search(r"token=([^&]+)", link["inviteLink"]).group(1)
    dev_api.Api().call("workspace/invites/accept", {
        "invitationId": invite["id"], "token": token, "name": TESTER_NAME, "password": password,
    })
    print(f"{TESTER_NAME} created")
    return dev_api.session(TESTER_EMAIL, password)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("page_id")
    parser.add_argument("--count", type=int, default=1)
    args = parser.parse_args()

    admin = dev_api.session(*dev_api.admin())
    admin_user = admin.call("users/me")["user"]
    tester = ensure_tester(admin)
    tester_user = tester.call("users/me")["user"]

    page = admin.call("pages/info", {"pageId": args.page_id})
    members = admin.call("spaces/members", {"spaceId": page["spaceId"], "limit": 100})
    if not any((m.get("id") == tester_user["id"]) for m in members.get("items", [])):
        admin.call("spaces/members/add", {"spaceId": page["spaceId"], "role": "writer", "userIds": [tester_user["id"]], "groupIds": []})

    comments = tester.call("comments", {"pageId": args.page_id, "limit": 100})
    for comment in comments.get("items", []):
        # Her replies hang under her own comments and are deleted with them.
        if comment.get("creatorId") == tester_user["id"] and not comment.get("parentCommentId"):
            tester.call("comments/delete", {"commentId": comment["id"]})

    for number in range(args.count):
        mention = {"type": "mention", "attrs": {
            "id": str(uuid.uuid4()), "label": admin_user["name"], "entityType": "user",
            "entityId": admin_user["id"], "creatorId": tester_user["id"],
        }}
        doc = {"type": "doc", "content": [{"type": "paragraph", "content": [
            {"type": "text", "text": "Hallo "}, mention, {"type": "text", "text": f", schau dir bitte die Tabelle an ({number + 1})."},
        ]}]}
        thread = tester.call("comments/create", {"pageId": args.page_id, "content": json.dumps(doc), "type": "page"})
    source = {"type": "link", "attrs": {"href": "https://example.com/diderot-uitest-quelle", "target": "_blank", "internal": False}}
    reply = {"type": "doc", "content": [
        {"type": "paragraph", "content": [{"type": "text", "text": "Nachtrag der Kollegin"}]},
        {"type": "paragraph", "content": [{"type": "text", "text": "Siehe "}, {"type": "text", "text": "Quelle", "marks": [source]}]},
    ]}
    tester.call("comments/create", {"pageId": args.page_id, "content": json.dumps(reply), "parentCommentId": thread["id"]})
    # The server creates notifications through a queue, so poll briefly until they exist.
    for _ in range(20):
        unread = admin.call("notifications/unread-count")
        if unread.get("count", 0) >= args.count:
            break
        time.sleep(0.25)
    print(f"{args.count} mention(s) created, unread for the admin: {unread.get('count')}")


if __name__ == "__main__":
    dev_api.run(main)
