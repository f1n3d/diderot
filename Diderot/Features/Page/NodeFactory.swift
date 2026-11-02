import Foundation
import DocmostKit

/// Nodes the editor makes, as the web makes them: ids, mentions, integration links, columns and tabs. New blocks of
/// the insert menu's kinds come from `BlockTemplate.node()`.
enum NodeFactory {
    /// New ID like `generateNodeId` in the web client (12 lowercase letters).
    static func newNodeId() -> String {
        String((0..<12).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement()! })
    }

    /// A mention of a person (`entityType` "user") or a page ("page"), made by `creatorId`; `anchorId` points into the
    /// page (a heading).
    static func mention(entityType: String, entityId: String, label: String, slugId: String?, creatorId: String?,
                        anchorId: String? = nil) -> PMNode {
        var attrs: [String: JSONValue] = [
            "id": .string(UUID().uuidString.lowercased()),
            "label": .string(label),
            "entityType": .string(entityType),
            "entityId": .string(entityId),
            "slugId": slugId.map { .string($0) } ?? .null,
        ]
        if let creatorId { attrs["creatorId"] = .string(creatorId) }
        if let anchorId, !anchorId.isEmpty { attrs["anchorId"] = .string(anchorId) }
        return PMNode(type: "mention", attrs: attrs)
    }

    static func integrationMention(url: String, provider: String) -> PMNode {
        PMNode(type: "integrationMention", attrs: ["url": .string(url), "provider": .string(provider)])
    }

    static func integrationCard(url: String, provider: String) -> PMNode {
        PMNode(type: "integrationCard", attrs: ["url": .string(url), "provider": .string(provider)])
    }

    /// The link as text, with its service as the web keeps it.
    static func integrationLinkText(url: String, provider: String) -> PMNode {
        var attrs: [String: JSONValue] = ["href": .string(url), "target": "_blank", "internal": false]
        if !provider.isEmpty { attrs["integrationProvider"] = .string(provider) }
        return PMNode(type: "text", marks: [PMMark(type: "link", attrs: attrs)], text: url)
    }

    static func columns(count: Int) -> PMNode {
        PMNode(type: "columns", attrs: ["layout": .string(columnsLayout(count))],
               content: (0..<count).map { _ in PMNode(type: "column", content: [PMNode(type: "paragraph")]) })
    }

    static func columnsLayout(_ count: Int) -> String {
        switch count {
        case 3: "three_equal"
        case 4: "four_equal"
        case 5: "five_equal"
        default: "two_equal"
        }
    }

    /// A new tabs block as the web makes it: "Tab 1" and "Tab 2", each with an empty paragraph.
    static func tabs() -> PMNode {
        PMNode(type: "tabs", content: [tab(label: "Tab 1"), tab(label: "Tab 2")])
    }

    /// A tab without an id (Docmost gives it one): its label and a panel with an empty paragraph.
    static func tab(label: String, panel: [PMNode] = [PMNode(type: "paragraph")]) -> PMNode {
        PMNode(type: "tab", content: [
            PMNode(type: "tabLabel", content: label.isEmpty ? nil : [PMNode(type: "text", text: label)]),
            PMNode(type: "tabPanel", content: panel),
        ])
    }
}
