// Checks the page's live connection (src/connection.ts) against a stand-in collab server over stand-in WebSockets: each
// connect's sync emits "synced", after a connection that ended with a close event and after one that died without
// notice, which the socket closes itself as WebKit gives no close event then. The app shows "Saved" only after
// "synced". Exits with 1 on any difference.
import * as Y from "yjs";
import { connection } from "../src/connection";

let differences = 0;

function expect(name: string, want: unknown, have: unknown) {
  if (JSON.stringify(want) === JSON.stringify(have)) return;
  differences++;
  console.log(`✗ ${name}\n  want: ${JSON.stringify(want)}\n  have: ${JSON.stringify(have)}`);
}

// Hocuspocus messages: the document's name, the message type and its fields, in lib0's encoding (numbers in 7-bit
// groups, strings and byte arrays after their length).
class Writer {
  private readonly bytes: number[] = [];

  uint(value: number) {
    while (value > 0x7f) {
      this.bytes.push(0x80 | (value & 0x7f));
      value = Math.floor(value / 128);
    }
    this.bytes.push(value);
    return this;
  }

  array(value: Uint8Array) {
    this.uint(value.length);
    this.bytes.push(...value);
    return this;
  }

  string(value: string) {
    return this.array(new TextEncoder().encode(value));
  }

  done() {
    return Uint8Array.from(this.bytes);
  }
}

class Reader {
  private position = 0;

  constructor(private readonly bytes: Uint8Array) {}

  uint() {
    let value = 0;
    for (let factor = 1; ; factor *= 128) {
      const byte = this.bytes[this.position++];
      value += (byte & 0x7f) * factor;
      if (byte < 0x80) return value;
    }
  }

  array() {
    const length = this.uint();
    this.position += length;
    return this.bytes.slice(this.position - length, this.position);
  }

  string() {
    return new TextDecoder().decode(this.array());
  }
}

// `MessageType` in @hocuspocus/provider, `AuthMessageType` in @hocuspocus/common, the sync steps in y-protocols.
const sync = 0;
const auth = 2;
const ping = 9;
const authenticated = 2;
const syncStep1 = 0;
const syncStep2 = 1;

type Listener = (event: unknown) => void;

/**
 * A WebSocket to the stand-in collab server, which authenticates any token, answers a sync with its document and pings
 * as Docmost's server does, so a connection that works stays open. `dies()` ends the connection without notice:
 * nothing goes through any more, and `close()` ends in no close event, as in WebKit (bug 247943). `ends()` ends it with
 * one, as when the server or the network closes it.
 */
class StandInSocket {
  static readonly opened: StandInSocket[] = [];
  static readonly document = new Y.Doc();

  readyState = 0;
  binaryType = "arraybuffer";
  private dead = false;
  private pings?: ReturnType<typeof setInterval>;
  private readonly listeners = new Map<string, Set<Listener>>();

  constructor(readonly url: string) {
    StandInSocket.opened.push(this);
    setTimeout(() => {
      this.readyState = 1;
      this.dispatch("open", {});
      this.pings = setInterval(() => this.answer(Uint8Array.of(ping)), 100);
    }, 1);
  }

  addEventListener(type: string, listener: Listener) {
    if (!this.listeners.has(type)) this.listeners.set(type, new Set());
    this.listeners.get(type)!.add(listener);
  }

  removeEventListener(type: string, listener: Listener) {
    this.listeners.get(type)?.delete(listener);
  }

  send(data: Uint8Array) {
    // A pong is the message type alone.
    if (this.dead || data.length === 1) return;
    const message = new Reader(Uint8Array.from(data));
    const name = message.string();
    const type = message.uint();
    if (type === auth) {
      this.answer(new Writer().string(name).uint(auth).uint(authenticated).string("read-write").done());
    } else if (type === sync && message.uint() === syncStep1) {
      const update = Y.encodeStateAsUpdate(StandInSocket.document, message.array());
      this.answer(new Writer().string(name).uint(sync).uint(syncStep2).array(update).done());
    }
  }

  close() {
    if (this.dead || this.readyState === 3) return;
    this.ends(1000);
  }

  dies() {
    this.dead = true;
    clearInterval(this.pings);
  }

  ends(code = 1006) {
    this.readyState = 3;
    clearInterval(this.pings);
    setTimeout(() => this.dispatch("close", { code, reason: "" }), 1);
  }

  private answer(message: Uint8Array) {
    setTimeout(() => {
      if (!this.dead && this.readyState === 1) this.dispatch("message", { data: message.buffer });
    }, 1);
  }

  private dispatch(type: string, event: unknown) {
    for (const listener of [...(this.listeners.get(type) ?? [])]) listener(event);
  }
}

async function until(condition: () => boolean, ms = 3000) {
  const deadline = Date.now() + ms;
  while (!condition() && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 5));
}

/**
 * The connection's events for `name`: "synced" for each sync, the code of each lost connection and close event. Once it
 * synced, `end` ends its connection; then it waits for the next sync.
 */
async function events(end: (socket: StandInSocket) => void): Promise<string[]> {
  const seen: string[] = [];
  const synced = () => seen.filter((event) => event === "synced").length;
  // A connection counts as dead after 300 ms without a message, the socket's own check runs every 30 ms; reconnects
  // after 10 ms. In the engine: 30 s, 3 s and 1 s.
  const { socket, provider } = connection(
    "ws://collab.test/collab",
    {
      name: "page.check",
      token: "token",
      onSynced: () => seen.push("synced"),
      onDisconnect: ({ event }) => seen.push(`lost ${event.code}`),
      onClose: ({ event }) => seen.push(`closed ${event.code}`),
    },
    { WebSocketPolyfill: StandInSocket, messageReconnectTimeout: 300, delay: 10, minDelay: 10, maxDelay: 100 },
  );
  provider.attach();
  socket.connect();
  await until(() => synced() === 1);
  end(StandInSocket.opened.at(-1)!);
  await until(() => synced() === 2);
  provider.destroy();
  socket.destroy();
  return seen;
}

async function main() {
  expect("a connection that ended: synced again after the reconnect", ["synced", "lost 1006", "closed 1006", "synced"],
    await events((socket) => socket.ends()));
  // Before: ["synced", "lost 4408"], and the app said "Connecting" from then on.
  expect("a connection that died without notice: synced again after the reconnect", ["synced", "lost 4408", "synced"],
    await events((socket) => socket.dies()));
  console.log(differences > 0 ? `${differences} difference(s)` : "Each connect syncs again, also after a connection that died without notice.");
  // The provider's own timers would keep Node running.
  process.exit(differences > 0 ? 1 : 0);
}

main();
