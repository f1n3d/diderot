import Foundation

/// Raw ProseMirror/TipTap node as stored in `pages.content`.
public struct PMNode: Codable, Sendable, Hashable {
    public let type: String
    public let attrs: [String: JSONValue]?
    public let content: [PMNode]?
    public let marks: [PMMark]?
    public let text: String?

    public init(type: String, attrs: [String: JSONValue]? = nil, content: [PMNode]? = nil, marks: [PMMark]? = nil, text: String? = nil) {
        self.type = type
        self.attrs = attrs
        self.content = content
        self.marks = marks
        self.text = text
    }

    /// Builds the node directly from a `JSONValue` (e.g. `Page.content`) without decoding again.
    public init?(json: JSONValue) {
        guard let object = json.objectValue, let type = object["type"]?.stringValue else { return nil }
        self.type = type
        self.attrs = object["attrs"]?.objectValue
        self.content = object["content"]?.arrayValue?.compactMap(PMNode.init(json:))
        self.marks = object["marks"]?.arrayValue?.compactMap(PMMark.init(json:))
        self.text = object["text"]?.stringValue
    }

    public var children: [PMNode] { content ?? [] }

    public func attr(_ key: String) -> JSONValue? { attrs?[key] }
    public func string(_ key: String) -> String? { attrs?[key]?.stringValue }
    public func int(_ key: String) -> Int? { attrs?[key]?.intValue }
    public func double(_ key: String) -> Double? { attrs?[key]?.doubleValue }
    public func bool(_ key: String) -> Bool? { attrs?[key]?.boolValue }

    /// Concatenated text of all text nodes below.
    public var plainText: String {
        if let text { return text }
        return children.map(\.plainText).joined()
    }
}

public struct PMMark: Codable, Sendable, Hashable {
    public let type: String
    public let attrs: [String: JSONValue]?

    public init(type: String, attrs: [String: JSONValue]? = nil) {
        self.type = type
        self.attrs = attrs
    }

    public init?(json: JSONValue) {
        guard let object = json.objectValue, let type = object["type"]?.stringValue else { return nil }
        self.type = type
        self.attrs = object["attrs"]?.objectValue
    }

    public func string(_ key: String) -> String? { attrs?[key]?.stringValue }
    public func bool(_ key: String) -> Bool? { attrs?[key]?.boolValue }
}
