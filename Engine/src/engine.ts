// Headless Docmost editor behind the native app: holds the Yjs document, syncs via Hocuspocus and runs the block
// operations the app calls on `window.DocmostEngine`. Events go to `webkit.messageHandlers.engine` as JSON strings.
import { Editor, getSchema, type JSONContent } from "@tiptap/core";
import { Node as PMNode } from "@tiptap/pm/model";
import Collaboration from "@tiptap/extension-collaboration";
import { initProseMirrorDoc } from "@tiptap/y-tiptap";
import { HocuspocusProvider, HocuspocusProviderWebsocket, WebSocketStatus } from "@hocuspocus/provider";
import * as Y from "yjs";
import { schemaExtensions } from "./schema";

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

type Target = { id?: string; path?: number[]; type?: string };
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
  private updateTimer?: number;
  private host?: HTMLElement;

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
        if (state) this.scheduleDocument(0);
      },
      onAuthenticationFailed: ({ reason }) => emit("authenticationFailed", { error: reason }),
      onAuthenticated: () => emit("authenticated"),
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
    if (this.updateTimer) window.clearTimeout(this.updateTimer);
    this.editor?.destroy();
    this.provider?.destroy();
    this.socket?.destroy();
    this.host?.remove();
    this.editor = undefined;
    this.provider = undefined;
    this.socket = undefined;
    this.host = undefined;
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

  /** Returns the document now, canceling the pending debounce. */
  flush(): JSONContent {
    if (this.updateTimer) {
      window.clearTimeout(this.updateTimer);
      this.updateTimer = undefined;
    }
    return this.getDocument();
  }

  // MARK: Block operations

  /** Replaces one block with one or more (e.g. unsyncing a synced block: its content replaces the wrapper). */
  replaceBlockWith(target: Target, json: JSONContent[]): boolean {
    return this.transact((editor) => {
      const found = this.locate(editor, target);
      if (!found) return false;
      const nodes = json.map((item) => PMNode.fromJSON(editor.schema, item));
      editor.view.dispatch(editor.state.tr.replaceWith(found.pos, found.pos + found.node.nodeSize, nodes));
      return true;
    });
  }

  /** Inserts one or more blocks in one step (e.g. a divider plus a paragraph to keep typing in). */
  insertBlocks(target: Target | null, json: JSONContent[], position: "before" | "after" = "after"): boolean {
    return this.transact((editor) => {
      const nodes = json.map((item) => PMNode.fromJSON(editor.schema, item));
      let pos: number;
      if (!target) {
        pos = editor.state.doc.content.size;
        // Insert before the footnotes, which always stay last.
        const last = editor.state.doc.lastChild;
        if (last && last.type.name === "footnotes") pos -= last.nodeSize;
      } else {
        const found = this.locate(editor, target);
        if (!found) return false;
        pos = position === "before" ? found.pos : found.pos + found.node.nodeSize;
      }
      editor.view.dispatch(editor.state.tr.insert(pos, nodes));
      return true;
    });
  }

  deleteBlock(target: Target): boolean {
    return this.transact((editor) => {
      const found = this.locate(editor, target);
      if (!found) return false;
      editor.view.dispatch(editor.state.tr.delete(found.pos, found.pos + found.node.nodeSize));
      return true;
    });
  }

  /** Moves a block before or after another block on the same level. */
  moveBlock(target: Target, destination: Target, position: "before" | "after"): boolean {
    return this.transact((editor) => {
      const source = this.locate(editor, target);
      const dest = this.locate(editor, destination);
      if (!source || !dest || source.pos === dest.pos) return false;
      const node = source.node;
      const tr = editor.state.tr.delete(source.pos, source.pos + node.nodeSize);
      const rawDest = position === "before" ? dest.pos : dest.pos + dest.node.nodeSize;
      const mapped = tr.mapping.map(rawDest, position === "before" ? -1 : 1);
      tr.insert(mapped, node);
      editor.view.dispatch(tr);
      return true;
    });
  }

  /** Splits a list, quote or callout after one of its children: the children below go into a new one of the same kind
   * right after it. */
  splitContainer(target: Target): boolean {
    return this.transact((editor) => {
      const found = this.locate(editor, target);
      if (!found) return false;
      const end = found.pos + found.node.nodeSize;
      const $end = editor.state.doc.resolve(end);
      // Only between two children.
      if ($end.index() === 0 || $end.index() >= $end.parent.childCount) return false;
      editor.view.dispatch(editor.state.tr.split(end));
      return true;
    });
  }

  setAttributes(target: Target, attrs: Record<string, unknown>): boolean {
    return this.transact((editor) => {
      const found = this.locate(editor, target);
      if (!found) return false;
      editor.view.dispatch(editor.state.tr.setNodeMarkup(found.pos, undefined, { ...found.node.attrs, ...attrs }));
      return true;
    });
  }

  undo(): boolean {
    return this.editor?.commands.undo() ?? false;
  }

  redo(): boolean {
    return this.editor?.commands.redo() ?? false;
  }

  // MARK: Internal

  /**
   * Binds the editor after the first sync. Its first render deletes whatever the schema can't hold (unknown types or
   * marks, content a newer Docmost allows in more places) and syncs that to the server, so the render runs on a copy
   * first; a page that would lose content closes the connection instead.
   */
  private attachEditor(): boolean {
    const ydoc = this.provider!.document;
    const copy = new Y.Doc();
    Y.applyUpdate(copy, Y.encodeStateAsUpdate(ydoc));
    let lossy = false;
    copy.on("update", () => (lossy = true));
    try {
      const { doc } = initProseMirrorDoc(copy.getXmlFragment("default"), getSchema(schemaExtensions));
      // Binding also fits the top level into the schema's order and drops what doesn't fit.
      if (doc.childCount > 0 && !doc.type.validContent(doc.content)) lossy = true;
    } catch {
      lossy = true; // Unreadable content (malformed Yjs) would make binding throw too.
    }
    if (lossy) {
      this.close();
      emit("unsupported", { error: "unsupported content" });
      return false;
    }
    // UniqueID adds missing block ids on the provider's "synced"; sync is done, so this stand-in fires it at once.
    const synced = { on: (_event: string, run: () => void) => run(), off() {} };
    this.editor = new Editor({
      element: this.host,
      editable: true,
      extensions: [...schemaExtensions, Collaboration.configure({ document: ydoc, provider: synced })],
      onUpdate: () => this.scheduleDocument(150),
    });
    return true;
  }

  private transact(operation: (editor: Editor) => boolean): boolean {
    if (!this.editor) {
      emit("error", { error: "engine not open" });
      return false;
    }
    try {
      const applied = operation(this.editor);
      if (applied) this.scheduleDocument(0);
      return applied;
    } catch (error) {
      emit("error", { error: String(error) });
      return false;
    }
  }

  /** Finds a block by its UniqueID (`attrs.id`) or its path (child indices from the root). */
  private locate(editor: Editor, target: Target): { node: PMNode; pos: number } | undefined {
    const doc = editor.state.doc;
    if (target.id) {
      let result: { node: PMNode; pos: number } | undefined;
      doc.descendants((node, pos) => {
        if (result) return false;
        if (node.attrs?.id === target.id) {
          result = { node, pos };
          return false;
        }
        return true;
      });
      if (result) return result;
    }
    if (target.path && target.path.length > 0) {
      let node: PMNode = doc;
      let pos = 0; // Position before the node; for the root, 0 = start of its content
      let first = true;
      for (const index of target.path) {
        if (index < 0 || index >= node.childCount) return undefined;
        let offset = first ? 0 : pos + 1;
        for (let i = 0; i < index; i++) offset += node.child(i).nodeSize;
        node = node.child(index);
        pos = offset;
        first = false;
      }
      // A path finds whatever sits there by now: after a collaborator's edit above, another block.
      if (target.type && node.type.name !== target.type) return undefined;
      return { node, pos };
    }
    return undefined;
  }

  private scheduleDocument(delay: number) {
    if (this.updateTimer) window.clearTimeout(this.updateTimer);
    this.updateTimer = window.setTimeout(() => {
      this.updateTimer = undefined;
      emit("document", { document: this.getDocument() });
    }, delay);
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

window.addEventListener("error", (event) => emit("error", { error: `uncaught: ${event.message}` }));
window.addEventListener("unhandledrejection", (event) => emit("error", { error: `unhandled rejection: ${String(event.reason)}` }));
window.DocmostEngine = new DocmostEngine();
emit("ready");
