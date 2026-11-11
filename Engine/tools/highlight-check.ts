// Checks the syntax colors of code blocks (src/highlight.ts): the stretches a language's grammar marks, the guess
// without a language, and their offsets, which the app counts in UTF-16 units. Exits with 1 on any difference.
import { highlight } from "../src/highlight";

let differences = 0;
function expect(name: string, want: unknown, have: unknown) {
  if (JSON.stringify(want) === JSON.stringify(have)) return;
  differences++;
  console.log(`✗ ${name}\n  want: ${JSON.stringify(want)}\n  have: ${JSON.stringify(have)}`);
}
/** The stretches as "text:scope". */
const marked = (code: string, language?: string | null) => highlight(code, language).map(([start, length, scope]) => `${code.slice(start, start + length)}:${scope}`);

expect("Swift", ["let:keyword", "=:operator", "1:number"], marked("let x = 1", "swift"));
expect("JSON", ["{:punctuation", '"a":attr', "::punctuation", "true:keyword", "}:punctuation"], marked('{ "a": true }', "json"));
expect("the innermost scope counts", true, marked('func f() { return "a\\(b)" }', "swift").some((item) => item.endsWith(":string")));
expect("a comment", ["// Kommentar:comment"], marked("// Kommentar", "javascript"));
expect("plain text has no colors", [], marked("let x = 1", "plaintext"));
expect("Mermaid is drawn, not colored", [], marked("graph TD; A-->B", "mermaid"));
expect("a language Docmost adds to the common ones", true, marked("FROM alpine", "dockerfile").includes("FROM:keyword"));
const python = "def f(x):\n    return x + 1\n\nprint(f(2))";
expect("no language: guessed", true, marked(python).includes("def:keyword") && marked(python).includes("print:built_in"));
expect("an unknown language: guessed too", marked(python), marked(python, "nosuchlanguage"));
// "🙂" is two UTF-16 units: the comment is 5 long and the keyword after it starts at 6, not at 5.
expect("offsets in UTF-16 units", [[0, 5, "comment"], [6, 3, "keyword"], [12, 1, "operator"], [14, 1, "number"]], highlight("// 🙂\nlet x = 1", "swift"));
expect("empty code", [], highlight("", "swift"));

if (differences) {
  console.log(`${differences} difference(s)`);
  process.exit(1);
}
console.log("Code blocks get the web's syntax colors.");
