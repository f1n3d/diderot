// Docmost's own node and mark types and the changes its web editor makes to documents on its own, as TipTap
// extensions. Written from FORMAT.md and spec/, on TipTap's MIT extensions; `pnpm run check` compares them with
// Docmost's editor. The engine's editor is never shown, so nodes render as plain elements.
import { Extension, Mark, Node, mergeAttributes, type Attribute, type NodeConfig } from "@tiptap/core";
import { Plugin, PluginKey, type EditorState, type Transaction } from "@tiptap/pm/state";
import { Fragment, type Node as PMNode, type Slice } from "@tiptap/pm/model";
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
export const Subpages = docmostNode("subpages", { group: "block", atom: true, draggable: true, isolating: true });
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
    return { ...this.parent?.(), internal: { default: false } };
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
