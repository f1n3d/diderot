// Syntax colors for code blocks, as the web's editor has them: lowlight (highlight.js) with the grammars Docmost's
// client registers. The app runs this in a JavaScript context of its own, without a page: code in, its colored stretches
// out (Diderot/Rendering/CodeHighlighter.swift). Built into Diderot/Resources/Engine/highlight.js (build.mjs).
import { common, createLowlight } from "lowlight";
import clojure from "highlight.js/lib/languages/clojure";
import dockerfile from "highlight.js/lib/languages/dockerfile";
import elixir from "highlight.js/lib/languages/elixir";
import erlang from "highlight.js/lib/languages/erlang";
import fortran from "highlight.js/lib/languages/fortran";
import haskell from "highlight.js/lib/languages/haskell";
import plaintext from "highlight.js/lib/languages/plaintext";
import powershell from "highlight.js/lib/languages/powershell";
import scala from "highlight.js/lib/languages/scala";

// As Docmost's client (apps/client/src/features/editor/extensions/extensions.ts), but for ABAP, a package of its own.
const lowlight = createLowlight(common);
lowlight.register({ mermaid: plaintext, powershell, erlang, elixir, dockerfile, clojure, fortran, haskell, scala });

/** A stretch of the code with a highlight.js scope ("keyword", "string" …): start and length in UTF-16 units. */
export type Stretch = [start: number, length: number, scope: string];

type Tree = { type: string; value?: string; properties?: { className?: unknown }; children?: Tree[] };

/**
 * The stretches of `code` that have a scope, each with its innermost one. In `language` when lowlight knows it, else
 * in the language it guesses, as Tiptap's code block does on the web.
 */
export function highlight(code: string, language?: string | null): Stretch[] {
  const tree: Tree = language && lowlight.registered(language) ? lowlight.highlight(language, code) : lowlight.highlightAuto(code);
  const stretches: Stretch[] = [];
  let offset = 0;
  const walk = (node: Tree, scope?: string) => {
    if (node.type === "text") {
      const length = node.value?.length ?? 0;
      if (scope && length > 0) stretches.push([offset, length, scope]);
      offset += length;
      return;
    }
    const classes = node.properties?.className;
    const own = Array.isArray(classes) && typeof classes[0] === "string" ? classes[0].replace(/^hljs-/, "") : undefined;
    for (const child of node.children ?? []) walk(child, own ?? scope);
  };
  walk(tree);
  return stretches;
}

// For the app: the stretches as JSON.
(globalThis as { DiderotHighlight?: unknown }).DiderotHighlight = (code: string, language?: string | null) => JSON.stringify(highlight(code, language));
