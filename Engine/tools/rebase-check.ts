// Checks `rebase` (src/rebase.ts): the app's edit of the block being edited, applied onto a collaborator's edit of that
// block since the app's editor took its text. Exits with 1 on any difference.
import { getSchema, type JSONContent } from "@tiptap/core";
import { Node as PMNode } from "@tiptap/pm/model";
import { rebase } from "../src/rebase";
import { schemaExtensions } from "../src/schema";

const schema = getSchema(schemaExtensions);
const text = (value: string, marks?: JSONContent["marks"]): JSONContent => ({ type: "text", text: value, ...(marks ? { marks } : {}) });
const paragraph = (content: JSONContent[] | string, attrs: Record<string, unknown> = {}) =>
  PMNode.fromJSON(schema, { type: "paragraph", attrs: { id: "a", ...attrs }, content: typeof content === "string" ? [text(content)] : content });

let differences = 0;
/** `want` is the merged block, or undefined when the app's block has to replace it whole. */
function check(name: string, base: PMNode, local: PMNode, current: PMNode, want: PMNode | undefined) {
  const have = rebase(current, base, local);
  if (JSON.stringify(have?.toJSON()) === JSON.stringify(want?.toJSON())) return;
  differences++;
  console.log(`✗ ${name}\n  want: ${JSON.stringify(want?.toJSON())}\n  have: ${JSON.stringify(have?.toJSON())}`);
}

check("no collaborator", paragraph("Hello"), paragraph("Hello!"), paragraph("Hello"), paragraph("Hello!"));
check("theirs after mine", paragraph("Hello world"), paragraph("Hello brave world"), paragraph("Hello world, everyone"),
  paragraph("Hello brave world, everyone"));
check("theirs before mine", paragraph("Hello world"), paragraph("Hello world!"), paragraph("Hi world"), paragraph("Hi world!"));
check("same range", paragraph("Hello world"), paragraph("Hello there"), paragraph("Hello earth"), undefined);
check("deleted by me, theirs elsewhere", paragraph("one two three"), paragraph("one three"), paragraph("one two three four"),
  paragraph("one three four"));
check("marks of both stay", paragraph([text("Hello ")]), paragraph([text("Hello "), text("bold", [{ type: "bold" }])]),
  paragraph([text("Oh, ", [{ type: "italic" }]), text("Hello ")]),
  paragraph([text("Oh, ", [{ type: "italic" }]), text("Hello "), text("bold", [{ type: "bold" }])]));
check("my attribute, their text", paragraph("Hello"), paragraph("Hello", { textAlign: "center" }), paragraph("Hello you"),
  paragraph("Hello you", { textAlign: "center" }));
check("their attribute, my text", paragraph("Hello"), paragraph("Hello!"), paragraph("Hello", { textAlign: "right" }),
  paragraph("Hello!", { textAlign: "right" }));
check("another type", paragraph("Hello"), paragraph("Hello!"), PMNode.fromJSON(schema, { type: "heading", attrs: { level: 1 }, content: [text("Hello")] }),
  undefined);

console.log(differences ? `${differences} rebase difference(s)` : "Rebasing keeps both edits.");
process.exitCode = differences ? 1 : 0;
