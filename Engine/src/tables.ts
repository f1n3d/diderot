// Table commands of the app's keyboard toolbar, run on the cell being edited the way the web editor's table menus run
// them: prosemirror-tables' commands for rows, columns, header cells, merging, splitting and moving; sorting a column,
// clearing, cell colors and text alignment as Docmost's menus do them. Pure (a state in, a transaction out), so
// tools/table-check.ts runs them without an editor.
import type { Node as PMNode } from "@tiptap/pm/model";
import type { Command, EditorState, Transaction } from "@tiptap/pm/state";
import {
  CellSelection, TableMap, addColumnAfter, addColumnBefore, addRowAfter, addRowBefore, deleteColumn, deleteRow,
  mergeCells, moveTableColumn, moveTableRow, splitCell, toggleHeader, toggleHeaderCell,
} from "@tiptap/pm/tables";

/** The cells a format command changes: the cell, its row or its column (the web's cell menu and row/column handles). */
export type TableScope = "cell" | "row" | "column";

export type TableCommand =
  | { name: "addRowBefore" | "addRowAfter" | "addColumnBefore" | "addColumnAfter" | "deleteRow" | "deleteColumn" | "deleteTable" }
  | { name: "toggleHeaderRow" | "toggleHeaderColumn" | "toggleHeaderCell" | "mergeRight" | "mergeDown" | "split" }
  | { name: "moveRowUp" | "moveRowDown" | "moveColumnLeft" | "moveColumnRight" }
  | { name: "sort"; descending: boolean }
  | { name: "background"; scope: TableScope; color: string | null; colorName: string | null }
  | { name: "align"; scope: TableScope; align: "left" | "center" | "right" }
  | { name: "clear"; scope: TableScope };

/**
 * A command's changes (none when it changes nothing) and the cell for the cursor afterwards, as its row and its index
 * in that row; null when the table is gone (its only row or column deleted).
 */
export type TableResult = { tr?: Transaction; focus: [number, number] | null };

type Rect = { left: number; top: number; right: number; bottom: number };

/** Runs `command` on a cell (row, index in the row) of the table at `tablePos`; null when it doesn't apply. */
export function runTableCommand(state: EditorState, tablePos: number, cell: [number, number], command: TableCommand): TableResult | null {
  const table = state.doc.nodeAt(tablePos);
  if (!table || table.type.spec.tableRole !== "table") return null;
  const cellPos = positionOf(table, tablePos, cell);
  if (cellPos === undefined) return null;
  const map = TableMap.get(table);
  const tableStart = tablePos + 1;
  const rect: Rect = map.findCell(cellPos - tableStart);
  const original = state.doc.nodeAt(cellPos)!;

  // prosemirror-tables' commands act on the selection: the cell, or the cell and the neighbor to merge it with.
  const selecting = (head = cellPos) => state.apply(state.tr.setSelection(CellSelection.create(state.doc, cellPos, head)));
  const run = (apply: Command, on = selecting()): Transaction | undefined => {
    let result: Transaction | undefined;
    apply(on, (tr) => (result = tr));
    return result;
  };
  /** The cell covering a slot of the grid afterwards (the nearest one, if the grid got smaller) gets the cursor. */
  const at = (tr: Transaction | undefined, row: number, column: number): TableResult | null =>
    tr ? { tr, focus: cellAt(tr.doc.nodeAt(tablePos)!, row, column) } : null;
  /** The cell keeps the cursor wherever it went (a moved row or column, a sorted table). */
  const following = (tr: Transaction | undefined): TableResult | null => {
    if (!tr) return null;
    const after = tr.doc.nodeAt(tablePos)!;
    return { tr, focus: find(after, original) ?? cellAt(after, rect.top, rect.left) };
  };
  const deletingTable = (): TableResult => ({ tr: state.tr.delete(tablePos, tablePos + table.nodeSize), focus: null });
  /** A change of each cell of `scope`, from the last one back: clearing changes sizes, the positions before stay. */
  const eachCell = (scope: TableScope, change: (tr: Transaction, pos: number, node: PMNode) => void): TableResult => {
    const tr = state.tr;
    for (const pos of cellsIn(map, rect, scope).map((offset) => tableStart + offset).sort((a, b) => b - a)) {
      change(tr, pos, tr.doc.nodeAt(pos)!);
    }
    return { tr, focus: cell };
  };

  switch (command.name) {
    case "addRowBefore": return at(run(addRowBefore), rect.top, rect.left);
    case "addRowAfter": return at(run(addRowAfter), rect.bottom, rect.left);
    case "addColumnBefore": return at(run(addColumnBefore), rect.top, rect.left);
    case "addColumnAfter": return at(run(addColumnAfter), rect.top, rect.right);
    // Deleting the last row or column deletes the table, as the app always did (prosemirror-tables refuses).
    case "deleteRow": return rect.top === 0 && rect.bottom === map.height ? deletingTable() : at(run(deleteRow), rect.top, rect.left);
    case "deleteColumn": return rect.left === 0 && rect.right === map.width ? deletingTable() : at(run(deleteColumn), rect.top, rect.left);
    case "deleteTable": return deletingTable();
    // The web's: the first row or column (the corner stays a header cell while the other one is on); the cell itself.
    case "toggleHeaderRow": return at(run(toggleHeader("row")), rect.top, rect.left);
    case "toggleHeaderColumn": return at(run(toggleHeader("column")), rect.top, rect.left);
    case "toggleHeaderCell": return at(run(toggleHeaderCell), rect.top, rect.left);
    // The web merges the cells selected; the app has no cell selection, so a cell merges with its neighbor, and with
    // every cell the rectangle around both takes in. Refused when another cell would stick out of it.
    case "mergeRight":
    case "mergeDown": {
      const right = command.name === "mergeRight";
      if (right ? rect.right >= map.width : rect.bottom >= map.height) return null;
      const neighbor = map.map[right ? rect.top * map.width + rect.right : rect.bottom * map.width + rect.left];
      const merged = map.rectBetween(cellPos - tableStart, neighbor);
      return at(run(mergeCells, selecting(tableStart + neighbor)), merged.top, merged.left);
    }
    case "split": return at(run(splitCell), rect.top, rect.left);
    case "moveRowUp":
    case "moveRowDown": {
      const to = command.name === "moveRowUp" ? rect.top - 1 : rect.bottom;
      if (to < 0 || to >= map.height) return null;
      return following(run(moveTableRow({ from: rect.top, to, select: false, pos: cellPos + 1 })));
    }
    case "moveColumnLeft":
    case "moveColumnRight": {
      const to = command.name === "moveColumnLeft" ? rect.left - 1 : rect.right;
      if (to < 0 || to >= map.width) return null;
      return following(run(moveTableColumn({ from: rect.left, to, select: false, pos: cellPos + 1 })));
    }
    case "sort": {
      const sorted = sortedTable(table, rect.left, command.descending);
      if (!sorted) return null;
      if (sorted === table) return { focus: cell };
      return following(state.tr.replaceWith(tablePos, tablePos + table.nodeSize, sorted));
    }
    case "background": {
      const { color, colorName } = command;
      return eachCell(command.scope, (tr, pos, node) => {
        tr.setNodeMarkup(pos, undefined, { ...node.attrs, backgroundColor: color, backgroundColorName: color ? colorName : null });
      });
    }
    // As the web's `setTextAlign` on selected cells: every paragraph and heading in them, also in lists and quotes.
    case "align": {
      const { align } = command;
      return eachCell(command.scope, (tr, pos, node) => {
        node.descendants((child, offset) => {
          if (child.type.name !== "paragraph" && child.type.name !== "heading") return true;
          tr.setNodeMarkup(pos + 1 + offset, undefined, { ...child.attrs, textAlign: align });
          return false;
        });
      });
    }
    // As the web's: one empty paragraph in each cell, which keeps its color and width.
    case "clear":
      return eachCell(command.scope, (tr, pos, node) => {
        tr.replaceWith(pos + 1, pos + node.nodeSize - 1, state.schema.nodes.paragraph.create());
      });
  }
}

/** Position of a cell (row, index in the row) of the table at `tablePos`. */
function positionOf(table: PMNode, tablePos: number, [row, index]: [number, number]): number | undefined {
  if (row < 0 || row >= table.childCount) return undefined;
  const rowNode = table.child(row);
  if (index < 0 || index >= rowNode.childCount) return undefined;
  let pos = tablePos + 2;
  for (let r = 0; r < row; r++) pos += table.child(r).nodeSize;
  for (let i = 0; i < index; i++) pos += rowNode.child(i).nodeSize;
  return pos;
}

/** The cell covering a slot of the grid, or the nearest one, as row and index in the row. */
function cellAt(table: PMNode, row: number, column: number): [number, number] {
  const map = TableMap.get(table);
  const slot = Math.min(Math.max(row, 0), map.height - 1) * map.width + Math.min(Math.max(column, 0), map.width - 1);
  return indicesOf(table, (offset) => offset === map.map[slot]) ?? [0, 0];
}

/** Where a cell went: the one with its very content (moving and sorting keep each cell's content). */
function find(table: PMNode, cell: PMNode): [number, number] | undefined {
  return indicesOf(table, (_, node) => node.content === cell.content);
}

/** Row and index in the row of the first cell that `matches` (its offset from the table's start, its node). */
function indicesOf(table: PMNode, matches: (offset: number, node: PMNode) => boolean): [number, number] | undefined {
  let rowStart = 0;
  for (let row = 0; row < table.childCount; row++) {
    const rowNode = table.child(row);
    let offset = rowStart + 1;
    for (let index = 0; index < rowNode.childCount; index++) {
      if (matches(offset, rowNode.child(index))) return [row, index];
      offset += rowNode.child(index).nodeSize;
    }
    rowStart += rowNode.nodeSize;
  }
  return undefined;
}

/**
 * The cell, or every cell its (first) row or column runs through, also one reaching in from another row or column, as
 * offsets from the table's start.
 */
function cellsIn(map: TableMap, rect: Rect, scope: TableScope): number[] {
  if (scope === "cell") return [map.map[rect.top * map.width + rect.left]];
  const slots = scope === "row"
    ? Array.from({ length: map.width }, (_, column) => rect.top * map.width + column)
    : Array.from({ length: map.height }, (_, row) => row * map.width + rect.left);
  return [...new Set(slots.map((slot) => map.map[slot]))];
}

/**
 * The table with its rows in the order of their cells in `column`, as the web sorts a column: not with merged cells;
 * rows of header cells stay where they are; empty cells go last; letters compare without case or accents, numbers by
 * value. The table itself when the order stays; undefined when it can't be sorted.
 */
function sortedTable(table: PMNode, column: number, descending: boolean): PMNode | undefined {
  const rows: PMNode[][] = [];
  table.forEach((row) => {
    const cells: PMNode[] = [];
    row.forEach((cell) => cells.push(cell));
    rows.push(cells);
  });
  if (rows.some((cells) => cells.some((cell) => cell.attrs.colspan > 1 || cell.attrs.rowspan > 1))) return undefined;
  const items = rows.map((cells, order) => {
    const text = cells[column] ? sortText(cells[column]) : "";
    return { row: table.child(order), order, text, isHeader: cells.every((cell) => cell.type.name === "tableHeader"), isEmpty: !text };
  });
  if (items.length < 2 || !items.some((item) => !item.isHeader && !item.isEmpty)) return undefined;
  const collator = new Intl.Collator(undefined, { sensitivity: "base", numeric: true });
  const data = items.filter((item) => !item.isHeader).sort((a, b) => {
    if (a.isEmpty || b.isEmpty) return a.isEmpty === b.isEmpty ? a.order - b.order : a.isEmpty ? 1 : -1;
    const order = collator.compare(a.text, b.text);
    return descending ? -order : order;
  });
  const sorted = items.map((item) => (item.isHeader ? item : data.shift()!));
  if (sorted.every((item, index) => item.order === index)) return table;
  return table.type.create(table.attrs, sorted.map((item) => item.row), table.marks);
}

/** A cell's text as the web sorts by it: its text nodes only, trimmed, in lower case. */
function sortText(cell: PMNode): string {
  let text = "";
  cell.descendants((node) => {
    if (node.isText) text += node.text;
    return true;
  });
  return text.trim().toLowerCase();
}
