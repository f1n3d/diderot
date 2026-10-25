// The engine's extensions, in the order and with the options of the Docmost server's list (`tiptapExtensions` in
// apps/server/src/collaboration/collaboration.util.ts, see tools/docmost-reference.ts), so the schema matches the
// page's Yjs document. Docmost's own types come from extensions.ts (FORMAT.md), the rest from TipTap.
import { extensions as coreExtensions, type AnyExtension } from "@tiptap/core";
import { StarterKit } from "@tiptap/starter-kit";
import { Document } from "@tiptap/extension-document";
import { Heading } from "@tiptap/extension-heading";
import { TextAlign } from "@tiptap/extension-text-align";
import { Superscript } from "@tiptap/extension-superscript";
import { Subscript } from "@tiptap/extension-subscript";
import { Typography } from "@tiptap/extension-typography";
import { TextStyle } from "@tiptap/extension-text-style";
import { Color } from "@tiptap/extension-color";
import { Youtube } from "@tiptap/extension-youtube";
import { TaskList, TaskItem } from "@tiptap/extension-list";
import { Table, TableRow } from "@tiptap/extension-table";
import { UniqueID } from "@tiptap/extension-unique-id";
import {
  Attachment, Audio, BaseEmbed, Callout, CodeBlock, Column, Columns, Comment, Details, DetailsContent, DetailsSummary,
  Drawio, Embed, Excalidraw, Footnote, FootnoteReference, Footnotes, Highlight, Image, Indent, IntegrationCard,
  IntegrationMention, Link, MathBlock, MathInline, Mention, PageBreak, Pdf, Status, Subpages, Tab, TabLabel, TabPanel,
  Tabs, TableCell, TableHeader, TrailingNode, TransclusionReference, TransclusionSource, Video, newBlockId,
} from "./extensions";

export const schemaExtensions: AnyExtension[] = [
  coreExtensions.TextDirection.configure({ direction: "auto" }),
  StarterKit.configure({
    document: false,
    codeBlock: false,
    link: false,
    trailingNode: false,
    heading: false,
    // Undo/redo comes from the Collaboration extension (Yjs UndoManager).
    undoRedo: false,
  }),
  Document.extend({
    content: "block+ footnotes?",
  }),
  Heading,
  UniqueID.configure({
    types: ["heading", "paragraph", "transclusionSource"],
    generateID: () => newBlockId(),
  }),
  Comment,
  TextAlign.configure({ types: ["heading", "paragraph"] }),
  Indent,
  TaskList,
  TaskItem.configure({
    nested: true,
  }),
  Link,
  Superscript,
  Subscript,
  Highlight,
  Typography,
  TrailingNode,
  TextStyle,
  Color,
  MathInline,
  MathBlock,
  Details,
  DetailsContent,
  DetailsSummary,
  Tabs,
  Tab,
  TabLabel,
  TabPanel,
  Table,
  TableCell,
  TableRow,
  TableHeader,
  Youtube,
  Image,
  Video,
  Audio,
  Pdf,
  PageBreak,
  Callout,
  Attachment,
  CodeBlock,
  Drawio,
  Excalidraw,
  Embed,
  Mention,
  Subpages,
  Columns,
  Column,
  Status,
  TransclusionSource,
  TransclusionReference,
  BaseEmbed,
  Footnotes,
  Footnote,
  FootnoteReference,
  IntegrationCard,
  IntegrationMention,
];
