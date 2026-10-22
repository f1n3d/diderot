// Describes what a set of editor extensions makes of documents, as plain data: the schema (every node and mark type
// in schema order with the spec fields that shape documents: content, groups, attributes and their defaults, …) and
// the plugins and hooks that can change documents. Two sets that describe the same hold the same documents.
import { Editor, getExtensionField, getSchema, type AnyExtension } from "@tiptap/core";

type Described = Record<string, unknown>;

const nodeFields = [
  "content", "marks", "group", "inline", "atom", "selectable", "draggable", "code", "whitespace", "defining",
  "definingAsContext", "definingForContent", "isolating", "tableRole", "linebreakReplacement",
] as const;
const markFields = ["inclusive", "excludes", "group", "spanning", "code"] as const;

function attributes(attrs: Record<string, { default?: unknown; validate?: unknown }> | undefined) {
  if (!attrs) return {};
  const result: Described = {};
  // In schema order, which is the order of the attributes in the document's JSON.
  for (const name of Object.keys(attrs)) {
    const attr = attrs[name];
    // An undefined default would drop the attribute from the document's JSON, unlike null.
    result[name] = "default" in attr ? { default: attr.default === undefined ? "(undefined)" : attr.default } : { required: true };
    if (typeof attr.validate === "string") (result[name] as Described).validate = attr.validate;
  }
  return result;
}

function pick(spec: Record<string, unknown>, fields: readonly string[]) {
  const result: Described = {};
  for (const field of fields) {
    if (spec[field] !== undefined) result[field] = spec[field];
  }
  return result;
}

export function describeSchema(extensions: AnyExtension[]) {
  const schema = getSchema(extensions);
  const nodes: Described[] = [];
  schema.spec.nodes.forEach((name, spec) => {
    nodes.push({ name, ...pick(spec as Record<string, unknown>, nodeFields), attrs: attributes(spec.attrs as never), leafText: typeof spec.leafText === "function" });
  });
  const marks: Described[] = [];
  schema.spec.marks.forEach((name, spec) => {
    marks.push({ name, ...pick(spec as Record<string, unknown>, markFields), attrs: attributes(spec.attrs as never) });
  });
  return { topNode: schema.topNodeType.name, nodes, marks };
}

/**
 * The named plugins that append or filter transactions, in the order they run, and the extension hooks that can
 * dispatch. Unnamed plugins are TipTap's input and paste rules, which act only on typing and pasting.
 */
export function describeDocumentPlugins(extensions: AnyExtension[]) {
  const editor = new Editor({ extensions, content: { type: "doc", content: [{ type: "paragraph" }] } });
  const plugins = editor.extensionManager.plugins
    // Keys are numbered per process: "name$", "name$1", …
    .map((plugin) => ({ plugin, key: (plugin as unknown as { key: string }).key.replace(/\$\d*$/, "") }))
    .filter(({ plugin, key }) => key !== "plugin" && (plugin.spec.appendTransaction || plugin.spec.filterTransaction))
    .map(({ plugin, key }) => ({ key, appends: !!plugin.spec.appendTransaction, filters: !!plugin.spec.filterTransaction }));
  const hooks = editor.extensionManager.extensions.flatMap((extension) =>
    ["onCreate", "onUpdate", "onTransaction"]
      .filter((hook) => getExtensionField(extension, hook as never))
      .map((hook) => `${extension.name}.${hook}`),
  );
  editor.destroy();
  return { plugins, hooks };
}
