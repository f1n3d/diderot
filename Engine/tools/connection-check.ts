// Checks the page's live connection (src/connection.ts) against a stand-in collab server over stand-in WebSockets: each
// connect's sync emits "synced", after a connection that ended with a close event and after one that died without
// notice, which the socket closes itself as WebKit gives no close event then. The app shows "Saved" only after
// "synced". A connection that holds the page's changes (`ChangeHold`) sends none until its connect is released, and
// each reconnect holds again; it holds back only changes the server hasn't confirmed, each release still gives the
// server back changes it confirmed and lost, and the provider counts each change until the server confirms it. Exits
// with 1 on any difference.
import * as Y from "yjs";
import { ChangeHold, connection } from "../src/connection";

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
const syncUpdate = 2;
const syncStatus = 8;

type Listener = (event: unknown) => void;

/**
 * A WebSocket to the stand-in collab server, which authenticates any token, answers a sync with its document, asks back
 * for what it lacks, takes changes and confirms them, and pings, as Docmost's server does, so a connection that works
 * stays open. `dies()` ends the connection without notice:
 * nothing goes through any more, and `close()` ends in no close event, as in WebKit (bug 247943). `ends()` ends it with
 * one, as when the server or the network closes it. After `deafens()` what the page sends is lost and what the server
 * sent still arrives, as when the connection breaks on the way to the server with its answers already on their way.
 */
class StandInSocket {
  static readonly opened: StandInSocket[] = [];
  /** The server's document for each name. */
  static readonly documents = new Map<string, Y.Doc>();

  static document(name: string) {
    if (!this.documents.has(name)) this.documents.set(name, new Y.Doc());
    return this.documents.get(name)!;
  }

  readyState = 0;
  binaryType = "arraybuffer";
  private dead = false;
  private deaf = false;
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
    if (this.dead || this.deaf || data.length === 1) return;
    const message = new Reader(Uint8Array.from(data));
    const name = message.string();
    const type = message.uint();
    if (type === auth) {
      this.answer(new Writer().string(name).uint(auth).uint(authenticated).string("read-write").done());
    } else if (type === sync) {
      const document = StandInSocket.document(name);
      const step = message.uint();
      if (step === syncStep1) {
        const update = Y.encodeStateAsUpdate(document, message.array());
        this.answer(new Writer().string(name).uint(sync).uint(syncStep2).array(update).done());
        this.answer(new Writer().string(name).uint(sync).uint(syncStep1).array(Y.encodeStateVector(document)).done());
      } else if (step === syncStep2 || step === syncUpdate) {
        Y.applyUpdate(document, message.array());
        // Applied: lib0's signed 1 is the same byte as the unsigned one.
        this.answer(new Writer().string(name).uint(syncStatus).uint(1).done());
      }
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

  deafens() {
    this.deaf = true;
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
  while (!condition() && Date.now() < deadline) await pause(5);
}

function pause(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
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

/**
 * A connection to document `name` that holds the page's changes (`ChangeHold`), and what it saw: "synced" for each
 * sync, and for each `state` what reached the stand-in server's document, whether changes stay back and how many the
 * provider counts as on their way. `changed` runs when `withheld` changes, `token` as the connection signs in.
 */
function holding(name: string, { changed, token }: { changed?: (hold: ChangeHold) => void; token?: () => string } = {}) {
  const seen: string[] = [];
  const hold: ChangeHold = new ChangeHold(() => changed?.(hold));
  const { socket, provider } = connection(
    "ws://collab.test/collab",
    { name, token: token ?? "token", onSynced: () => seen.push("synced") },
    { WebSocketPolyfill: StandInSocket, messageReconnectTimeout: 300, delay: 10, minDelay: 10, maxDelay: 100 },
    hold,
  );
  const server = () => StandInSocket.document(name).getText("t").toString();
  return {
    hold,
    provider,
    text: provider.document.getText("t"),
    state: (step: string) =>
      seen.push(`${step}: server "${server()}", withheld ${hold.withheld}, unsynced ${provider.unsyncedChanges}`),
    /** Until the server has `part` and the provider counts nothing on its way. */
    has: (part: string) => until(() => server().includes(part) && !provider.hasUnsyncedChanges),
    start: () => {
      provider.attach();
      socket.connect();
    },
    end: () => {
      provider.destroy();
      socket.destroy();
      return seen;
    },
  };
}

/**
 * What reached the stand-in server's document when, on a connection that holds the page's changes (`ChangeHold`): one
 * kept from before the connect ("offline"), one made while the connect holds ("held"), one right after its release
 * while the sync it starts runs ("quick"), one after that ("live"), one while the connection is down ("down"), released
 * after the reconnect.
 */
async function held(): Promise<string[]> {
  const { hold, provider, text, state, has, start, end } = holding("page.held");
  text.insert(0, "offline ");
  start();
  await until(() => provider.synced);
  await pause(50);
  state("connected");
  text.insert(text.length, "held ");
  await pause(50);
  state("changed while it holds");
  hold.release(hold.connects, provider);
  text.insert(text.length, "quick ");
  await has("quick");
  state("released");
  text.insert(text.length, "live ");
  await has("live");
  state("changed after the release");
  StandInSocket.opened.at(-1)!.ends();
  text.insert(text.length, "down ");
  await until(() => hold.connects === 2 && provider.synced);
  // The first connect's release, late, changes nothing.
  hold.release(1, provider);
  await pause(50);
  state("reconnected");
  hold.release(2, provider);
  await has("down");
  state("released again");
  return end();
}

/** A page without changes of its own on a connection that holds them, connected and then reconnected. */
async function unchanged(): Promise<string[]> {
  StandInSocket.document("page.unchanged").getText("t").insert(0, "theirs ");
  const { hold, provider, state, start, end } = holding("page.unchanged");
  start();
  await until(() => provider.synced);
  await pause(50);
  state("connected");
  hold.release(hold.connects, provider);
  StandInSocket.opened.at(-1)!.ends();
  await until(() => hold.connects === 2 && provider.synced);
  await pause(50);
  state("reconnected");
  return end();
}

/**
 * Changes that never reach the server: one made on a released connect whose connection has died without notice, and
 * the sync after the next connect's release, which carries it, as the connection breaks on its way.
 */
async function lost(): Promise<string[]> {
  let losesSync = false;
  const page = holding("page.lost", {
    changed: (hold) => {
      // As the sync's answer goes out.
      if (losesSync && !hold.withheld) StandInSocket.opened.at(-1)!.deafens();
    },
  });
  const { hold, provider, text, state, has, start, end } = page;
  start();
  await until(() => provider.synced);
  hold.release(hold.connects, provider);
  await pause(50);
  StandInSocket.opened.at(-1)!.dies();
  text.insert(text.length, "lost ");
  await until(() => hold.connects === 2 && provider.synced);
  await pause(50);
  state("reconnected");
  losesSync = true;
  hold.release(2, provider);
  await pause(50);
  state("released, its sync lost");
  losesSync = false;
  StandInSocket.opened.at(-1)!.ends();
  await until(() => hold.connects === 3 && provider.synced);
  await pause(50);
  state("reconnected again");
  hold.release(3, provider);
  await has("lost");
  state("released again");
  return end();
}

/**
 * A connect released before the server confirmed its empty answer, so that confirmation arrives after the sync the
 * release starts has set the provider's count to 1. A change made right after that sync's answer went out never
 * reaches the server, which confirms the answer: the provider then counts nothing on its way.
 */
async function lostAfterEarlyRelease(): Promise<string[]> {
  let step = 0;
  const page = holding("page.early", {
    changed: (hold) => {
      if (step === 0 && hold.withheld) {
        step = 1;
        // After the empty answer went out, before the server's confirmation of it comes in.
        queueMicrotask(() => hold.release(hold.connects, page.provider));
      } else if (step === 1 && !hold.withheld) {
        step = 2;
        queueMicrotask(() => {
          StandInSocket.opened.at(-1)!.deafens();
          page.text.insert(page.text.length, "lost ");
        });
      }
    },
  });
  const { hold, provider, text, state, has, start, end } = page;
  text.insert(0, "offline ");
  start();
  await until(() => step === 2 && !provider.hasUnsyncedChanges);
  state("confirmed");
  StandInSocket.opened.at(-1)!.ends();
  await until(() => hold.connects === 2 && provider.synced);
  await pause(50);
  state("reconnected");
  hold.release(2, provider);
  await has("lost");
  state("released");
  return end();
}

/**
 * A change made on a released connect whose connection has died without notice, and one made on the next connect,
 * released before the connection signed in. The server confirms the second, which it keeps aside until it has the first
 * that it builds on, before the page answered its sync, the answer that would carry the first; the connection breaks
 * before that answer goes.
 */
async function releasedBeforeTheSync(): Promise<string[]> {
  let releasesEarly = false;
  const page = holding("page.before", {
    token: () => {
      if (releasesEarly) {
        releasesEarly = false;
        page.hold.release(page.hold.connects, page.provider);
        page.text.insert(page.text.length, "early ");
        // The server gets neither the token nor the sync that follow.
        StandInSocket.opened.at(-1)!.deafens();
      }
      return "token";
    },
  });
  const { hold, provider, text, state, has, start, end } = page;
  start();
  await until(() => provider.synced);
  hold.release(hold.connects, provider);
  await pause(50);
  StandInSocket.opened.at(-1)!.dies();
  text.insert(text.length, "lost ");
  releasesEarly = true;
  await until(() => hold.connects === 2);
  await pause(50);
  state("the second confirmed");
  StandInSocket.opened.at(-1)!.ends();
  await until(() => hold.connects === 3 && provider.synced);
  await pause(50);
  state("reconnected");
  hold.release(3, provider);
  await has("lost");
  state("released");
  return end();
}

/**
 * A change the server confirmed and then lost, as when Docmost's collab server ends abruptly before it stored the page:
 * it confirms a change once it has it in memory and stores the page seconds later. The change is typed right after the
 * first connect's release, while the sync it starts runs; the page reconnects, and that connect is released too.
 */
async function forgotten(): Promise<string[]> {
  const { hold, provider, text, state, has, start, end } = holding("page.forgotten");
  start();
  await until(() => provider.synced);
  await pause(50);
  hold.release(hold.connects, provider);
  text.insert(0, "confirmed ");
  await has("confirmed");
  state("confirmed");
  // The server starts again from what it stored, without the change.
  StandInSocket.documents.set("page.forgotten", new Y.Doc());
  StandInSocket.opened.at(-1)!.ends();
  await until(() => hold.connects === 2 && provider.synced);
  await pause(50);
  state("reconnected");
  hold.release(2, provider);
  await has("confirmed");
  state("released");
  return end();
}

async function main() {
  expect("a connection that ended: synced again after the reconnect", ["synced", "lost 1006", "closed 1006", "synced"],
    await events((socket) => socket.ends()));
  // Before: ["synced", "lost 4408"], and the app said "Connecting" from then on.
  expect("a connection that died without notice: synced again after the reconnect", ["synced", "lost 4408", "synced"],
    await events((socket) => socket.dies()));
  // Before, the count stayed at 1 from "released" on: the provider counted "quick" when the sync after the release
  // was on its way, and the server confirms that sync once for all it carries.
  expect("a connection that holds the page's changes: none goes before its connect's release, and each connect holds", [
    "synced",
    'connected: server "", withheld true, unsynced 0',
    'changed while it holds: server "", withheld true, unsynced 1',
    'released: server "offline held quick ", withheld false, unsynced 0',
    'changed after the release: server "offline held quick live ", withheld false, unsynced 0',
    "synced",
    'reconnected: server "offline held quick live ", withheld true, unsynced 0',
    'released again: server "offline held quick live down ", withheld false, unsynced 0',
  ], await held());
  // Before, withheld was true on each connect: its answer to the server's sync stayed back, empty or not.
  expect("a page without changes of its own: nothing stays back on a connect or a reconnect", [
    "synced",
    'connected: server "theirs ", withheld false, unsynced 0',
    "synced",
    'reconnected: server "theirs ", withheld false, unsynced 0',
  ], await unchanged());
  expect("a change that never reached the server: each connect keeps it back until the server confirmed it", [
    "synced",
    "synced",
    'reconnected: server "", withheld true, unsynced 0',
    'released, its sync lost: server "", withheld false, unsynced 1',
    "synced",
    'reconnected again: server "", withheld true, unsynced 0',
    'released again: server "lost ", withheld false, unsynced 0',
  ], await lost());
  // The provider's count, 0 at "confirmed", doesn't tell that the server has the page's changes.
  expect("a change lost after an early release, while the provider counts nothing on its way: it goes after the next release", [
    "synced",
    'confirmed: server "offline ", withheld false, unsynced 0',
    "synced",
    'reconnected: server "offline ", withheld true, unsynced 0',
    'released: server "offline lost ", withheld false, unsynced 0',
  ], await lostAfterEarlyRelease());
  expect("a change confirmed before the sync's answer went: the next connect still keeps back the one the answer carries", [
    "synced",
    "synced",
    'the second confirmed: server "", withheld false, unsynced 0',
    "synced",
    'reconnected: server "", withheld true, unsynced 0',
    'released: server "lost early ", withheld false, unsynced 0',
  ], await releasedBeforeTheSync());
  // The page's answer to the server's sync is empty while the connect holds, as the page has no changes the server
  // hasn't confirmed; only the full answer after the release gives the server back what it lost.
  expect("a change the server confirmed and lost: the sync after a connect's release sends it again", [
    "synced",
    'confirmed: server "confirmed ", withheld false, unsynced 0',
    "synced",
    'reconnected: server "", withheld false, unsynced 0',
    'released: server "confirmed ", withheld false, unsynced 0',
  ], await forgotten());
  console.log(differences > 0 ? `${differences} difference(s)`
    : "Each connect syncs again, also after a connection that died without notice; a held connection sends nothing before its release, and holds back only changes the server hasn't confirmed.");
  // The provider's own timers would keep Node running.
  process.exit(differences > 0 ? 1 : 0);
}

main();
