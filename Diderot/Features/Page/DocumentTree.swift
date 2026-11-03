import DocmostKit

/// Finding blocks in a document: by path, by id, by what encloses them, and where text lies before or under a path. Pure
/// functions of a document, for the page's copy and the engine's alike.
extension PMNode {
    /// Blocks the page edits as text; a code block it edits as code.
    static let editableTextTypes: Set<String> = ["paragraph", "heading", "detailsSummary"]

    /// Containers whose content is edited directly (unlike columns, synced blocks, etc.).
    static let inPlaceContainers: Set<String> = [
        "bulletList", "orderedList", "listItem", "taskList", "taskItem", "blockquote", "callout",
        "details", "detailsContent", "table", "tableRow", "tableCell", "tableHeader",
    ]

    /// The node at `path` (child indices from this node); nil when there is none.
    func node(at path: [Int]) -> PMNode? {
        var current = self
        for index in path {
            guard current.children.indices.contains(index) else { return nil }
            current = current.children[index]
        }
        return current
    }

    /// Path of the first node in document order that `matches`.
    func path(where matches: (PMNode) -> Bool) -> [Int]? {
        func search(_ node: PMNode, _ path: [Int]) -> [Int]? {
            for (index, child) in node.children.enumerated() {
                if matches(child) { return path + [index] }
                if let found = search(child, path + [index]) { return found }
            }
            return nil
        }
        return search(self, [])
    }

    /// Path and node of a block: by its ID (stable when something before it changes), otherwise by path.
    func locate(_ ref: NodeRef) -> (path: [Int], node: PMNode)? {
        guard let id = ref.id else { return node(at: ref.path).map { (ref.path, $0) } }
        return path(where: { $0.string("id") == id }).flatMap { path in node(at: path).map { (path, $0) } }
    }

    /// Types of a node's ancestors, excluding the node.
    func ancestorTypes(of path: [Int]) -> Set<String> {
        var types: Set<String> = []
        var current = self
        for index in path.dropLast() {
            guard current.children.indices.contains(index) else { break }
            current = current.children[index]
            types.insert(current.type)
        }
        return types
    }

    /// Path of the nearest ancestor (not the node itself) whose type is one of `types`.
    func ancestorPath(of path: [Int], types: Set<String>) -> [Int]? {
        for length in stride(from: path.count - 1, through: 1, by: -1) {
            let prefix = Array(path.prefix(length))
            if let type = node(at: prefix)?.type, types.contains(type) { return prefix }
        }
        return nil
    }

    /// Where the `index`-th child of type `type` is among the children: an atom in a block's text, which a link to it
    /// names by its number among those of its type.
    func childPosition(ofType type: String, index: Int) -> Int? {
        let positions = children.indices.filter { children[$0].type == type }
        return positions.indices.contains(index) ? positions[index] : nil
    }

    /// `path`, or the first text under it, down through first children (a table's first cell, a list's first item);
    /// it stops at a block without children (an image, a formula).
    func textPath(from path: [Int]) -> [Int] {
        var path = path
        while let node = node(at: path), !Self.editableTextTypes.contains(node.type), node.type != "codeBlock", !node.children.isEmpty {
            path.append(0)
        }
        return path
    }

    /// Last directly editable text or non-mermaid code block before `path` in document order: in a table its last
    /// cell, for a collapsed toggle its summary.
    func lastTextBlock(before path: [Int]) -> NodeRef? {
        var result: NodeRef?
        /// Visits the children in document order; returns `false` once `path` is reached.
        func visit(_ node: PMNode, at nodePath: [Int]) -> Bool {
            for (index, child) in node.children.enumerated() {
                let childPath = nodePath + [index]
                let isAncestor = childPath.count < path.count && path.starts(with: childPath)
                guard isAncestor || childPath.precedes(path) else { return false }
                if Self.editableTextTypes.contains(child.type) || (child.type == "codeBlock" && child.string("language") != "mermaid") {
                    if !isAncestor { result = NodeRef(path: childPath, node: child) }
                } else if child.type == "details", child.bool("open") != true, !isAncestor {
                    if let summary = child.children.first, summary.type == "detailsSummary" {
                        result = NodeRef(path: childPath + [0], node: summary)
                    }
                } else if Self.inPlaceContainers.contains(child.type) {
                    if !visit(child, at: childPath) { return false }
                }
            }
            return true
        }
        _ = visit(self, at: [])
        return result
    }

    /// The document with blocks replaced by `overrides`, by their identity (`NodeRef.identity`).
    func applyingOverrides(_ overrides: [String: PMNode]) -> PMNode {
        func apply(to node: PMNode, path: [Int]) -> PMNode {
            let ref = NodeRef(path: path, node: node)
            // Kept by path for a block without an id: it stands only for a block of its type.
            if !path.isEmpty, let override = overrides[ref.identity], override.type == node.type { return override }
            guard let content = node.content else { return node }
            let children = content.enumerated().map { apply(to: $0.element, path: path + [$0.offset]) }
            return PMNode(type: node.type, attrs: node.attrs, content: children, marks: node.marks, text: node.text)
        }
        return overrides.isEmpty ? self : apply(to: self, path: [])
    }

    /// The node without its own and its descendants' ids, for a copy.
    func strippingIds() -> PMNode {
        var attrs = self.attrs
        attrs?["id"] = nil
        return PMNode(type: type, attrs: attrs?.isEmpty == true ? nil : attrs, content: content?.map { $0.strippingIds() }, marks: marks, text: text)
    }
}

extension [Int] {
    /// This path comes before `other` in document order and is neither `other` itself nor an ancestor of it.
    func precedes(_ other: [Int]) -> Bool {
        for (x, y) in zip(self, other) where x != y { return x < y }
        return false
    }
}
