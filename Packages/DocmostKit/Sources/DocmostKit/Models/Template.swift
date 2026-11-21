import Foundation

/// A page template (the Enterprise license feature `templates`, Docmost 0.90): global, or of one space.
public struct PageTemplate: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String?
    public let description: String?
    public let icon: String?
    /// The space it belongs to; `nil` for a global one, which every space offers.
    public let spaceId: String?
    /// Its document (`templates/info`).
    public let content: JSONValue?
    public let updatedAt: Date?
    /// `updatedAt` exactly as the server sent it: Docmost 0.98 takes it back as the template's revision
    /// (`templateUpdatedAt`) to the millisecond, which a `Date` round trip may not keep.
    public let revision: String?

    public var displayTitle: String { PageTitle.display(title) }

    private enum CodingKeys: String, CodingKey {
        case id, title, description, icon, spaceId, content, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        spaceId = try container.decodeIfPresent(String.self, forKey: .spaceId)
        content = try container.decodeIfPresent(JSONValue.self, forKey: .content)
        updatedAt = try? container.decodeIfPresent(Date.self, forKey: .updatedAt)
        revision = try? container.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

/// A field a template asks for when a page is made from it (Docmost 0.98's `templateVariable` node): its value becomes
/// text on the page in the variable's place.
public struct TemplateVariable: Sendable, Hashable, Identifiable {
    public enum FieldType: String, Sendable, Hashable {
        case text, multiline, select
    }

    /// The id the server keys the value by (the first occurrence's, for every variable of that name).
    public let id: String
    public let name: String
    public let fieldType: FieldType
    /// The choices of a `select` field.
    public let options: [String]

    public enum Invalid: Error, Equatable {
        /// A variable without a valid id, name, type or options.
        case variable
        /// One id under two names.
        case conflictingNames
    }

    /// The fields a template's content asks for, as Docmost's `getTemplateVariables`: one per name (trimmed, case
    /// ignored), the first occurrence giving its place in the list and its definition. Throws where the web refuses the
    /// template ("Failed to load template").
    public static func fields(in content: JSONValue?) throws -> [TemplateVariable] {
        var fields: [TemplateVariable] = []
        var seen: Set<String> = []
        var namesById: [String: String] = [:]
        func visit(_ node: JSONValue) throws {
            if node["type"]?.stringValue == "templateVariable" {
                guard let variable = TemplateVariable(attrs: node["attrs"]) else { throw Invalid.variable }
                let key = nameKey(variable.name)
                if let earlier = namesById[variable.id], earlier != key { throw Invalid.conflictingNames }
                namesById[variable.id] = key
                if seen.insert(key).inserted { fields.append(variable) }
            } else if let children = node["content"]?.arrayValue {
                for child in children { try visit(child) }
            }
        }
        if let content { try visit(content) }
        return fields
    }

    /// Two variables with the same name are one field.
    public static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The web's `isTemplateVariable`: a UUID, a name on one line, and options only for `select` (one or more, on one
    /// line each, no two alike).
    init?(attrs: JSONValue?) {
        func singleLine(_ value: String?) -> String? {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !value.contains(where: { $0 == "\n" || $0 == "\r" }) else { return nil }
            return value
        }
        guard let id = attrs?["id"]?.stringValue, Self.isUUID(id), let name = singleLine(attrs?["name"]?.stringValue),
              let type = attrs?["fieldType"]?.stringValue.flatMap(FieldType.init(rawValue:)),
              let rawOptions = attrs?["options"]?.arrayValue
        else { return nil }
        let options = rawOptions.map(\.stringValue)
        switch type {
        case .select:
            let values = options.compactMap { singleLine($0) }
            guard !values.isEmpty, values.count == options.count, Set(values).count == values.count else { return nil }
            self.options = values
        case .text, .multiline:
            guard options.isEmpty else { return nil }
            self.options = []
        }
        self.id = id
        self.name = name
        fieldType = type
    }

    /// As the `uuid` package's `validate`: versions 1 to 8, the nil and the max UUID.
    static func isUUID(_ value: String) -> Bool {
        let lower = value.lowercased()
        if lower == "00000000-0000-0000-0000-000000000000" || lower == "ffffffff-ffff-ffff-ffff-ffffffffffff" { return true }
        return lower.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/) != nil
    }
}
