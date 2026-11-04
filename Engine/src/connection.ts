// The page's live connection to Docmost's collab server (the provider in src/engine.ts).
import {
  HocuspocusProvider,
  HocuspocusProviderWebsocket,
  type CompleteHocuspocusProviderConfiguration,
  type CompleteHocuspocusProviderWebsocketConfiguration,
} from "@hocuspocus/provider";

export type ConnectionOptions = Partial<Omit<CompleteHocuspocusProviderConfiguration, "websocketProvider">> & { name: string };

/**
 * The provider for document `options.name` on a socket of its own to `url`, neither attached nor connected yet.
 * `socket` sets the socket's other options: none in the engine, short waits in tools/connection-check.ts.
 *
 * Every lost connection resets the provider as a close does (`onClose`: not synced, nobody else present). WebKit gives
 * no close event for a connection that died without notice (bug 247943), so the socket closes such a connection itself
 * once no message came for `messageReconnectTimeout` (its `checkConnection`). That close skipped the provider's reset:
 * it still counted as synced, the next connect's sync emitted no "synced", and the app said "Connecting" until the page
 * was opened again, e.g. after returning to the app on the iPhone. After a real close the provider resets itself once
 * more, which changes nothing.
 */
export function connection(url: string, options: ConnectionOptions, socket: Partial<CompleteHocuspocusProviderWebsocketConfiguration> = {}) {
  const websocket = new HocuspocusProviderWebsocket({ ...socket, url, autoConnect: false });
  const provider: HocuspocusProvider = new HocuspocusProvider({
    ...options,
    websocketProvider: websocket,
    onDisconnect: (data) => {
      provider.onClose();
      options.onDisconnect?.(data);
    },
  });
  return { socket: websocket, provider };
}
