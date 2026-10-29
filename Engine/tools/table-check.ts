// Checks the table commands of the app's keyboard toolbar (src/tables.ts) on small tables: the table each one leaves
// and the cell that gets the cursor. Exits with 1 on any difference.
//
// Tables are written as rows of cells: "A" is a cell with the paragraph "A" ("A/B" two paragraphs, "" an empty one),
// "#A" a header cell; " →2" makes it two columns wide, " ↓2" two rows tall, another word is its color's name. Results
// add, in brackets, the alignment of the cell's paragraphs.
import { getSchema } from "@tiptap/core";
import type { Node as PMNode } from "@tiptap/pm/model";
import { EditorState } from "@tiptap/pm/state";
import { runTableCommand, type TableCommand } from "../src/tables";
import { schemaExtensions } from "../src/schema";

const schema = getSchema(schemaExtensions);
type Rows = string[][];

function table(rows: Rows): PMNode {
  return schema.nodes.table.create(null, rows.map((cells) => schema.nodes.tableRow.create(null, cells.map((spec) => {
    const [first = "", ...options] = spec.split(" ");
    const header = first.startsWith("#");
    const attrs: Record<string, number | string> = {};
    for (const option of options) {
      if (option.startsWith("→")) attrs.colspan = Number(option.slice(1));
      else if (option.startsWith("↓")) attrs.rowspan = Number(option.slice(1));
      else Object.assign(attrs, { backgroundColor: "#b4d5ff", backgroundColorName: option });
    }
    const paragraphs = (header ? first.slice(1) : first).split("/").map((text) =>
      schema.nodes.paragraph.create(null, text ? schema.text(text) : undefined));
    return schema.nodes[header ? "tableHeader" : "tableCell"].create(attrs, paragraphs);
  }))));
}

function describe(node: PMNode): Rows {
  const rows: Rows = [];
  node.forEach((row) => {
    const cells: string[] = [];
    row.forEach((cell) => {
      const texts: string[] = [];
      const aligns = new Set<string>();
      cell.descendants((child) => {
        if (child.type.name !== "paragraph" && child.type.name !== "heading") return true;
        texts.push(child.textContent);
        if (child.attrs.textAlign) aligns.add(child.attrs.textAlign);
        return false;
      });
      let text = `${cell.type.name === "tableHeader" ? "#" : ""}${texts.join("/")}`;
      if (cell.attrs.colspan > 1) text += ` →${cell.attrs.colspan}`;
      if (cell.attrs.rowspan > 1) text += ` ↓${cell.attrs.rowspan}`;
      if (cell.attrs.backgroundColorName) text += ` ${cell.attrs.backgroundColorName}`;
      if (aligns.size) text += ` [${[...aligns].join(",")}]`;
      cells.push(text);
    });
    rows.push(cells);
  });
  return rows;
}

let differences = 0;
/**
 * Runs `command` on `cell` of a table from `rows` (with a paragraph after it); `want` is the table afterwards, "gone"
 * when the table was deleted, null when the command must not apply.
 */
function check(name: string, rows: Rows, cell: [number, number], command: TableCommand, want: Rows | "gone" | null, focus?: [number, number]) {
  const doc = schema.nodes.doc.create(null, [table(rows), schema.nodes.paragraph.create()]);
  const result = runTableCommand(EditorState.create({ schema, doc }), 0, cell, command);
  const after = result ? (result.tr?.doc ?? doc).firstChild! : undefined;
  const have = !result ? null : after?.type.name === "table" ? describe(after) : "gone";
  const haveFocus = result?.focus ?? undefined;
  const wantFocus = want === null || want === "gone" ? undefined : focus;
  if (JSON.stringify(have) === JSON.stringify(want) && JSON.stringify(haveFocus) === JSON.stringify(wantFocus)) return;
  differences++;
  console.log(`✗ ${name}\n  want: ${JSON.stringify(want)} cursor ${JSON.stringify(wantFocus)}\n  have: ${JSON.stringify(have)} cursor ${JSON.stringify(haveFocus)}`);
}

const plain = [["A", "B"], ["C", "D"]];

check("row below: the new row gets the cursor", plain, [0, 0], { name: "addRowAfter" }, [["A", "B"], ["", ""], ["C", "D"]], [1, 0]);
check("row above", plain, [1, 1], { name: "addRowBefore" }, [["A", "B"], ["", ""], ["C", "D"]], [1, 1]);
check("column right", plain, [0, 0], { name: "addColumnAfter" }, [["A", "", "B"], ["C", "", "D"]], [0, 1]);
check("column left", plain, [1, 1], { name: "addColumnBefore" }, [["A", "", "B"], ["C", "", "D"]], [1, 1]);
check("row below a cell two rows tall: below both rows", [["A ↓2", "B"], ["C"]], [0, 0], { name: "addRowAfter" },
  [["A ↓2", "B"], ["C"], ["", ""]], [2, 0]);
check("row within a cell two rows tall: the cell grows", [["A ↓2", "B"], ["C"]], [0, 1], { name: "addRowAfter" },
  [["A ↓3", "B"], [""], ["C"]], [1, 0]);

check("delete row: the next row gets the cursor", plain, [0, 1], { name: "deleteRow" }, [["C", "D"]], [0, 1]);
check("delete the last row: the row before", plain, [1, 0], { name: "deleteRow" }, [["A", "B"]], [0, 0]);
check("delete the only row deletes the table", [["A", "B"]], [0, 1], { name: "deleteRow" }, "gone");
check("delete column", plain, [1, 0], { name: "deleteColumn" }, [["B"], ["D"]], [1, 0]);
check("delete the only column deletes the table", [["A"], ["C"]], [1, 0], { name: "deleteColumn" }, "gone");
check("delete table", plain, [1, 1], { name: "deleteTable" }, "gone");

check("header row: the first row, from any row", plain, [1, 1], { name: "toggleHeaderRow" }, [["#A", "#B"], ["C", "D"]], [1, 1]);
check("header row off", [["#A", "#B"], ["C", "D"]], [0, 0], { name: "toggleHeaderRow" }, plain, [0, 0]);
check("header column keeps the header row's corner", [["#A", "#B"], ["C", "D"]], [1, 1], { name: "toggleHeaderColumn" },
  [["#A", "#B"], ["#C", "D"]], [1, 1]);
check("header cell", plain, [1, 1], { name: "toggleHeaderCell" }, [["A", "B"], ["C", "#D"]], [1, 1]);
check("header cell off", [["A", "B"], ["C", "#D"]], [1, 1], { name: "toggleHeaderCell" }, plain, [1, 1]);

check("merge right: both texts in one cell", plain, [0, 0], { name: "mergeRight" }, [["A/B →2"], ["C", "D"]], [0, 0]);
check("merge down", plain, [0, 1], { name: "mergeDown" }, [["A", "B/D ↓2"], ["C"]], [0, 1]);
check("merge down with an empty cell keeps the text", [["A", "B"], ["", "D"]], [0, 0], { name: "mergeDown" },
  [["A ↓2", "B"], ["D"]], [0, 0]);
check("merge right takes in the rectangle around both", [["A ↓2", "B", "C"], ["D", "E"]], [0, 0], { name: "mergeRight" },
  [["A/B/D →2 ↓2", "C"], ["E"]], [0, 0]);
check("merge right from a lower cell: the merged cell starts higher", [["A", "B ↓2"], ["C"]], [1, 0], { name: "mergeRight" },
  [["A/B/C →2 ↓2"], []], [0, 0]);
check("no merge right in the last column", plain, [0, 1], { name: "mergeRight" }, null);
check("no merge down in the last row", plain, [1, 0], { name: "mergeDown" }, null);
check("no merge when a cell would stick out", [["A ↓2", "B", "C"], ["D →2"]], [0, 0], { name: "mergeRight" }, null);
const docmostTable = [["A →2", "S ↓2"], ["B", "C"], ["D", "E", "F"]];
check("merge a cell two rows tall down", docmostTable, [0, 1], { name: "mergeDown" }, [["A →2", "S/F ↓3"], ["B", "C"], ["D", "E"]], [0, 1]);
check("no merge cutting through a cell two columns wide", docmostTable, [1, 1], { name: "mergeRight" }, null);
check("split: the text stays in the first cell", [["A/B →2"], ["C", "D"]], [0, 0], { name: "split" }, [["A/B", ""], ["C", "D"]], [0, 0]);
check("split a cell two rows tall", [["A", "B ↓2"], ["C"]], [0, 1], { name: "split" }, [["A", "B"], ["C", ""]], [0, 1]);
check("no split of a single cell", plain, [0, 0], { name: "split" }, null);

check("row down: the cursor goes with it", plain, [0, 1], { name: "moveRowDown" }, [["C", "D"], ["A", "B"]], [1, 1]);
check("row up", [["A", "B"], ["C", "D"], ["E", "F"]], [2, 0], { name: "moveRowUp" }, [["A", "B"], ["E", "F"], ["C", "D"]], [1, 0]);
check("no row up from the first row", plain, [0, 0], { name: "moveRowUp" }, null);
check("no row down from the last row", plain, [1, 0], { name: "moveRowDown" }, null);
check("column right", plain, [1, 0], { name: "moveColumnRight" }, [["B", "A"], ["D", "C"]], [1, 1]);
check("column left", plain, [0, 1], { name: "moveColumnLeft" }, [["B", "A"], ["D", "C"]], [0, 0]);
check("no column left from the first column", plain, [0, 0], { name: "moveColumnLeft" }, null);

const names = [["#Name", "#Nr"], ["b", "10"], ["Ä", "9"], ["", "1"], ["c", "2"]];
check("sort A to Z: header row stays, case and accents ignored, empty last; the cursor goes with its row", names, [2, 0],
  { name: "sort", descending: false }, [["#Name", "#Nr"], ["Ä", "9"], ["b", "10"], ["c", "2"], ["", "1"]], [1, 0]);
check("sort Z to A: empty still last", names, [1, 0], { name: "sort", descending: true },
  [["#Name", "#Nr"], ["c", "2"], ["b", "10"], ["Ä", "9"], ["", "1"]], [2, 0]);
check("sort numbers by value", names, [1, 1], { name: "sort", descending: false },
  [["#Name", "#Nr"], ["", "1"], ["c", "2"], ["Ä", "9"], ["b", "10"]], [4, 1]);
check("sorted already: nothing changes", [["a"], ["b"]], [0, 0], { name: "sort", descending: false }, [["a"], ["b"]], [0, 0]);
check("no sort with merged cells", [["A →2"], ["B", "C"]], [1, 0], { name: "sort", descending: false }, null);
check("no sort without text to sort by", [["#A"], [""]], [1, 0], { name: "sort", descending: false }, null);

const blue = { color: "#b4d5ff", colorName: "Blue" };
check("color of a cell", plain, [0, 1], { name: "background", scope: "cell", ...blue }, [["A", "B Blue"], ["C", "D"]], [0, 1]);
check("color of a row", plain, [1, 0], { name: "background", scope: "row", ...blue }, [["A", "B"], ["C Blue", "D Blue"]], [1, 0]);
check("color of a column", plain, [0, 1], { name: "background", scope: "column", ...blue }, [["A", "B Blue"], ["C", "D Blue"]], [0, 1]);
check("color of a row with a cell from the row above in it", [["A ↓2", "B"], ["C"]], [1, 0], { name: "background", scope: "row", ...blue },
  [["A ↓2 Blue", "B"], ["C Blue"]], [1, 0]);
check("default color", [["A", "B Blue"], ["C", "D"]], [0, 1], { name: "background", scope: "cell", color: null, colorName: "Default" },
  plain, [0, 1]);

check("alignment of a column", plain, [1, 0], { name: "align", scope: "column", align: "center" }, [["A [center]", "B"], ["C [center]", "D"]], [1, 0]);
check("alignment of every paragraph in a cell", [["A/B", "C"]], [0, 0], { name: "align", scope: "cell", align: "right" },
  [["A/B [right]", "C"]], [0, 0]);
check("left is set, as the web does", [["A"]], [0, 0], { name: "align", scope: "row", align: "left" }, [["A [left]"]], [0, 0]);

check("clear a cell", [["A/B", "C"]], [0, 0], { name: "clear", scope: "cell" }, [["", "C"]], [0, 0]);
check("clear a row keeps the colors", [["A Blue", "B"], ["C", "D"]], [0, 1], { name: "clear", scope: "row" }, [[" Blue", ""], ["C", "D"]], [0, 1]);
check("clear a column", plain, [1, 1], { name: "clear", scope: "column" }, [["A", ""], ["C", ""]], [1, 1]);

check("a cell that isn't there", plain, [0, 5], { name: "addRowAfter" }, null);

console.log(differences ? `${differences} table difference(s)` : "The table commands do what the web's menus do.");
process.exitCode = differences ? 1 : 0;
