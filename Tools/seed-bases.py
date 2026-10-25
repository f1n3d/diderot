#!/usr/bin/env python3
"""Creates the database test data in the dev instance (dev only):

- "Kanban-Test": database with the Kanban template and three cards in the test page's space,
- "Datenbank-Einbettung": page with a paragraph and the embedded "Kanban-Test" database,
- "Datenbank-Test": all property types, 30 rows, table and board,
- "Projekte" › "Projektplan": Kanban template with an emoji icon and a second view, under another page.

Prints the IDs as `KEY=value` (for Tools/run-uitests.sh).

    Tools/seed-bases.py <pageId of the editor test page>
"""
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASE_URL = os.environ.get("DOCMOST_SEED_URL", "http://localhost:3000") + "/api/"


def credentials():
    env = {}
    for line in (ROOT / ".env").read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip().strip('"').strip("'")
    return env["DEV_ADMIN_EMAIL"], env["DEV_ADMIN_PASSWORD"]


def call(path, body=None, token=None):
    request = urllib.request.Request(BASE_URL + path, data=json.dumps(body or {}).encode(), method="POST")
    request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(request) as response:
        payload = json.loads(response.read() or b"{}")
        cookie = next((m.group(1) for h in (response.headers.get_all("Set-Cookie") or [])
                       for m in [re.match(r"authToken=([^;]+)", h)] if m), None)
        return payload.get("data", payload), cookie


def main():
    test_page_id = sys.argv[1]
    email, password = credentials()
    _, token = call("auth/login", {"email": email, "password": password})
    space_id = call("pages/info", {"pageId": test_page_id}, token)[0]["spaceId"]

    bases = call("bases", {"spaceId": space_id, "limit": 100}, token)[0]["items"]
    base = next((b for b in bases if b.get("title") == "Kanban-Test"), None)
    if base is None:
        base = call("bases/create", {"spaceId": space_id, "name": "Kanban-Test", "template": "kanban"}, token)[0]
    info = call("bases/info", {"pageId": base["id"]}, token)[0]
    title = next(p for p in info["properties"] if p.get("isPrimary"))
    status = next(p for p in info["properties"] if p["type"] == "status")
    choices = status["typeOptions"]["choices"]
    rows = call("bases/rows", {"pageId": base["id"], "limit": 100}, token)[0]["items"]
    if not rows:
        for index, choice in enumerate([choices[0], choices[0], choices[1]]):
            call("bases/rows/create", {"pageId": base["id"], "cells": {title["id"]: f"Karte {index + 1}", status["id"]: choice["id"]}}, token)

    sidebar = call("pages/sidebar-pages", {"spaceId": space_id, "limit": 100}, token)[0]["items"]
    # Prefix: a title or favorite test (HomeUITests) that stopped halfway leaves the page renamed and a favorite.
    host = next((p for p in sidebar if (p.get("title") or "").startswith("Datenbank-Einbettung")), None)
    if host is None:
        host = call("pages/create", {"spaceId": space_id, "title": "Datenbank-Einbettung"}, token)[0]
    content = {"type": "doc", "content": [
        {"type": "paragraph", "content": [{"type": "text", "text": "Eine eingebettete Datenbank:"}]},
        {"type": "base", "attrs": {"pageId": base["id"]}},
    ]}
    call("pages/update", {"pageId": host["id"], "title": "Datenbank-Einbettung", "content": content, "format": "json",
                          "operation": "replace"}, token)
    try:
        call("favorites/remove", {"type": "page", "pageId": host["id"]}, token)
    except urllib.error.HTTPError:
        pass  # not a favorite
    full, ids = ensure_full_base(token, space_id, test_page_id, bases)
    nested = ensure_nested_base(token, space_id, sidebar)
    print(f"DOCMOST_UITEST_BASE={base['id']}")
    print(f"DOCMOST_UITEST_BASE_HOST={host['id']}")
    print(f"DOCMOST_UITEST_BASE_FULL={full}")
    print(f"DOCMOST_UITEST_BASE_NESTED={nested}")
    print(f"DOCMOST_UITEST_BASE_IDS={json.dumps(ids, ensure_ascii=False, separators=(',', ':'))}")


def ensure_nested_base(token, space_id, sidebar):
    """\"Projektplan\" like a database created on the web: Kanban template (Kanban first), emoji icon, second view
    "Tabelle", and under the page "Projekte" (from seed-dev.sh, otherwise new), so it has breadcrumbs above the title."""
    parent = next((p for p in sidebar if p.get("title") == "Projekte"), None)
    if parent is None:
        parent = call("pages/create", {"spaceId": space_id, "title": "Projekte"}, token)[0]
        call("pages/update", {"pageId": parent["id"], "icon": "📁"}, token)
    children = call("pages/sidebar-pages", {"spaceId": space_id, "pageId": parent["id"], "limit": 100}, token)[0]["items"]
    base = next((p for p in children if p.get("title") == "Projektplan"), None)
    if base is None:
        base = call("bases/create", {"parentPageId": parent["id"], "name": "Projektplan", "template": "kanban"}, token)[0]
        call("pages/update", {"pageId": base["id"], "icon": "📱"}, token)
        info = call("bases/info", {"pageId": base["id"]}, token)[0]
        title = next(p for p in info["properties"] if p.get("isPrimary"))
        status = next(p for p in info["properties"] if p["type"] == "status")
        for index, choice in enumerate(status["typeOptions"]["choices"][1:]):
            call("bases/rows/create", {"pageId": base["id"], "cells": {title["id"]: f"Aufgabe {index + 1}", status["id"]: choice["id"]}}, token)
        call("bases/views/create", {"pageId": base["id"], "name": "Tabelle", "type": "table"}, token)
    return base["id"]


def choice_id(name):
    """Stable choice ID ("opt" + 9 characters [0-9a-z]); the client assigns it, the server only checks the format."""
    digest = hashlib.sha1(name.encode()).hexdigest()
    return "opt" + "".join("0123456789abcdefghijklmnopqrstuvwxyz"[int(digest[i:i + 2], 16) % 36] for i in range(0, 18, 2))


def choices(*items):
    return {"choices": [dict(id=choice_id(name), name=name, color=color, **({"category": cat} if cat else {}))
                        for name, color, cat in items],
            "choiceOrder": [choice_id(name) for name, _, _ in items]}


# Every property type once (name, type, options).
FULL_PROPERTIES = [
    ("Status", "status", choices(("Offen", "gray", "todo"), ("In Arbeit", "blue", "inProgress"), ("Erledigt", "green", "complete"))),
    ("Priorität", "select", choices(("Hoch", "red", None), ("Mittel", "yellow", None), ("Niedrig", "gray", None))),
    ("Tags", "multiSelect", choices(("iOS", "blue", None), ("Web", "violet", None), ("Design", "pink", None), ("Backend", "teal", None))),
    ("Fällig", "date", {"includeTime": False}),
    ("Aufwand", "number", {"format": "plain", "precision": 1}),
    ("Budget", "number", {"format": "currency", "currencyCode": "EUR", "precision": 2}),
    ("Fortschritt", "number", {"format": "progress"}),
    ("Erledigt", "checkbox", None),
    ("Verantwortlich", "person", {"allowMultiple": False}),
    ("Seite", "page", None),
    ("Link", "url", None),
    ("E-Mail", "email", None),
    ("Notizen", "longText", None),
    ("Doppelt", "formula", {"source": 'prop("Aufwand") * 2'}),
    ("Anhang", "file", None),
    ("Erstellt", "createdAt", None),
    ("Bearbeitet", "lastEditedAt", None),
    ("Bearbeitet von", "lastEditedBy", None),
]


def ensure_full_base(token, space_id, test_page_id, bases):
    """\"Datenbank-Test\": all property types, 30 rows, views "Tabelle" and "Board" (Kanban by status, "Erledigt" hidden)."""
    base = next((b for b in bases if b.get("title") == "Datenbank-Test"), None)
    if base is None:
        base = call("bases/create", {"spaceId": space_id, "name": "Datenbank-Test"}, token)[0]
    page_id = base["id"]
    info = call("bases/info", {"pageId": page_id}, token)[0]
    existing = {p["name"]: p for p in info["properties"]}
    for name, kind, options in FULL_PROPERTIES:
        if name not in existing:
            body = {"pageId": page_id, "name": name, "type": kind}
            if options is not None:
                body["typeOptions"] = options
            call("bases/properties/create", body, token)
    info = call("bases/info", {"pageId": page_id}, token)[0]
    props = {p["name"]: p for p in info["properties"]}
    title = next(p for p in info["properties"] if p.get("isPrimary"))

    views = {v["name"]: v for v in info["views"]}
    table = next((v for v in info["views"] if v["type"] == "table"), None)
    if table and table["name"] != "Tabelle":
        call("bases/views/update", {"pageId": page_id, "viewId": table["id"], "name": "Tabelle"}, token)
    # Boards often hide done cards; a card set to "Erledigt" leaves the board.
    hidden = [choice_id("Erledigt")]
    if "Board" not in views:
        call("bases/views/create", {"pageId": page_id, "name": "Board", "type": "kanban", "config": {
            "groupByPropertyId": props["Status"]["id"],
            "visiblePropertyIds": [props["Priorität"]["id"], props["Fällig"]["id"], props["Verantwortlich"]["id"]],
            "hiddenChoiceIds": hidden,
        }}, token)
    elif views["Board"]["config"].get("hiddenChoiceIds") != hidden:
        call("bases/views/update", {"pageId": page_id, "viewId": views["Board"]["id"],
                                    "config": {**views["Board"]["config"], "hiddenChoiceIds": hidden}}, token)

    # Leftovers of aborted UI test runs: remove the rows and new tag options they created.
    rows = call("bases/rows", {"pageId": page_id, "limit": 100}, token)[0]["items"]
    stale = [r for r in rows if str(r["cells"].get(title["id"]) or "").startswith("UITest")]
    for row in stale:
        call("bases/rows/delete", {"pageId": page_id, "rowId": row["id"]}, token)
    rows = [r for r in rows if r not in stale]
    tags_options = props["Tags"].get("typeOptions") or {}
    kept = [c for c in tags_options.get("choices", []) if not c["name"].startswith("UITest")]
    if len(kept) != len(tags_options.get("choices", [])):
        call("bases/properties/update", {"pageId": page_id, "propertyId": props["Tags"]["id"], "typeOptions": {
            **tags_options, "choices": kept, "choiceOrder": [c["id"] for c in kept]}}, token)
    if len(rows) < 30:
        me = call("users/me", token=token)[0]["user"]["id"]
        status = [choice_id(n) for n in ("Offen", "In Arbeit", "Erledigt")]
        priority = [choice_id(n) for n in ("Hoch", "Mittel", "Niedrig")]
        tags = [choice_id(n) for n in ("iOS", "Web", "Design", "Backend")]
        for index in range(len(rows), 30):
            cells = {
                title["id"]: f"Aufgabe {index + 1:02d}",
                props["Status"]["id"]: status[index % 3] if index % 7 else None,
                props["Priorität"]["id"]: priority[index % 3],
                props["Tags"]["id"]: [tags[index % 4]] + ([tags[(index + 1) % 4]] if index % 2 else []),
                props["Fällig"]["id"]: f"2026-{10 + index % 3:02d}-{1 + index % 27:02d}T00:00:00.000Z",
                props["Aufwand"]["id"]: round(0.5 + index * 0.75, 1),
                props["Budget"]["id"]: 120 + index * 37.5,
                props["Fortschritt"]["id"]: (index * 13) % 101,
                props["Erledigt"]["id"]: index % 3 == 2,
                props["Verantwortlich"]["id"]: me,
                props["Seite"]["id"]: test_page_id if index % 4 == 0 else None,
                props["Link"]["id"]: f"https://example.com/aufgabe/{index + 1}" if index % 5 == 0 else None,
                props["E-Mail"]["id"]: "team@example.com" if index % 6 == 0 else None,
                props["Notizen"]["id"]: "Eine längere Notiz, die in der Tabelle gekürzt und im Detail ganz angezeigt wird." if index % 3 == 0 else None,
            }
            call("bases/rows/create", {"pageId": page_id, "cells": {k: v for k, v in cells.items() if v is not None}}, token)
    # IDs for the UI tests: properties and status values, keyed by name, and the row "Aufgabe 27" (done, so the board
    # hides it) for the entry link test.
    ids = {name: prop["id"] for name, prop in props.items()}
    ids.update({f"status:{name}": choice_id(name) for name in ("Offen", "In Arbeit", "Erledigt")})
    rows = call("bases/rows", {"pageId": page_id, "limit": 100}, token)[0]["items"]
    ids.update({"row:Aufgabe 27": r["id"] for r in rows if r["cells"].get(title["id"]) == "Aufgabe 27"})
    return page_id, ids


if __name__ == "__main__":
    main()
