// The page's live connection to Docmost's collab server (the provider in src/engine.ts).
import {
  HocuspocusProvider,
  HocuspocusProviderWebsocket,
  MessageType,
  type CompleteHocuspocusProviderConfiguration,
  type CompleteHocuspocusProviderWebsocketConfiguration,
} from "@hocuspocus/provider";

export type ConnectionOptions = Partial<Omit<CompleteHocuspocusProviderConfiguration, "websocketProvider">> & { name: string };

/**
 * The provider for document `options.name` on a socket of its own to `url`, neither attached nor connected yet.
 * `socket` sets the socket's other options: none in the engine, short waits in tools/connection-check.ts. With `hold`,
 * the page's own changes go out only as it lets them (`ChangeHold`).
 *
 * Every lost connection resets the provider as a close does (`onClose`: not synced, nobody else present). WebKit gives
 * no close event for a connection that died without notice (bug 247943), so the socket closes such a connection itself
 * once no message came for `messageReconnectTimeout` (its `checkConnection`). That close skipped the provider's reset:
 * it still counted as synced, the next connect's sync emitted no "synced", and the app said "Connecting" until the page
 * was opened again, e.g. after returning to the app on the iPhone. After a real close the provider resets itself once
 * more, which changes nothing.
 */
export function connection(
  url: string,
  options: ConnectionOptions,
  socket: Partial<CompleteHocuspocusProviderWebsocketConfiguration> = {},
  hold?: ChangeHold,
) {
  const websocket = new HocuspocusProviderWebsocket({ ...socket, url, autoConnect: false });
  const provider: HocuspocusProvider = new HocuspocusProvider({
    ...options,
    websocketProvider: websocket,
    // Before the provider signs in and syncs: each connect holds from its start.
    onOpen: (data) => {
      hold?.connected();
      options.onOpen?.(data);
    },
    onAuthenticated: (data) => {
      options.onAuthenticated?.(data);
      hold?.authenticated(provider);
    },
    onMessage: (data) => {
      hold?.received(new Uint8Array(data.event.data as ArrayBuffer));
      options.onMessage?.(data);
    },
    onDisconnect: (data) => {
      provider.onClose();
      options.onDisconnect?.(data);
    },
  });
  if (hold) {
    // Every change but the server's, which the provider applies as their origin. In place before the engine applies the
    // changes the server hadn't confirmed when the page last closed, so those count too.
    provider.document.on("update", (_update: Uint8Array, origin: unknown) => {
      if (origin !== provider) hold.changedLocally();
    });
    const send = websocket.send.bind(websocket);
    websocket.send = (message: Uint8Array) => {
      const passed = hold.pass(message, websocket.webSocket?.readyState === 1, provider);
      if (passed) send(passed);
    };
  }
  return { socket: websocket, provider };
}

// The sync's messages in y-protocols' encoding: the second step answers the other side's state vector with what it
// lacks, an update carries a change as it is made. The first step, the state vector itself, changes nothing.
const syncStep2 = 1;
const syncUpdate = 2;

/**
 * Holds the page's own changes back from each connect until the app releases that connect (`release`). On Docmost 0.98
 * with page verification an edit of a verified or approved page takes the verification back, so after each connect the
 * app asks the server for the page's status before its changes go, as the web does (its collab socket's `send`, with
 * `usePageSyncPermission`). Meanwhile the connection syncs as a reader's would: the server's document and others'
 * changes come in, the page's own stay in its shared document, and the sync after `release` sends them all. Changes made
 * while the connection is down wait for the next connect the same way: queued, they would go out with it, before the app
 * could ask. A connect without such changes holds nothing back: the page's answer to the server's sync is empty then,
 * and nothing counts as withheld.
 */
export class ChangeHold {
  /** Connects so far: each one holds until `release` names it. */
  connects = 0;
  private released = 0;
  private kept = false;
  private resyncing = false;
  /**
   * The page has changes of its own the server may lack. Set by each; cleared once, on a connection whose answer to the
   * server's sync left it lacking none (`answered`), the server confirmed all that went out and nothing stayed back.
   */
  private ownChanges = false;
  /**
   * Changes that went out on this connection and that the server hasn't confirmed. Not the provider's count: a sync it
   * starts sets that to 1, and a confirmation of what went out before then takes it to 0 while the sync's answer is on
   * its way.
   */
  private awaiting = 0;
  /**
   * The answer to the server's sync on this connection left the server lacking none of the page's changes: the answer
   * carried them, or the server had them all. Before it, a change released early goes on its own, and its confirmation
   * says nothing of the changes the answer carries.
   */
  private answered = false;

  /** `changed` runs when `withheld` changes. */
  constructor(private readonly changed: () => void) {}

  /** Changes stayed back since the server last got the page's: the next sync sends them. */
  get withheld(): boolean {
    return this.kept;
  }

  /** The page's changes wait (the current connect isn't released). */
  get holds(): boolean {
    return this.released !== this.connects;
  }

  /** A connect started: it holds until released. */
  connected() {
    this.connects++;
    this.resyncing = false;
    // Confirmations come on the connection a change went out on.
    this.awaiting = 0;
    this.answered = false;
  }

  /** The page's changes may go out on connect `connect`, the current one; a later connect holds again. */
  release(connect: number, provider: HocuspocusProvider) {
    if (connect !== this.connects) return;
    this.released = connect;
    this.resync(provider);
  }

  /** The server took the connection's token: changes kept back on a released connect can go now. */
  authenticated(provider: HocuspocusProvider) {
    this.resync(provider);
  }

  /** The page's document changed, not by the server's sync. */
  changedLocally() {
    this.ownChanges = true;
  }

  /** The server sent `message`; a confirmation of a change it applied counts one off. */
  received(message: Uint8Array) {
    if (!confirms(message)) return;
    if (this.awaiting > 0) this.awaiting--;
    if (this.answered && this.awaiting === 0 && !this.kept) this.ownChanges = false;
  }

  /**
   * What goes out for `message` on a socket that is `open` or not: the message itself, an empty answer to the server's
   * sync, or nothing (null).
   */
  pass(message: Uint8Array, open: boolean, provider: HocuspocusProvider): Uint8Array | null {
    const sync = syncOf(message);
    if (!sync || (sync.step !== syncStep2 && sync.step !== syncUpdate)) return message;
    if (open && !this.holds) {
      if (this.kept && sync.step === syncUpdate) {
        // It may build on a change that stayed back: the sync sends them all, this one with them. The provider counted
        // this one as on its way, and the server confirms the sync once for all it carries. A sync that starts here, or
        // once the server took the token, sets the count to 1 anew; with one already on its way, the count goes back.
        if (this.resyncing) provider.decrementUnsyncedChanges();
        else this.resync(provider);
        return null;
      }
      this.resyncing = false;
      this.keep(false);
      if (sync.step === syncStep2) this.answered = true;
      this.awaiting++;
      return message;
    }
    this.resyncing = false;
    // An update is a change of the page's own; the answer to the server's sync holds one back only if the page has any.
    if (sync.step === syncUpdate || this.ownChanges) this.keep(true);
    if (!open || sync.step !== syncStep2) return null;
    // An empty answer completes the server's sync: the connection then syncs as a reader's. Without changes of the
    // page's own that the server lacks, the full answer would carry nothing more either.
    if (!this.ownChanges) this.answered = true;
    this.awaiting++;
    return emptyAnswer(message.subarray(0, sync.nameEnd));
  }

  private resync(provider: HocuspocusProvider) {
    if (this.holds || !this.kept || this.resyncing || !provider.isAuthenticated) return;
    this.resyncing = true;
    provider.forceSync();
  }

  private keep(kept: boolean) {
    if (kept === this.kept) return;
    this.kept = kept;
    this.changed();
  }
}

/** A sync message's step, and where its document's name ends; null for any other message. */
function syncOf(message: Uint8Array): { step: number; nameEnd: number } | null {
  // A ping's answer is its type alone, without a document's name.
  if (message.length <= 1) return null;
  const reader = afterName(message);
  const nameEnd = reader.at;
  if (readUint(reader) !== MessageType.Sync) return null;
  return { step: readUint(reader), nameEnd };
}

/** Whether the server's `message` confirms a change it applied: a sync status of 1 (lib0's signed 1 is that byte too). */
function confirms(message: Uint8Array): boolean {
  const reader = afterName(message);
  return readUint(reader) === MessageType.SyncStatus && readUint(reader) === 1;
}

/** A reader of `message` at its type, past its document's name. */
function afterName(message: Uint8Array): { bytes: Uint8Array; at: number } {
  const reader = { bytes: message, at: 0 };
  const nameLength = readUint(reader);
  reader.at += nameLength;
  return reader;
}

/** lib0's unsigned integer: 7 bits a byte, the low ones first; -1 where the message ends first. */
function readUint(reader: { bytes: Uint8Array; at: number }): number {
  let value = 0;
  for (let factor = 1; reader.at < reader.bytes.length; factor *= 128) {
    const byte = reader.bytes[reader.at++];
    value += (byte & 0x7f) * factor;
    if (byte < 0x80) return value;
  }
  return -1;
}

/** The answer to the server's sync of the document whose encoded name is `name` that sends nothing: an empty update. */
function emptyAnswer(name: Uint8Array): Uint8Array {
  return Uint8Array.of(...name, MessageType.Sync, syncStep2, 2, 0, 0);
}
