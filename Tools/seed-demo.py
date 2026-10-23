#!/usr/bin/env python3
"""Demo content for Apple's App Review and the App Store screenshots: a space with pages that show what Diderot does
(text, lists, tasks, a table, a diagram, code, a formula, a toggle, an image, an embedded database), a task database
and a comment thread, written by two demo people. The member "Alex" is the account for Apple; "Sam" administers the
space. The server's admin only sets it up and then leaves it, so no real name shows up in it and the admin's own
spaces stay as they were (the dev instance's UI tests look for theirs on the home screen). Only for a server without real users: the dev instance or the
separate demo instance. It stops if the server has other users.

    Tools/seed-demo.py                       # dev instance (admin from .env), English
    Tools/seed-demo.py --language de         # the same in German, in a space of its own
    Tools/seed-demo.py --env .env.demo       # the demo instance for Apple
    Tools/seed-demo.py --reset               # deletes the language's demo space first

.env.demo (git-ignored, in the repository root): DEMO_URL, DEMO_ADMIN_EMAIL, DEMO_ADMIN_PASSWORD, DEMO_MEMBER_EMAIL,
DEMO_MEMBER_PASSWORD, DEMO_COLLEAGUE_EMAIL, DEMO_COLLEAGUE_PASSWORD. On the dev instance the two people get fixed
local addresses and passwords. Passwords are never printed.
"""
import argparse
import json
import re
import struct
import sys
import urllib.error
import urllib.request
import uuid
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# The dev instance's UI tests have a colleague of their own (Tools/seed-notifications.py).
DEV_TEST_USERS = {"kollegin@docmost.local"}


def read_env(path):
    env = {}
    for line in path.read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip().strip('"').strip("'")
    return env


def check(config):
    """Stops before the first request if .env.demo has an address or password that can't be right."""
    for key in ("admin", "member", "colleague"):
        email, password = config[key]
        if not re.fullmatch(r"[^@\s#]+@[^@\s#]+\.[A-Za-z]{2,}", email):
            sys.exit(f"The {key}'s email address isn't one (no comments after values in .env.demo)")
        if len(password) < 8:
            sys.exit(f"The {key}'s password needs at least 8 characters")


def settings(env_file):
    """Server, admin and the two demo people: from .env.demo for the demo instance, else the dev instance."""
    if env_file:
        env = read_env(ROOT / env_file)
        return {
            "url": env["DEMO_URL"].rstrip("/"),
            "admin": (env["DEMO_ADMIN_EMAIL"], env["DEMO_ADMIN_PASSWORD"]),
            "member": (env["DEMO_MEMBER_EMAIL"], env["DEMO_MEMBER_PASSWORD"]),
            "colleague": (env["DEMO_COLLEAGUE_EMAIL"], env["DEMO_COLLEAGUE_PASSWORD"]),
        }
    env = read_env(ROOT / ".env")
    return {
        "url": "http://localhost:3000",
        "admin": (env["DEV_ADMIN_EMAIL"], env["DEV_ADMIN_PASSWORD"]),
        "member": ("alex@docmost.local", "alex-dev-123"),
        "colleague": ("sam@docmost.local", "sam-dev-123"),
    }


class Api:
    def __init__(self, url):
        self.url = url

    def call(self, path, body=None, token=None, raw=None, content_type="application/json", refusable=False):
        """POST to the API; returns (data, authToken cookie or None). `refusable`: (None, None) when the server refuses
        it as unlicensed, forbidden or not found."""
        data = raw if raw is not None else json.dumps(body or {}).encode()
        request = urllib.request.Request(f"{self.url}/api/{path}", data=data, method="POST")
        request.add_header("Content-Type", content_type)
        # Firewalls in front of a server (Cloudflare's browser check) refuse Python's default user agent.
        request.add_header("User-Agent", "Diderot-seed-demo")
        if token:
            request.add_header("Authorization", "Bearer " + token)
        try:
            with urllib.request.urlopen(request) as response:
                payload = json.loads(response.read() or b"{}")
                cookie = next((m.group(1) for h in (response.headers.get_all("Set-Cookie") or [])
                               for m in [re.match(r"authToken=([^;]+)", h)] if m), None)
                return payload.get("data", payload), cookie
        except urllib.error.HTTPError as error:
            if error.code == 401 and path == "auth/login":
                raise
            if refusable and error.code in (402, 403, 404):
                return None, None
            sys.exit(f"{path} → HTTP {error.code}: {error.read().decode(errors='replace')[:300]}")

    def login(self, email, password):
        _, token = self.call("auth/login", {"email": email, "password": password})
        if not token:
            sys.exit(f"Sign-in for {email} returned no token")
        return token

    def upload(self, token, page_id, filename, data, mime):
        boundary = f"----diderot{uuid.uuid4().hex}"
        body = b"".join([
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"pageId\"\r\n\r\n{page_id}\r\n".encode(),
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{filename}\"\r\n"
            f"Content-Type: {mime}\r\n\r\n".encode(),
            data,
            f"\r\n--{boundary}--\r\n".encode(),
        ])
        return self.call("files/upload", token=token, raw=body, content_type=f"multipart/form-data; boundary={boundary}")[0]


def ensure_person(api, admin, email, password, name):
    """Signs the person in, after inviting them as a member if they don't exist yet."""
    try:
        return api.login(email, password)
    except urllib.error.HTTPError as error:
        if error.code != 401:
            raise
    api.call("workspace/invites/create", {"emails": [email], "role": "member", "groupIds": []}, admin)
    invites, _ = api.call("workspace/invites", {"limit": 100}, admin)
    invite = next(i for i in invites["items"] if i["email"].lower() == email.lower())
    link, _ = api.call("workspace/invites/link", {"invitationId": invite["id"]}, admin)
    invite_token = re.search(r"token=([^&]+)", link["inviteLink"]).group(1)
    _, cookie = api.call("workspace/invites/accept", {
        "invitationId": invite["id"], "token": invite_token, "name": name, "password": password,
    })
    print(f"{name} invited ({email})")
    return cookie or api.login(email, password)


# MARK: - Content


def text(value, *marks):
    node = {"type": "text", "text": value}
    if marks:
        node["marks"] = [{"type": mark} if isinstance(mark, str) else mark for mark in marks]
    return node


def link(href):
    return {"type": "link", "attrs": {"href": href, "target": "_blank", "internal": False}}


def paragraph(*parts):
    return {"type": "paragraph", "content": [text(p) if isinstance(p, str) else p for p in parts]}


def heading(level, value):
    return {"type": "heading", "attrs": {"level": level}, "content": [text(value)]}


def bullets(*items):
    return {"type": "bulletList", "content": [{"type": "listItem", "content": [paragraph(*item) if isinstance(item, tuple) else paragraph(item)]}
                                              for item in items]}


def tasks(*items):
    return {"type": "taskList", "content": [{"type": "taskItem", "attrs": {"checked": done}, "content": [paragraph(label)]}
                                            for label, done in items]}


def callout(kind, *parts):
    return {"type": "callout", "attrs": {"type": kind, "icon": None}, "content": [paragraph(*parts)]}


def status(label, color):
    return {"type": "status", "attrs": {"text": label, "color": color}}


def table(header, *rows):
    def cell(kind, value):
        content = paragraph(*value) if isinstance(value, tuple) else paragraph(value)
        return {"type": kind, "attrs": {"colspan": 1, "rowspan": 1, "colwidth": None}, "content": [content]}
    return {"type": "table", "content": [{"type": "tableRow", "content": [cell("tableHeader", v) for v in header]}]
            + [{"type": "tableRow", "content": [cell("tableCell", v) for v in row]} for row in rows]}


def code(language, source):
    return {"type": "codeBlock", "attrs": {"language": language}, "content": [text(source)]}


def toggle(summary, *content):
    return {"type": "details", "attrs": {"open": False}, "content": [
        {"type": "detailsSummary", "content": [text(summary)]},
        {"type": "detailsContent", "content": list(content)},
    ]}


def mention(user, author):
    return {"type": "mention", "attrs": {"id": uuid.uuid4().hex[:12], "label": user["name"], "entityType": "user",
                                         "entityId": user["id"], "creatorId": author["id"]}}


def doc(*blocks):
    return {"type": "doc", "content": list(blocks)}


def brand_png(width=1200, height=675):
    """A forest-green banner with a lighter band, so the image block has something to show; no dependencies."""
    rows = []
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            band = 1 - min(1, abs(y - height * 0.62 - (x - width / 2) * 0.18) / (height * 0.22))
            row += bytes((int(31 + 160 * band * 0.5), int(92 + 120 * band * 0.6), int(61 + 100 * band * 0.4)))
        rows.append(bytes(row))

    def chunk(tag, body):
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b"")


def pages(t, member, colleague):
    """(title, icon, content) per page; `t(en, de)` picks the language. The image and the embedded database come after
    the pages exist (upload, and the database last so it ends up last in the page tree)."""
    return [
        (t("Welcome", "Willkommen"), "👋", doc(
            paragraph(t("This space shows what working in Diderot feels like: read and edit pages, check off tasks, "
                        "keep track of a project and talk things through, ",
                        "Dieser Bereich zeigt, wie sich Arbeiten in Diderot anfühlt: Seiten lesen und bearbeiten, "
                        "Aufgaben abhaken, ein Projekt im Blick behalten und Dinge besprechen, "),
                      text(t("live with everyone on the web", "live mit allen im Web"), "bold"), "."),
            heading(2, t("Try it", "Ausprobieren")),
            tasks((t("Tap a paragraph and change it", "Einen Absatz antippen und ändern"), False),
                  (t("Check off this task", "Diese Aufgabe abhaken"), False),
                  (t("Open the comments on “Weekly Sync”", "Die Kommentare zu „Wöchentliche Abstimmung“ öffnen"), True)),
            callout("info", t("Changes are saved as you type and appear on the web right away.",
                              "Änderungen werden beim Tippen gespeichert und erscheinen sofort im Web.")),
        )),
        (t("Product Roadmap", "Produkt-Roadmap"), "🗺️", doc(
            paragraph(t("Where the app is heading this year. Each quarter has one goal everyone can name.",
                        "Wohin sich die App dieses Jahr entwickelt. Jedes Quartal hat ein Ziel, das alle kennen.")),
            table((t("Quarter", "Quartal"), t("Goal", "Ziel"), "Status"),
                  ("Q1", t("Offline editing", "Offline bearbeiten"), (status(t("Done", "Erledigt"), "green"),)),
                  ("Q2", t("Shared databases", "Gemeinsame Datenbanken"), (status(t("In progress", "In Arbeit"), "blue"),)),
                  ("Q3", t("Faster search", "Schnellere Suche"), (status(t("Planned", "Geplant"), "gray"),)),
                  ("Q4", t("iPad multitasking", "iPad-Multitasking"), (status(t("Planned", "Geplant"), "gray"),))),
            heading(2, t("How a release ships", "So geht ein Release raus")),
            code("mermaid", t("flowchart LR\n  Idea --> Spec --> Build --> Review --> Release\n  Review -- changes --> Build",
                              "flowchart LR\n  Idee --> Konzept --> Umsetzung --> Review --> Release\n  Review -- Änderungen --> Umsetzung")),
        )),
        (t("Weekly Sync", "Wöchentliche Abstimmung"), "📝", doc(
            paragraph(text(t("Attendees: ", "Dabei: "), "bold"), mention(member, member), ", ", mention(colleague, member)),
            heading(2, t("Decisions", "Entscheidungen")),
            bullets(t("The beta starts on Monday.", "Die Beta startet am Montag."),
                    t("Feedback goes into the task database.", "Rückmeldungen kommen in die Aufgaben-Datenbank."),
                    (t("Release notes stay short: ", "Release-Notes bleiben kurz: "), text(t("three bullets at most", "höchstens drei Punkte"), "italic"))),
            heading(2, t("Action items", "Nächste Schritte")),
            tasks((t("Invite the beta testers", "Beta-Tester einladen"), True),
                  (t("Update the screenshots", "Screenshots aktualisieren"), False),
                  (t("Write the release notes", "Release-Notes schreiben"), False)),
            {"type": "blockquote", "content": [paragraph(t("Ship small, ship often.", "Klein und oft ausliefern."))]},
        )),
        (t("Engineering Notes", "Technik-Notizen"), "🛠️", doc(
            paragraph(t("How the app keeps a page in sync, in short.", "Wie die App eine Seite synchron hält, kurz erklärt.")),
            code("swift", "func save(_ change: Change) async throws {\n    try await engine.apply(change)\n    await outbox.flush()\n}"),
            paragraph(t("Retries back off exponentially:", "Wiederholungen warten exponentiell länger:")),
            {"type": "mathBlock", "attrs": {"text": "t_n = t_0 \\cdot 2^{n}"}},
            toggle(t("What happens offline?", "Was passiert offline?"),
                   paragraph(t("Edits are kept on the device and sent when the network is back.",
                               "Änderungen bleiben auf dem Gerät und gehen raus, sobald das Netz wieder da ist."))),
        )),
        (t("Brand Guide", "Marken-Leitfaden"), "🎨", doc(
            paragraph(t("Forest green, a serif headline and plenty of space. Use the banner below for announcements.",
                        "Waldgrün, eine Serifen-Überschrift und viel Raum. Für Ankündigungen das Banner unten nehmen.")),
            callout("success", t("Primary color: ", "Hauptfarbe: "), text("#1F5C3D", "code")),
        )),
    ]


def base_spec(t):
    open_, doing, done = t("Open", "Offen"), t("In progress", "In Arbeit"), t("Done", "Erledigt")
    high, medium, low = t("High", "Hoch"), t("Medium", "Mittel"), t("Low", "Niedrig")
    rows = [
        (t("Invite the beta testers", "Beta-Tester einladen"), done, high, "2027-03-02", "member"),
        (t("Polish the onboarding", "Einstieg überarbeiten"), doing, high, "2027-03-09", "colleague"),
        (t("Update the screenshots", "Screenshots aktualisieren"), open_, medium, "2027-03-12", "member"),
        (t("Write the release notes", "Release-Notes schreiben"), open_, medium, "2027-03-16", "colleague"),
        (t("Check VoiceOver labels", "VoiceOver-Beschriftungen prüfen"), doing, medium, "2027-03-18", "member"),
        (t("Plan the next sprint", "Nächsten Sprint planen"), open_, low, "2027-03-23", "colleague"),
    ]
    return {"name": t("Tasks", "Aufgaben"), "status": (open_, doing, done), "priority": (high, medium, low),
            "properties": (t("Priority", "Priorität"), t("Due", "Fällig"), t("Owner", "Zuständig")), "rows": rows}


def choice_options(*names_colors):
    choices = [{"id": "opt" + uuid.uuid5(uuid.NAMESPACE_URL, name).hex[:9], "name": name, "color": color, **({"category": cat} if cat else {})}
               for name, color, cat in names_colors]
    return {"choices": choices, "choiceOrder": [c["id"] for c in choices]}


def create_base(api, token, space_id, spec, people):
    """The task database, or None where the server's license has no databases."""
    base = api.call("bases/create", {"spaceId": space_id, "name": spec["name"]}, token, refusable=True)[0]
    if base is None:
        return None
    page_id = base["id"]
    open_, doing, done = spec["status"]
    priority_name, due_name, owner_name = spec["properties"]
    status_options = choice_options((open_, "gray", "todo"), (doing, "blue", "inProgress"), (done, "green", "complete"))
    priority_options = choice_options(*((name, color, None) for name, color in zip(spec["priority"], ("red", "yellow", "gray"))))
    api.call("bases/properties/create", {"pageId": page_id, "name": "Status", "type": "status", "typeOptions": status_options}, token)
    api.call("bases/properties/create", {"pageId": page_id, "name": priority_name, "type": "select", "typeOptions": priority_options}, token)
    api.call("bases/properties/create", {"pageId": page_id, "name": due_name, "type": "date", "typeOptions": {"includeTime": False}}, token)
    api.call("bases/properties/create", {"pageId": page_id, "name": owner_name, "type": "person", "typeOptions": {"allowMultiple": False}}, token)
    info = api.call("bases/info", {"pageId": page_id}, token)[0]
    props = {p["name"]: p for p in info["properties"]}
    title = next(p for p in info["properties"] if p.get("isPrimary"))
    ids = {c["name"]: c["id"] for options in (status_options, priority_options) for c in options["choices"]}
    for name, state, priority, due, owner in spec["rows"]:
        api.call("bases/rows/create", {"pageId": page_id, "cells": {
            title["id"]: name, props["Status"]["id"]: ids[state], props[priority_name]["id"]: ids[priority],
            props[due_name]["id"]: f"{due}T00:00:00.000Z", props[owner_name]["id"]: people[owner]["id"],
        }}, token)
    api.call("bases/views/create", {"pageId": page_id, "name": "Board", "type": "kanban", "config": {
        "groupByPropertyId": props["Status"]["id"],
        "visiblePropertyIds": [props[priority_name]["id"], props[due_name]["id"], props[owner_name]["id"]],
    }}, token)
    return page_id


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--language", choices=["en", "de"], default="en")
    parser.add_argument("--env", help="settings file in the repository root, e.g. .env.demo")
    parser.add_argument("--reset", action="store_true")
    args = parser.parse_args()
    config = settings(args.env)
    check(config)
    api = Api(config["url"])

    def t(en, de):
        return de if args.language == "de" else en

    admin = api.login(*config["admin"])
    names = {"member": "Alex Morgan", "colleague": "Sam Lee"}
    allowed = {config["admin"][0].lower(), config["member"][0].lower(), config["colleague"][0].lower()} | DEV_TEST_USERS
    members, _ = api.call("workspace/members", {"limit": 100}, admin)
    strangers = [m for m in members["items"] if (m.get("email") or "").lower() not in allowed]
    if strangers:
        sys.exit(f"{config['url']} has {len(strangers)} other user(s): demo content only goes to a server without real "
                 "users (the dev instance or the demo instance).")

    tokens = {key: ensure_person(api, admin, *config[key], names[key]) for key in ("member", "colleague")}
    people = {key: api.call("users/me", token=tokens[key])[0]["user"] for key in tokens}

    slug = t("product", "produkt")
    # Sam administers the space; the admin only until it is set up (or in one from before that).
    managers = [tokens["colleague"], admin]
    space = next((s for s in (api.call("spaces/info", {"spaceId": slug}, m, refusable=True)[0] for m in managers) if s), None)
    if space and args.reset:
        if not any(api.call("spaces/delete", {"spaceId": space["id"]}, m, refusable=True)[0] is not None for m in managers):
            sys.exit(f"Neither Sam nor the admin may delete the space “{space['name']}”")
        print(f"Space “{space['name']}” deleted.")
        space = None
    if space:
        print(f"Space “{space['name']}” exists; --reset recreates it.")
        return
    space = api.call("spaces/create", {"name": t("Product Team", "Produktteam"), "slug": slug,
                                       "description": t("Demo content for Diderot", "Demo-Inhalte für Diderot")}, admin)[0]
    for key, role in (("colleague", "admin"), ("member", "writer")):
        api.call("spaces/members/add", {"spaceId": space["id"], "role": role, "groupIds": [], "userIds": [people[key]["id"]]}, admin)
    admin_id = api.call("users/me", token=admin)[0]["user"]["id"]
    api.call("spaces/members/remove", {"spaceId": space["id"], "userId": admin_id}, tokens["colleague"])
    print(f"Space “{space['name']}” created.")

    author = tokens["member"]
    created = {}
    for title, icon, content in pages(t, people["member"], people["colleague"]):
        page = api.call("pages/create", {"spaceId": space["id"], "title": title, "icon": icon}, author)[0]
        if icon == "🎨":
            banner = api.upload(author, page["id"], "banner.png", brand_png(), "image/png")
            content["content"].append({"type": "image", "attrs": {
                "src": f"/api/files/{banner['id']}/{banner['fileName']}", "attachmentId": banner["id"],
                "size": banner["fileSize"], "alt": t("Brand banner", "Marken-Banner"), "align": "center"}})
        api.call("pages/update", {"pageId": page["id"], "content": content, "operation": "replace", "format": "json"}, author)
        created[icon] = (page, content)
        print(f"  {icon} {title}")
    base_id = create_base(api, author, space["id"], base_spec(t), people)
    if base_id:
        print(f"  ✅ {base_spec(t)['name']}")
        welcome, content = created["👋"]
        content["content"] += [heading(2, t("Tasks", "Aufgaben")), {"type": "base", "attrs": {"pageId": base_id}}]
        api.call("pages/update", {"pageId": welcome["id"], "content": content, "operation": "replace", "format": "json"}, author)
    else:
        print("  (no task database: the server's license has no databases)")

    sync = created["📝"][0]["id"]
    thread, _ = api.call("comments/create", {"pageId": sync, "type": "page", "content": json.dumps(doc(
        paragraph(t("Can we move the beta to Tuesday? Monday is a holiday in some countries.",
                    "Können wir die Beta auf Dienstag legen? Montag ist in manchen Ländern Feiertag.")))),
    }, tokens["colleague"])
    api.call("comments/create", {"pageId": sync, "parentCommentId": thread["id"], "content": json.dumps(doc(
        paragraph(t("Good point, Tuesday it is. I'll update the notes.", "Guter Punkt, dann Dienstag. Ich passe die Notizen an.")))),
    }, tokens["member"])
    print(f"Done: {config['url']}, space “{space['name']}”, member {config['member'][0]}.")


if __name__ == "__main__":
    main()
