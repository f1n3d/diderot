// The extension list of the Docmost server (`tiptapExtensions` in apps/server/src/collaboration/collaboration.util.ts),
// built from Docmost's own editor extensions in a Docmost checkout (see run.mjs --docmost). Development only: the
// observation tool runs it to record Docmost's format in spec/; nothing here goes into the app.
import { StarterKit } from "@tiptap/starter-kit";
import { createLowlight } from "lowlight";
import { Document } from "@tiptap/extension-document";
import { TextAlign } from "@tiptap/extension-text-align";
import { Superscript } from "@tiptap/extension-superscript";
import SubScript from "@tiptap/extension-subscript";
import { Typography } from "@tiptap/extension-typography";
import { TextStyle } from "@tiptap/extension-text-style";
import { Color } from "@tiptap/extension-color";
import { Youtube } from "@tiptap/extension-youtube";
import { TaskList, TaskItem } from "@tiptap/extension-list";
import { extensions as coreExtensions } from "@tiptap/core";
import { Heading } from "editor-ext/lib/heading/heading";
import { Callout } from "editor-ext/lib/callout";
import { Comment } from "editor-ext/lib/comment/comment";
import { CustomCodeBlock } from "editor-ext/lib/custom-code-block";
import { Details, DetailsContent, DetailsSummary } from "editor-ext/lib/details";
import { LinkExtension } from "editor-ext/lib/link";
import { MathBlock, MathInline } from "editor-ext/lib/math";
import { TableHeader, TableCell, TableRow, CustomTable } from "editor-ext/lib/table";
import { TiptapImage } from "editor-ext/lib/image";
import { TiptapVideo } from "editor-ext/lib/video";
import { TiptapAudio } from "editor-ext/lib/audio";
import { TiptapPdf } from "editor-ext/lib/pdf";
import { PageBreak } from "editor-ext/lib/page-break";
import { TrailingNode } from "editor-ext/lib/trailing-node";
import { Attachment } from "editor-ext/lib/attachment";
import { Drawio } from "editor-ext/lib/drawio";
import { Excalidraw } from "editor-ext/lib/excalidraw";
import { Embed } from "editor-ext/lib/embed";
import { Mention } from "editor-ext/lib/mention";
import { Subpages } from "editor-ext/lib/subpages";
import { Highlight } from "editor-ext/lib/highlight";
import { Indent } from "editor-ext/lib/indent";
import { UniqueID } from "editor-ext/lib/unique-id";
import { Columns, Column } from "editor-ext/lib/columns";
import { Status } from "editor-ext/lib/status";
import { TransclusionSource, TransclusionReference } from "editor-ext/lib/transclusion";
import { BaseEmbed } from "editor-ext/lib/base-embed";
import { Footnotes, Footnote, FootnoteReference } from "editor-ext/lib/footnotes";

export const docmostExtensions = [
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
  }),
  Comment,
  TextAlign.configure({ types: ["heading", "paragraph"] }),
  Indent,
  TaskList,
  TaskItem.configure({
    nested: true,
  }),
  LinkExtension,
  Superscript,
  SubScript,
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
  CustomTable,
  TableCell,
  TableRow,
  TableHeader,
  Youtube,
  TiptapImage,
  TiptapVideo,
  TiptapAudio,
  TiptapPdf,
  PageBreak,
  Callout,
  Attachment,
  // No grammars: nobody sees the highlighting here, but the code block's highlighting plugin needs a lowlight instance.
  CustomCodeBlock.configure({ lowlight: createLowlight() }),
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
] as any[];
