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
    Tools/dev_api.py dev-password alex@docmost.local          # a dev user's password, for a script's variable

`key=value` sends a string, `key:=value` a JSON value (a number, null, a list …), as in HTTPie. The calls sign in as
DOCMOST_API_EMAIL / DOCMOST_API_PASSWORD if set (Tools/run-uitests.sh sets them to the user its tests sign in as),
else as the admin from .env; DOCMOST_SEED_URL picks the server (default http://localhost:3000). Plain http:// is taken
for this Mac only, and redirects aren't followed: urllib would send the token along to wherever they point.

The users the tools create (the UI tests' colleague, the demo people) have passwords derived from the admin's in .env
(`dev_password`): the dev instance listens on every interface for tests on a device, so a password written in this
repository would let anyone on the network sign in as them.
"""
import argparse
import base64
import hashlib
import hmac
import json
import mimetypes
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOKENS = ROOT / "Tools/.cache/dev-tokens.json"
# The servers and users whose fixed password `replace_fixed_password` found gone: ["<server>|<email>"]. Lost, it costs
# one sign-in per server and user to find out again.
REPLACED = ROOT / "Tools/.cache/dev-fixed-passwords-gone.json"
# Where the shell tools kept a token before, readable by every user of this Mac; removed when found.
LEGACY_TOKEN = ROOT / "Tools/.cache/seed-token.txt"
# The passwords these users had before `dev_password`, written in this repository: `replace_fixed_password` replaces
# one where it is still set.
FIXED_PASSWORDS = {
    "kollegin@docmost.local": "kollegin-dev-123",
    "alex@docmost.local": "alex-dev-123",
    "sam@docmost.local": "sam-dev-123",
}
LOCAL_HOSTS = ("localhost", "127.0.0.1", "::1")


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
    return checked_url(os.environ.get("DOCMOST_SEED_URL", "http://localhost:3000"))


def is_local(url):
    """Whether the address is one of this Mac's."""
    return urllib.parse.urlsplit(url).hostname in LOCAL_HOSTS


def checked_url(url):
    """The server's address without a trailing slash. Stops for plain http:// to another machine, which would carry
    passwords and tokens unencrypted."""
    url = url.rstrip("/")
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        sys.exit(f"{url} is no http(s) address")
    if parts.scheme == "http" and not is_local(url):
        sys.exit(f"{url} would carry passwords and tokens unencrypted: use https:// (plain http only for localhost)")
    return url


class RefuseRedirects(urllib.request.HTTPRedirectHandler):
    """urllib follows a 301, 302 or 303 with the request's headers, the token among them, to any host. Refused instead:
    the redirect comes back as an HTTPError with its status."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OPENER = urllib.request.build_opener(RefuseRedirects)


def redirect_detail(error):
    """What to say about a refused redirect (an HTTPError with a 3xx status)."""
    return f"redirects to {error.headers.get('Location')}, which isn't followed: use that address"


class ApiError(Exception):
    """An answer other than 2xx (`status`), or none at all (`status` None)."""

    def __init__(self, path, status, detail):
        super().__init__(f"{path} → HTTP {status}: {detail[:300]}" if status else f"{path}: {detail}")
        self.path = path
        self.status = status


class Api:
    """POSTs to one server's API as one user."""

    def __init__(self, url=None, token=None, credentials=None, cache=False):
        self.url = checked_url(url) if url else base_url()
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
            with OPENER.open(request) as response:
                payload = json.loads(response.read() or b"{}")
                cookies = response.headers.get_all("Set-Cookie") or []
        except urllib.error.HTTPError as error:
            if 300 <= error.code < 400:
                raise ApiError(path, error.code, redirect_detail(error)) from None
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
    write_private(TOKENS, tokens)


def write_private(path, value):
    """Writes `value` as JSON, readable by this user only from the first byte: mkstemp makes the file 0600, and the move
    keeps that."""
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.stem}-")
    try:
        with os.fdopen(descriptor, "w") as file:
            json.dump(value, file)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


# The dev users' passwords.

def dev_password(email):
    """The password of a dev user the tools create, derived from the admin's password in .env: this developer's own,
    the same on every dev instance (the 0.97 one is a copy of the first), and nothing kept that could go missing."""
    _, secret = admin()
    digest = hmac.new(secret.encode(), f"diderot dev user {email.lower()}".encode(), hashlib.sha256).digest()
    return base64.urlsafe_b64encode(digest)[:24].decode()


def replace_fixed_password(email, url=None, again=False):
    """Gives the user `dev_password` on the server (default: DOCMOST_SEED_URL) if it still has its fixed password, and
    says whether it did. Each server is asked once, unless `again`: for a user who doesn't take its password, as after
    the dev data was restored from before. The sign-in's session stays (Docmost ends the user's other ones) and goes
    into the token cache."""
    email = email.lower()
    fixed = FIXED_PASSWORDS.get(email)
    if not fixed:
        return False
    api = Api(url)
    key = token_key(api.url, email)
    gone = load_replaced()
    if key in gone and not again:
        return False
    replaced = False
    try:
        api.sign_in(email, fixed)
    except ApiError as error:
        if error.status != 401:
            raise
    else:
        api.call("auth/change-password", {"oldPassword": fixed, "newPassword": dev_password(email)})
        store_token(api.url, email, api.token)
        print(f"Replaced the fixed password of {email} on {api.url}", file=sys.stderr)
        replaced = True
    if key not in gone:
        write_private(REPLACED, sorted(gone | {key}))
    return replaced


def load_replaced():
    try:
        gone = json.loads(REPLACED.read_text())
    except (OSError, ValueError):
        return set()
    return {key for key in gone if isinstance(key, str)} if isinstance(gone, list) else set()


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
    password = commands.add_parser("dev-password", help="print the password of a dev user the tools create, for a script's variable")
    password.add_argument("email")
    args = parser.parse_args()

    if args.command == "setting":
        print(settings().get(args.key, ""))
    elif args.command == "dev-password":
        replace_fixed_password(args.email)
        print(dev_password(args.email))
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
