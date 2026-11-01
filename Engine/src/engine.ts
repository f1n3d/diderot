// Headless Docmost editor behind the native app: holds the Yjs document, syncs via Hocuspocus and runs the block
// operations the app calls on `window.DocmostEngine`. Events go to `webkit.messageHandlers.engine` as JSON strings.
import { Editor, getSchema, type JSONContent } from "@tiptap/core";
import Collaboration from "@tiptap/extension-collaboration";
import { HocuspocusProvider, HocuspocusProviderWebsocket, WebSocketStatus } from "@hocuspocus/provider";
import * as Y from "yjs";
import { bindingChanges } from "./guards";
import { DocumentSchedule, documentDelay } from "./schedule";
import { editorOptions, schemaExtensions } from "./schema";
import { applySteps, locate, type Step, type Target } from "./steps";
import { runTableCommand, type TableCommand } from "./tables";

declare global {
  interface Window {
    DocmostEngine: DocmostEngine;
    webkit?: {
      messageHandlers?: {
        engine?: { postMessage(message: string): void };
        collabToken?: { postMessage(message: string): Promise<string | undefined> };
      };
    };
  }
}

type OpenOptions = {
  wsUrl: string;
  pageId: string;
  token: string;
  user?: { id: string; name: string; avatarUrl?: string | null; color?: string };
  /** Changes the server hadn't confirmed when the page last closed (see `unsentChanges`). */
  unsent?: string;
};

function emit(type: string, payload: Record<string, unknown> = {}) {
  const message = JSON.stringify({ type, ...payload });
  window.webkit?.messageHandlers?.engine?.postMessage(message);
}

class DocmostEngine {
  private socket?: HocuspocusProviderWebsocket;
  private provider?: HocuspocusProvider;
  private editor?: Editor;
  private readonly documents = new DocumentSchedule(
    { now: () => Date.now(), setTimeout: (run, ms) => window.setTimeout(run, ms), clearTimeout: (id) => window.clearTimeout(id) },
    () => emit("document", { document: this.getDocument() }),
  );
  private host?: HTMLElement;
  /** Set by `fail`: edits are refused from then on. */
  private failed = false;

  open(options: OpenOptions) {
    this.close();
    this.host = document.createElement("div");
    this.host.style.display = "none";
    document.body.appendChild(this.host);

    this.socket = new HocuspocusProviderWebsocket({ url: options.wsUrl, autoConnect: false });
    // The provider resends the token on every reconnect and collab tokens expire after 24 h, so from the second
    // connect on the app fetches a fresh one (keeping the last if it can't, e.g. offline).
    let token = options.token;
    let connects = 0;
    this.provider = new HocuspocusProvider({
      websocketProvider: this.socket,
      name: `page.${options.pageId}`,
      token: async () => {
        if (connects++ > 0) token = (await window.webkit?.messageHandlers?.collabToken?.postMessage("")) || token;
        return token;
      },
      onStatus: ({ status }) => emit("status", { status }),
      onSynced: ({ state }) => {
        if (state && !this.editor && !this.attachEditor()) return;
        emit("synced", { synced: state });
        if (state) this.documents.change(0);
      },
      onAuthenticationFailed: ({ reason }) => emit("authenticationFailed", { error: reason }),
      // "readonly" when the server lets the connection only read (a reader, a page in the trash).
      onAuthenticated: ({ scope }) => emit("authenticated", { scope }),
      // Docmost 0.97 tells a connection that lost write access, then ignores its updates.
      onStateless: ({ payload }) => {
        try {
          const message = JSON.parse(payload);
          if (message?.type === "page.permissions") emit("permissions", { access: message.access });
        } catch {}
      },
      onClose: ({ event }) => emit("closed", { code: event?.code, reason: event?.reason }),
    });
    // With the provider listening, so it counts them as unsent until the server confirms them; the sync sends them.
    if (options.unsent) Y.applyUpdate(this.provider.document, Uint8Array.from(atob(options.unsent), (char) => char.charCodeAt(0)));
    if (options.user) {
      this.provider.setAwarenessField("user", options.user);
    }
    this.provider.awareness?.on("change", () => this.emitAwareness());

    // With an explicit `websocketProvider` the provider doesn't attach itself (the web client's React component does).
    this.provider.attach();
    this.socket.connect();
    emit("opened");
  }

  close() {
    this.documents.cancel();
    this.editor?.destroy();
    this.provider?.destroy();
    this.socket?.destroy();
    this.host?.remove();
    this.editor = undefined;
    this.provider = undefined;
    this.socket = undefined;
    this.host = undefined;
    this.failed = false;
  }

  /**
   * An error once the editor is bound may leave it out of step with the shared document (the binding threw halfway), and
   * the next edit would write the editor's state over what others wrote. Refuses edits from then on; the app closes the
   * engine, keeping what the server hasn't confirmed, and opens it again.
   */
  fail(reason: string) {
    if (!this.editor || this.failed) return;
    this.failed = true;
    emit("failed", { error: reason });
  }

  /**
   * After up to 2 s for the server to confirm changes on their way: "" if it has them all, else the whole document as a
   * base64 Yjs update for the next `open` (a full state, which merges idempotently); undefined once the page is closed.
   */
  async unsentChanges(): Promise<string | undefined> {
    // A deadline, not a count of timeouts: timers in a page that is never shown may run late.
    const deadline = Date.now() + 2000;
    while (Date.now() < deadline && this.provider?.hasUnsyncedChanges && this.socket?.status === WebSocketStatus.Connected) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    if (!this.provider) return undefined;
    if (!this.provider.hasUnsyncedChanges) return "";
    return btoa(Array.from(Y.encodeStateAsUpdate(this.provider.document), (byte) => String.fromCharCode(byte)).join(""));
  }

  getDocument(): JSONContent {
    return this.editor?.getJSON() ?? { type: "doc", content: [] };
  }

  /** Returns the document now, canceling the pending document event. */
  flush(): JSONContent {
    this.documents.cancel();
    return this.getDocument();
  }

  // MARK: Block operations
  //
  // Each returns true when applied, false when refused (the block is gone, the change doesn't fit) and null when the
  // engine takes no edits (not open, or stopped after an error: `fail`); the app keeps input for null and sends it again
  // once the engine is back. The steps behind them are in src/steps.ts.

  /** Applies the steps in one transaction, all or none (src/steps.ts); a compound edit's steps go together. */
  batch(steps: Step[]): boolean | null {
    return this.transact((editor) => {
      const tr = editor.state.tr;
      if (!applySteps(tr, steps)) return false;
      editor.view.dispatch(tr);
      return true;
    });
  }

  /**
   * Replaces one block with one or more (e.g. unsyncing a synced block: its content replaces the wrapper). With `base`,
   * the text block the app's edit started from: a collaborator's edit since then stays (`rebase`). With `expected`, the
   * block a structural edit was built from (a list converted, columns changed): refused when the block changed since,
   * so the replacement doesn't overwrite what a collaborator typed meanwhile.
   */
  replaceBlockWith(target: Target, json: JSONContent[], base?: JSONContent | null, expected?: JSONContent | null): boolean | null {
    return this.batch([{ op: "replace", target, json, base, expected }]);
  }

  /** Inserts one or more blocks in one step (e.g. a divider plus a paragraph to keep typing in). */
  insertBlocks(target: Target | null, json: JSONContent[], position: "before" | "after" = "after"): boolean | null {
    return this.batch([{ op: "insert", target, json, position }]);
  }

  deleteBlock(target: Target): boolean | null {
    return this.batch([{ op: "delete", target }]);
  }

  /** Moves a block before or after another block on the same level. */
  moveBlock(target: Target, destination: Target, position: "before" | "after"): boolean | null {
    return this.batch([{ op: "move", target, destination, position }]);
  }

  /** Splits a list, quote or callout after one of its children: the children below go into a new one of the same kind
   * right after it. */
  splitContainer(target: Target): boolean | null {
    return this.batch([{ op: "split", target }]);
  }

  setAttributes(target: Target, attrs: Record<string, unknown>): boolean | null {
    return this.batch([{ op: "setAttributes", target, attrs }]);
  }

  /**
   * Runs a table command on a cell (row, index in the row) of the table at `target`, as the web's table menus do
   * (src/tables.ts). Returns the cell for the cursor afterwards the same way, [] when the table is gone, undefined when
   * the command didn't apply.
   */
  tableCommand(target: Target, cell: [number, number], command: TableCommand): number[] | undefined {
    let focus: number[] | undefined;
    this.transact((editor) => {
      const found = locate(editor.state.doc, target);
      if (!found) return false;
      const result = runTableCommand(editor.state, found.pos, cell, command);
      if (!result) return false;
      if (result.tr?.docChanged) editor.view.dispatch(result.tr);
      focus = result.focus ?? [];
      return true;
    });
    return focus;
  }

  /** False with nothing to undo (TipTap's Collaboration refuses an empty history). */
  undo(): boolean | null {
    return this.transact((editor) => editor.commands.undo());
  }

  redo(): boolean | null {
    return this.transact((editor) => editor.commands.redo());
  }

  // MARK: Internal

  /** Binds the editor after the first sync; a page that binding would change (`bindingChanges`) closes instead. */
  private attachEditor(): boolean {
    const ydoc = this.provider!.document;
    if (bindingChanges(ydoc, getSchema(schemaExtensions))) {
      this.close();
      emit("unsupported", { error: "unsupported content" });
      return false;
    }
    // UniqueID adds missing block ids on the provider's "synced"; sync is done, so this stand-in fires it at once.
    const synced = { on: (_event: string, run: () => void) => run(), off() {} };
    try {
      this.editor = new Editor({
        ...editorOptions,
        element: this.host,
        editable: true,
        extensions: [...schemaExtensions, Collaboration.configure({ document: ydoc, provider: synced })],
        onUpdate: () => this.documents.change(documentDelay),
      });
    } catch (error) {
      // Bound halfway at most: closed, and the app takes it for a start that failed.
      emit("error", { error: String(error) });
      this.close();
      emit("failed", { error: "editor didn't start" });
      return false;
    }
    return true;
  }

  /** Applied (true), refused (false) or no engine to take it (null), as the block operations above return. */
  private transact(operation: (editor: Editor) => boolean): boolean | null {
    if (!this.editor || this.failed) {
      emit("error", { error: this.editor ? "engine failed" : "engine not open" });
      return null;
    }
    const before = this.editor.state;
    try {
      const applied = operation(this.editor);
      if (applied) this.documents.change(0);
      return applied;
    } catch (error) {
      emit("error", { error: String(error) });
      // Thrown once the editor had taken the change: by the binding, while writing it into the shared document. The
      // engine takes no more edits then, and the app sends this one again once it is back.
      if (this.editor?.state !== before) {
        this.fail("change failed halfway");
        return null;
      }
      return false;
    }
  }

  private emitAwareness() {
    const states = this.provider?.awareness?.getStates();
    if (!states) return;
    const participants: unknown[] = [];
    const ownClient = this.provider?.document.clientID;
    states.forEach((state, clientId) => {
      if (clientId !== ownClient && state?.user) participants.push(state.user);
    });
    emit("awareness", { participants });
  }
}

// The binding applies the server's changes to the editor synchronously, so an exception from it arrives here; a rejected
// promise comes from the connection's own work (reconnecting, tokens) and leaves the editor as it was.
window.addEventListener("error", (event) => {
  emit("error", { error: `uncaught: ${event.message}` });
  window.DocmostEngine?.fail("uncaught error");
});
window.addEventListener("unhandledrejection", (event) => emit("error", { error: `unhandled rejection: ${String(event.reason)}` }));
window.DocmostEngine = new DocmostEngine();
emit("ready");
