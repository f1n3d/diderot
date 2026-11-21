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
    onDisconnect: (data) => {
      provider.onClose();
      options.onDisconnect?.(data);
    },
  });
  if (hold) {
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
 * could ask.
 */
export class ChangeHold {
  /** Connects so far: each one holds until `release` names it. */
  connects = 0;
  private released = 0;
  private kept = false;
  private resyncing = false;

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

  /**
   * What goes out for `message` on a socket that is `open` or not: the message itself, an empty answer to the server's
   * sync, or nothing (null).
   */
  pass(message: Uint8Array, open: boolean, provider: HocuspocusProvider): Uint8Array | null {
    const sync = syncOf(message);
    if (!sync || (sync.step !== syncStep2 && sync.step !== syncUpdate)) return message;
    if (open && !this.holds) {
      if (this.kept && sync.step === syncUpdate) {
        // It may build on a change that stayed back: the sync sends them all, this one with them.
        this.resync(provider);
        return null;
      }
      this.resyncing = false;
      this.keep(false);
      return message;
    }
    this.resyncing = false;
    this.keep(true);
    // An empty answer completes the server's sync: the connection then syncs as a reader's.
    return open && sync.step === syncStep2 ? emptyAnswer(message.subarray(0, sync.nameEnd)) : null;
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
  const reader = { bytes: message, at: 0 };
  const nameLength = readUint(reader);
  const nameEnd = reader.at + nameLength;
  reader.at = nameEnd;
  if (readUint(reader) !== MessageType.Sync) return null;
  return { step: readUint(reader), nameEnd };
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
