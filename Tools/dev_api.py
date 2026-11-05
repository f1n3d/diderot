#!/usr/bin/env python3
"""The dev instance's settings, sign-in and API calls, for the seed tools and Tools/run-uitests.sh (dev only).

Passwords and tokens never go on a command line, where `ps` shows them to every user of this Mac: shell scripts read
settings with `setting` and call the API with `call` and `upload`, which sign in by themselves. The sign-in token is
cached per server and user in Tools/.cache/dev-tokens.json, readable by this user only, because the server allows
10 sign-ins a minute per IP; a token the server refuses is renewed once.

    Tools/dev_api.py setting DEV_ADMIN_EMAIL                  # a value from .env (empty if it isn't there)
    Tools/dev_api.py call spaces/info spaceId=demo --field id  # POST {"spaceId": "demo"}, print the answer's data.id
    Tools/dev_api.py call pages/sidebar-pages spaceId=… limit:=5
    Tools/dev_api.py call pages/update - < body.json          # the body as JSON from stdin
    Tools/dev_api.py upload <pageId> <file> [type]            # attach a file to a page

`key=value` sends a string, `key:=value` a JSON value (a number, null, a list …), as in HTTPie. The calls sign in as
DOCMOST_API_EMAIL / DOCMOST_API_PASSWORD if set (Tools/run-uitests.sh sets them to the user its tests sign in as),
else as the admin from .env; DOCMOST_SEED_URL picks the server (default http://localhost:3000).
"""
import argparse
import base64
import json
import mimetypes
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOKENS = ROOT / "Tools/.cache/dev-tokens.json"
# Where the shell tools kept a token before, readable by every user of this Mac; removed when found.
LEGACY_TOKEN = ROOT / "Tools/.cache/seed-token.txt"


def read_env(path):
    """KEY=value lines (`export ` before a key is allowed); empty lines and lines starting with # are skipped. Values are
    taken as written, without $ expansion, escapes or comments after them; quotes around a value are removed."""
    path = Path(path)
    if path.stat().st_mode & 0o077:
        print(f"{path.name} can be read by other users of this Mac: chmod 600 {path.name}", file=sys.stderr)
    env = {}
    for number, line in enumerate(path.read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, equals, value = line.partition("=")
        key = re.sub(r"^export\s+", "", key.strip())
        if not equals or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            # Not the line itself: it may hold a password.
            sys.exit(f"{path.name}, line {number}: expected KEY=value")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        env[key] = value
    return env


def settings():
    """The repository's .env; empty without one."""
    path = ROOT / ".env"
    return read_env(path) if path.exists() else {}


def admin():
    """Email and password of the dev instance's admin, from .env."""
    env = settings()
    missing = [key for key in ("DEV_ADMIN_EMAIL", "DEV_ADMIN_PASSWORD") if not env.get(key)]
    if missing:
        sys.exit(f"{' and '.join(missing)} missing in .env (see .env.example)")
    return env["DEV_ADMIN_EMAIL"], env["DEV_ADMIN_PASSWORD"]


def user():
    """Who the calls sign in as: DOCMOST_API_EMAIL / DOCMOST_API_PASSWORD if set, else the admin."""
    if os.environ.get("DOCMOST_API_EMAIL"):
        return os.environ["DOCMOST_API_EMAIL"], os.environ.get("DOCMOST_API_PASSWORD", "")
    return admin()


def base_url():
    return os.environ.get("DOCMOST_SEED_URL", "http://localhost:3000").rstrip("/")


class ApiError(Exception):
    """An answer other than 2xx (`status`), or none at all (`status` None)."""

    def __init__(self, path, status, detail):
        super().__init__(f"{path} → HTTP {status}: {detail[:300]}" if status else f"{path}: {detail}")
        self.path = path
        self.status = status


class Api:
    """POSTs to one server's API as one user."""

    def __init__(self, url=None, token=None, credentials=None, cache=False):
        self.url = (url or base_url()).rstrip("/")
        self.token = token
        # To sign in again with once, when the server refuses the token (expired, or the dev data was reset).
        self.credentials = credentials
        self.cache = cache
        self.signed_in = False

    def call(self, path, body=None, raw=None, content_type="application/json"):
        """The answer's `data`, or the whole answer if it has none."""
        try:
            return self.post(path, body, raw, content_type)[0]
        except ApiError as error:
            if error.status != 401 or not self.credentials or self.signed_in:
                raise
        self.sign_in(*self.credentials)
        return self.post(path, body, raw, content_type)[0]

    def post(self, path, body=None, raw=None, content_type="application/json"):
        """(data, the authToken cookie the server set or None), without signing in again."""
        data = raw if raw is not None else json.dumps({} if body is None else body).encode()
        request = urllib.request.Request(f"{self.url}/api/{path}", data=data, method="POST")
        request.add_header("Content-Type", content_type)
        # Firewalls in front of a server (Cloudflare's browser check) refuse Python's default user agent.
        request.add_header("User-Agent", "Diderot-dev-tools")
        if self.token:
            request.add_header("Authorization", "Bearer " + self.token)
        try:
            with urllib.request.urlopen(request) as response:
                payload = json.loads(response.read() or b"{}")
                cookies = response.headers.get_all("Set-Cookie") or []
        except urllib.error.HTTPError as error:
            raise ApiError(path, error.code, error.read().decode(errors="replace")) from None
        except urllib.error.URLError as error:
            raise ApiError(path, None, f"no answer from {self.url} ({error.reason}); is the dev instance running?") from None
        token = next((m.group(1) for cookie in cookies for m in [re.match(r"authToken=([^;]+)", cookie)] if m), None)
        return (payload.get("data", payload) if isinstance(payload, dict) else payload), token

    def sign_in(self, email, password):
        print(f"Signing in to {self.url} as {email} …", file=sys.stderr)
        self.token = None  # the refused one stays out of the sign-in
        _, token = self.post("auth/login", {"email": email, "password": password})
        if not token:
            raise ApiError("auth/login", None, f"no token for {email}")
        self.token = token
        self.signed_in = True
        if self.cache:
            store_token(self.url, email, token)
        return token

    def upload(self, page_id, filename, data, mime=None):
        """Attaches `data` to the page as `filename` (files/upload) and returns the attachment."""
        mime = mime or mimetypes.guess_type(filename)[0] or "application/octet-stream"
        boundary = f"----diderot{uuid.uuid4().hex}"
        body = b"".join([
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"pageId\"\r\n\r\n{page_id}\r\n".encode(),
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{filename}\"\r\n"
            f"Content-Type: {mime}\r\n\r\n".encode(),
            data,
            f"\r\n--{boundary}--\r\n".encode(),
        ])
        return self.call("files/upload", raw=body, content_type=f"multipart/form-data; boundary={boundary}")


def session(email=None, password=None, url=None, cache=True):
    """An Api signed in as `email` (default: `user()`): with its cached token unless that has expired, else anew.
    `cache=False` for servers other than the dev instance, whose tokens shouldn't stay on disk."""
    if email is None:
        email, password = user()
    api = Api(url, credentials=(email, password), cache=cache)
    api.token = cached_token(api.url, email) if cache else None
    if not api.token:
        api.sign_in(email, password)
    return api


def run(main):
    """Runs a tool's main(), ending it with an API error's message instead of a traceback."""
    try:
        main()
    except ApiError as error:
        sys.exit(str(error))


# The token cache: {"<server>|<email>": token}.

def token_key(url, email):
    return f"{url}|{email.lower()}"


def expired(token, margin=60):
    """Whether the token's `exp` claim is past (or within `margin` seconds); unreadable ones count as expired."""
    try:
        claims = token.split(".")[1]
        expiry = json.loads(base64.urlsafe_b64decode(claims + "=" * (-len(claims) % 4))).get("exp")
    except (AttributeError, IndexError, ValueError):
        return True
    return isinstance(expiry, (int, float)) and expiry < time.time() + margin


def load_tokens():
    LEGACY_TOKEN.unlink(missing_ok=True)
    try:
        tokens = json.loads(TOKENS.read_text())
    except (OSError, ValueError):
        return {}
    return {key: token for key, token in tokens.items() if isinstance(token, str)} if isinstance(tokens, dict) else {}


def cached_token(url, email):
    token = load_tokens().get(token_key(url, email))
    return None if token is None or expired(token) else token


def store_token(url, email, token):
    tokens = {key: old for key, old in load_tokens().items() if not expired(old, 0)}
    tokens[token_key(url, email)] = token
    TOKENS.parent.mkdir(parents=True, exist_ok=True)
    # Readable by this user only from the first byte: mkstemp makes the file 0600, and the move keeps that.
    descriptor, temporary = tempfile.mkstemp(dir=TOKENS.parent, prefix=".dev-tokens-")
    try:
        with os.fdopen(descriptor, "w") as file:
            json.dump(tokens, file)
        os.replace(temporary, TOKENS)
    finally:
        Path(temporary).unlink(missing_ok=True)


# The command line.

def body_of(items):
    """The JSON body from `key=value` (a string) and `key:=value` (JSON) items, or `-` alone for JSON from stdin."""
    if items == ["-"]:
        return json.load(sys.stdin)
    body = {}
    for item in items:
        match = re.fullmatch(r"([^=:]+)(:?=)(.*)", item, re.S)
        if not match:
            sys.exit(f"Expected key=value, key:=json or -, got {item!r}")
        key, kind, value = match.groups()
        try:
            body[key] = json.loads(value) if kind == ":=" else value
        except ValueError:
            sys.exit(f"{key}:= needs a JSON value")
    return body


def main():
    parser = argparse.ArgumentParser(description="The dev instance's settings and API, without passwords or tokens on the command line.")
    commands = parser.add_subparsers(dest="command", required=True)
    setting = commands.add_parser("setting", help="print a value from .env, empty if it isn't there")
    setting.add_argument("key")
    call = commands.add_parser("call", help="POST to /api/<path> and print the answer's data as JSON")
    call.add_argument("path")
    call.add_argument("items", nargs="*", help="key=value (a string), key:=value (JSON), or - for a JSON body from stdin")
    call.add_argument("--field", help="print only this field of the data, a string as it is")
    upload = commands.add_parser("upload", help="attach a file to a page (files/upload)")
    upload.add_argument("page_id")
    upload.add_argument("file", type=Path)
    upload.add_argument("type", nargs="?", help="its media type (default: from the file name)")
    args = parser.parse_args()

    if args.command == "setting":
        print(settings().get(args.key, ""))
    elif args.command == "call":
        body = body_of(args.items)
        data = session().call(args.path, body)
        if args.field:
            data = data.get(args.field) if isinstance(data, dict) else None
        print("" if data is None else data if isinstance(data, str) else json.dumps(data, ensure_ascii=False))
    else:
        session().upload(args.page_id, args.file.name, args.file.read_bytes(), args.type)


if __name__ == "__main__":
    run(main)
