// Docmost's own node and mark types and the changes its web editor makes to documents on its own, as TipTap
// extensions. Written from FORMAT.md and spec/, on TipTap's MIT extensions; `pnpm run check` compares them with
// Docmost's editor. The engine's editor is never shown, so nodes render as plain elements.
import { Extension, Mark, Node, mergeAttributes, type Attribute, type NodeConfig } from "@tiptap/core";
import { Plugin, PluginKey, type EditorState, type Transaction } from "@tiptap/pm/state";
import { Fragment, type Node as PMNode, type Slice } from "@tiptap/pm/model";
import { ReplaceAroundStep, ReplaceStep } from "@tiptap/pm/transform";
import { CodeBlock as TiptapCodeBlock } from "@tiptap/extension-code-block";
import { Highlight as TiptapHighlight } from "@tiptap/extension-highlight";
import { Link as TiptapLink } from "@tiptap/extension-link";
import { TableCell as TiptapTableCell, TableHeader as TiptapTableHeader } from "@tiptap/extension-table";
import { customAlphabet } from "nanoid";

/** New block ids: 12 random lowercase letters. */
export const newBlockId = customAlphabet("abcdefghijklmnopqrstuvwxyz", 12);

const required: Partial<Attribute> = { isRequired: true };

/**
 * A node type with its schema fields and attributes, in the order they appear in the JSON: a default value each
 * (`undefined`: none, so the attribute stays out of the JSON until set), or `required`.
 */
function docmostNode(name: string, fields: Partial<NodeConfig>, attributes: Record<string, unknown> = {}) {
  return Node.create({
    name,
    ...fields,
    addAttributes: () =>
      Object.fromEntries(Object.entries(attributes).map(([key, value]) => [key, value === required ? required : { default: value }])),
    renderHTML: ({ HTMLAttributes }) => [
      fields.inline ? "span" : "div",
      mergeAttributes({ "data-type": name }, HTMLAttributes),
      ...(fields.content ? [0] : []),
    ] as never,
  });
}

// MARK: Blocks

export const Callout = docmostNode("callout", { group: "block", content: "block+", defining: true, isolating: true }, { type: "info", icon: null });
export const Details = docmostNode("details", { group: "block", content: "detailsSummary detailsContent", defining: true, isolating: true }, { open: false });
export const DetailsSummary = docmostNode("detailsSummary", { group: "block", content: "inline*", selectable: false, defining: true, isolating: true });
export const DetailsContent = docmostNode("detailsContent", { group: "block", content: "block*", selectable: false, defining: true });
export const MathBlock = docmostNode("mathBlock", { group: "block", atom: true, isolating: true }, { text: "" });
export const PageBreak = docmostNode("pageBreak", { group: "block", atom: true, selectable: true });
export const Subpages = docmostNode("subpages", { group: "block", atom: true, draggable: true, isolating: true }, { sortBy: "default" });
export const Columns = docmostNode("columns", { group: "block", content: "column+", defining: true, isolating: true }, { layout: "two_equal", widthMode: "normal" });
export const Column = docmostNode("column", { group: "block", content: "block+", selectable: false, defining: true, isolating: true }, { width: null });
export const TransclusionSource = docmostNode("transclusionSource", {
  group: "block",
  content: "(paragraph | heading | blockquote | codeBlock | horizontalRule | bulletList | orderedList | taskList | image | video | audio | attachment | callout | details | embed | mathBlock | table | drawio | excalidraw | pdf | subpages | columns | youtube)+",
  defining: true,
  isolating: true,
});
export const TransclusionReference = docmostNode("transclusionReference", { group: "block", atom: true, selectable: true, draggable: false }, { sourcePageId: null, transclusionId: null });
export const BaseEmbed = docmostNode("base", { group: "block", atom: true, selectable: true, draggable: true }, { pageId: null, pendingKey: null });

// MARK: Tabs

/** Tabs, each with a label and a panel; tab ids follow the rules in FORMAT.md. */
export const Tabs = docmostNode("tabs", { group: "block", content: "tab+", defining: true, isolating: true }).extend({
  addProseMirrorPlugins: () => [
    // Docmost's view plugin only moves the selection into the tab that is shown; the engine has no view and edits by
    // position, so its stand-in leaves transactions alone.
    new Plugin({ key: new PluginKey("tabsView"), appendTransaction: () => null }),
    new Plugin({ key: new PluginKey("tabIds"), appendTransaction: (transactions, oldState, newState) => followTabIds(transactions, oldState, newState) }),
  ],
  onCreate() {
    // Once the editor shows the document, as Docmost's does: tabs without an id or with a taken one get new ids. Bound
    // to a page, the tab id rule has done that already; headless (the tools) there is nothing to show.
    setTimeout(() => {
      if (this.editor.isDestroyed || !this.editor.view.dom.isConnected) return;
      const tr = withUniqueTabIds(this.editor.state);
      if (tr) this.editor.view.dispatch(tr);
    });
  },
});
export const Tab = docmostNode("tab", { content: "tabLabel tabPanel", defining: true, isolating: true }, { id: "" });
export const TabLabel = docmostNode("tabLabel", { content: "inline*", selectable: false, defining: true });
export const TabPanel = docmostNode("tabPanel", { content: "block+" }).extend({
  extendNodeSchema: (extension) => (extension.name === "tabPanel" ? { definingAsContext: true } : {}),
});

/** The ids of the document's tabs, in document order. */
function tabIdsOf(doc: PMNode) {
  const ids: unknown[] = [];
  doc.descendants((node) => {
    if (node.type.name === "tab") ids.push(node.attrs.id);
  });
  return ids;
}

const sameIds = (a: unknown[], b: unknown[]) => a.length === b.length && a.every((id, index) => id === b[index]);

/** Whether content holds a tabs block or a tab, also as an open part of one (a split). */
function containsTabs(fragment: Fragment) {
  let found = false;
  fragment.descendants((node) => {
    found ||= node.type.name === "tab" || node.type.name === "tabs";
    return !found;
  });
  return found;
}

/**
 * Whether a step may have added, removed or moved tabs: a step that rebuilds a node around its content (any node),
 * one that inserts or removes content holding a tabs block or a tab (also splitting or joining tabs blocks), or one
 * that replaces the whole document (a page loading or another user's change) and so changes the order of the tab ids.
 * Attribute and mark steps don't count.
 */
function touchesTabs(tr: Transaction) {
  return tr.steps.some((step, index) => {
    if (step instanceof ReplaceAroundStep) return true;
    if (!(step instanceof ReplaceStep)) return false;
    const before = tr.docs[index];
    if (step.from === 0 && step.to === before.content.size) {
      return !sameIds(tabIdsOf(before), tabIdsOf(tr.docs[index + 1] ?? tr.doc));
    }
    return containsTabs(step.slice.content) || containsTabs(before.slice(step.from, step.to).content);
  });
}

/** After a change that may have touched tabs, every tab without an id or with a taken one gets a new id. */
function followTabIds(transactions: readonly Transaction[], _oldState: EditorState, newState: EditorState): Transaction | null {
  return transactions.some(touchesTabs) ? withUniqueTabIds(newState) : null;
}

/** New ids for tabs without one (empty or not a string) or with one an earlier tab has; null if all are fine. */
function withUniqueTabIds(state: EditorState): Transaction | null {
  const { tr } = state;
  const taken = new Set(tabIdsOf(state.doc));
  const seen = new Set<unknown>();
  state.doc.descendants((node, pos) => {
    if (node.type.name !== "tab") return;
    const id = node.attrs.id;
    if (typeof id === "string" && id !== "" && !seen.has(id)) {
      seen.add(id);
      return;
    }
    let fresh = newBlockId();
    while (taken.has(fresh)) fresh = newBlockId();
    taken.add(fresh);
    seen.add(fresh);
    tr.setNodeAttribute(pos, "id", fresh);
  });
  // Like the web editor's: the new ids aren't an edit of their own to undo.
  return tr.docChanged ? tr.setMeta("addToHistory", false) : null;
}

/** Second in the schema, after the paragraph. */
export const CodeBlock = TiptapCodeBlock.extend({ priority: 101, selectable: true, isolating: true });

// MARK: Tables

const cellContent = "(paragraph | heading | bulletList | orderedList | taskList | blockquote | callout | image | video | audio | subpages | attachment | mathBlock | details | codeBlock)+";
const cellAttributes = { align: { default: null }, backgroundColor: { default: null }, backgroundColorName: { default: null } };

export const TableCell = TiptapTableCell.extend({
  content: cellContent,
  addAttributes() {
    return { ...this.parent?.(), ...cellAttributes };
  },
});
export const TableHeader = TiptapTableHeader.extend({
  content: cellContent,
  addAttributes() {
    return { ...this.parent?.(), ...cellAttributes };
  },
});

// MARK: Files and embeds

const media = { group: "block", atom: true, defining: true, draggable: true, isolating: true };
const diagram = { src: "", title: undefined, alt: undefined, width: null, height: null, size: null, aspectRatio: null, align: "center", attachmentId: undefined };

export const Image = docmostNode("image", { ...media, inline: false }, {
  src: "", width: null, height: null, align: "center", alt: undefined, attachmentId: undefined, size: null, aspectRatio: null, placeholder: null,
});
export const Video = docmostNode("video", media, {
  src: "", alt: undefined, attachmentId: undefined, width: null, height: null, size: null, align: "center", aspectRatio: null, placeholder: null,
});
export const Audio = docmostNode("audio", media, { src: "", attachmentId: undefined, size: null, placeholder: null });
export const Pdf = docmostNode("pdf", media, { src: "", name: undefined, attachmentId: undefined, size: null, width: 800, height: 600, placeholder: null });
export const Attachment = docmostNode("attachment", { ...media, inline: false }, { url: "", name: undefined, mime: undefined, size: null, attachmentId: undefined, placeholder: null });
export const Drawio = docmostNode("drawio", { ...media, inline: false }, diagram);
export const Excalidraw = docmostNode("excalidraw", { ...media, inline: false }, diagram);
export const Embed = docmostNode("embed", { ...media, inline: false }, { src: "", provider: "", align: "center", width: 800, height: 600 });

// MARK: Inline nodes and marks

const inline = { group: "inline", inline: true, atom: true };

/** Third in the schema, after the code block. */
export const Mention = docmostNode("mention", { ...inline, priority: 101, selectable: true, draggable: true }, {
  id: null, label: null, entityType: null, entityId: null, slugId: null, creatorId: null, anchorId: null,
});
export const MathInline = docmostNode("mathInline", inline, { text: "" });
export const Status = docmostNode("status", { ...inline, selectable: true, draggable: true }, { text: "", color: "gray" });

export const Link = TiptapLink.extend({
  inclusive: false,
  addAttributes() {
    return { ...this.parent?.(), internal: { default: false }, integrationProvider: { default: null } };
  },
});
export const Highlight = TiptapHighlight.extend({
  addAttributes: () => ({ color: { default: null }, colorName: { default: null } }),
});
export const Comment = Mark.create({
  name: "comment",
  inclusive: false,
  addAttributes: () => ({ commentId: { default: null }, resolved: { default: false } }),
  renderHTML: ({ HTMLAttributes }) => ["span", HTMLAttributes, 0],
});

// MARK: Integrations

/** A link to an issue, pull request, design, … shown as a card or, inline, as a chip; `provider` names the service. */
export const IntegrationCard = docmostNode("integrationCard", { group: "block", inline: false, atom: true, draggable: true, defining: true, isolating: true }, { url: "", provider: "" });
export const IntegrationMention = docmostNode("integrationMention", { group: "inline", inline: true, atom: true, selectable: true, draggable: false }, { url: "", provider: "" });

// MARK: Footnotes

export const FootnoteReference = docmostNode("footnoteReference", { ...inline, draggable: true, content: "text*" }, {
  class: "footnote-ref", "data-id": null, referenceNumber: null, href: null,
});
export const Footnote = docmostNode("footnote", { content: "paragraph+", defining: true, isolating: true, draggable: false }, { id: required, "data-id": required });

/** The footnotes section follows the references; see FORMAT.md. */
const FootnoteRules = Extension.create({
  name: "footnoteRules",
  priority: 1000,
  addProseMirrorPlugins: () => [
    new Plugin({
      key: new PluginKey("footnoteRules"),
      appendTransaction: (transactions, _, state) => (transactions.some(movesReferences) ? followReferences(state) : null),
    }),
  ],
});

export const Footnotes = docmostNode("footnotes", { group: "", content: "footnote*", defining: true, isolating: true, draggable: false }, { class: "footnotes" })
  .extend({ addExtensions: () => [FootnoteRules] });

/**
 * Whether a transaction inserts or removes a footnote reference: one in inserted content, or one whose start or end
 * lies in a replaced range (a deletion across two references joins them). Typing inside a reference doesn't count.
 */
function movesReferences(tr: Transaction) {
  return tr.steps.some((step, index) => {
    let found = false;
    step.getMap().forEach((from, to) => {
      tr.docs[index].nodesBetween(from, to, (node, pos) => {
        const end = pos + node.nodeSize - 1;
        found ||= node.type.name === "footnoteReference" && ((pos >= from && pos < to) || (end >= from && end < to));
        return !found;
      });
    });
    (step as { slice?: Slice }).slice?.content.descendants((node) => {
      found ||= node.type.name === "footnoteReference";
      return !found;
    });
    return found;
  });
}

/** Numbers the references in document order and rebuilds the footnotes section to match; null if nothing changes. */
function followReferences(state: EditorState): Transaction | null {
  const { tr, schema } = state;
  const references: { node: PMNode; pos: number }[] = [];
  state.doc.descendants((node, pos) => {
    if (node.type.name === "footnoteReference") references.push({ node, pos });
  });
  // Attribute steps, which leave the blocks around them unchanged.
  references.forEach(({ node, pos }, index) => {
    if (node.attrs.referenceNumber !== String(index + 1)) tr.setNodeAttribute(pos, "referenceNumber", String(index + 1));
  });

  const doc = tr.doc;
  const section = doc.lastChild?.type.name === "footnotes" ? doc.lastChild : null;
  const start = doc.content.size - (section?.nodeSize ?? 0);
  if (references.length === 0) {
    if (section) tr.delete(start, doc.content.size);
  } else {
    // By `data-id`; the last footnote wins if several have it.
    const texts = new Map<unknown, Fragment>();
    section?.forEach((footnote) => texts.set(footnote.attrs["data-id"], footnote.content));
    const footnotes = Fragment.from(references.map(({ node }, index) =>
      schema.nodes.footnote.create(
        { id: `fn:${index + 1}`, "data-id": node.attrs["data-id"] },
        texts.get(node.attrs["data-id"]) ?? schema.nodes.paragraph.create(),
      ),
    ));
    // The section's content, not the section: a paragraph inserted before it isn't part of the change.
    if (!section) tr.insert(start, schema.nodes.footnotes.create(null, footnotes));
    else if (!section.content.eq(footnotes)) tr.replaceWith(start + 1, doc.content.size - 1, footnotes);
  }
  return tr.docChanged ? tr : null;
}

// MARK: Indentation and the trailing paragraph

const unindented = new Set(["listItem", "taskItem", "tableCell", "tableHeader"]);

/** Indentation steps on paragraphs and headings, none inside lists and tables; see FORMAT.md. */
export const Indent = Extension.create({
  name: "indent",
  priority: 1000,
  addGlobalAttributes: () => [{ types: ["paragraph", "heading"], attributes: { indent: { default: 0 } } }],
  addProseMirrorPlugins: () => [
    new Plugin({
      key: new PluginKey("indentNormalizer"),
      appendTransaction: (transactions, _, state) => {
        if (!transactions.some((tr) => tr.docChanged)) return null;
        const { tr } = state;
        state.doc.descendants((node, pos) => {
          if (!(node.attrs.indent > 0) || (node.type.name !== "paragraph" && node.type.name !== "heading")) return;
          const $pos = state.doc.resolve(pos);
          for (let depth = $pos.depth; depth > 0; depth--) {
            if (unindented.has($pos.node(depth).type.name)) {
              tr.setNodeMarkup(pos, undefined, { ...node.attrs, indent: 0 });
              return;
            }
          }
        });
        return tr.docChanged ? tr : null;
      },
    }),
  ],
});

/** Where the blocks end: before the footnotes section, if there is one. */
function endOfBlocks(doc: PMNode) {
  return doc.lastChild?.type.name === "footnotes" ? doc.content.size - doc.lastChild.nodeSize : doc.content.size;
}

const needsParagraph = (doc: PMNode) => doc.resolve(endOfBlocks(doc)).nodeBefore?.type.name !== "paragraph";

/** An empty paragraph after the last block when that isn't a paragraph; see FORMAT.md. */
export const TrailingNode = Extension.create({
  name: "trailingNode",
  addProseMirrorPlugins() {
    const key = new PluginKey<boolean>("trailingNode");
    return [
      new Plugin({
        key,
        state: {
          init: (_, state) => needsParagraph(state.doc),
          apply: (tr, needed) => (tr.docChanged ? needsParagraph(tr.doc) : needed),
        },
        appendTransaction: (_, __, state) =>
          key.getState(state) ? state.tr.insert(endOfBlocks(state.doc), state.schema.nodes.paragraph.create()) : null,
      }),
    ];
  },
});
