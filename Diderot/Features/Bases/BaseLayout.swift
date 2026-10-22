import SwiftUI
import UIKit
import DocmostKit

/// Choice value of a select, status or multi-select property.
struct BaseChoice: Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let color: String
    /// Status only: `todo`, `inProgress` or `complete`.
    var category: String?
}

/// Web client view rules (visible properties, order, widths, kanban columns) and query filters.
enum BaseLayout {
    static let defaultColumnWidth: CGFloat = 180
    static let minColumnWidth: CGFloat = 80
    static let maxColumnWidth: CGFloat = 600

    // MARK: Table

    /// Visible columns as in the web client: `hiddenPropertyIds` wins over `visiblePropertyIds`; order from
    /// `propertyOrder` (unlisted ones by position). The title column always comes first and can't be hidden.
    static func tableColumns(base: Base, view: BaseView?) -> [BaseProperty] {
        let config = view?.config
        let hidden = Set(stringArray(config?["hiddenPropertyIds"]) ?? [])
        let visible = stringArray(config?["visiblePropertyIds"]).flatMap { $0.isEmpty ? nil : Set($0) }
        let shown = base.properties.filter { property in
            if property.isPrimary == true { return true }
            if config?["hiddenPropertyIds"]?.arrayValue != nil { return !hidden.contains(property.id) }
            if let visible { return visible.contains(property.id) }
            return true
        }
        let ordered = ordered(shown.sorted { ($0.position ?? "") < ($1.position ?? "") }, by: stringArray(config?["propertyOrder"]))
        return ordered.filter { $0.isPrimary == true } + ordered.filter { $0.isPrimary != true }
    }

    static func width(of property: BaseProperty, in view: BaseView?) -> CGFloat {
        if let width = view?.config?["propertyWidths"]?[property.id]?.doubleValue {
            return min(max(CGFloat(width), minColumnWidth), maxColumnWidth)
        }
        switch property.kind {
        case .checkbox: return 90
        case .number, .date, .createdAt, .lastEditedAt: return 140
        default: return defaultColumnWidth
        }
    }

    // MARK: Kanban

    /// Grouping property of the kanban view; only select and status properties can group.
    static func groupByProperty(base: Base, view: BaseView) -> BaseProperty? {
        guard let id = view.config?["groupByPropertyId"]?.stringValue, let property = base.property(id: id),
              property.kind == .select || property.kind == .status
        else { return nil }
        return property
    }

    /// Columns in the view's order (else the property's), hidden ones omitted. "No value" comes after the unlisted
    /// choices unless the order lists it.
    static func kanbanColumns(view: BaseView, groupBy: BaseProperty) -> [BaseKanbanColumn] {
        let columns = choices(of: groupBy).map { BaseKanbanColumn(id: $0.id, name: $0.name, color: $0.color) }
            + [BaseKanbanColumn(id: BaseKanbanColumn.noValueId, name: nil, color: nil)]
        let order = stringArray(view.config?["choiceOrder"]) ?? stringArray(groupBy.typeOptions?["choiceOrder"])
        let hidden = Set(stringArray(view.config?["hiddenChoiceIds"]) ?? [])
        return ordered(columns, by: order).filter { !hidden.contains($0.id) }
    }

    /// Kanban column of a row: its choice value or "No value".
    static func columnId(of row: BaseRow, groupBy: BaseProperty) -> String {
        guard let id = row.cells[groupBy.id]?.stringValue, !id.isEmpty else { return BaseKanbanColumn.noValueId }
        return id
    }

    /// Card fields: `visiblePropertyIds` without the title, ordered by `propertyOrder`.
    static func cardProperties(base: Base, view: BaseView) -> [BaseProperty] {
        let visible = Set(stringArray(view.config?["visiblePropertyIds"]) ?? [])
        let shown = base.properties.filter { visible.contains($0.id) && $0.isPrimary != true }
        return ordered(shown.sorted { ($0.position ?? "") < ($1.position ?? "") }, by: stringArray(view.config?["propertyOrder"]))
    }

    // MARK: Queries

    /// The view's filter, if it has conditions.
    static func filter(of view: BaseView) -> JSONValue? {
        guard let filter = view.config?["filter"], filter["children"]?.arrayValue?.isEmpty == false else { return nil }
        return filter
    }

    static func sorts(of view: BaseView) -> JSONValue? {
        guard let sorts = view.config?["sorts"], sorts.arrayValue?.isEmpty == false else { return nil }
        return sorts
    }

    /// Filter for a kanban column: view filter AND grouping value (or empty).
    static func columnFilter(viewFilter: JSONValue?, groupBy: String, column: BaseKanbanColumn) -> JSONValue {
        let condition: JSONValue = column.isNoValue
            ? .object(["propertyId": .string(groupBy), "op": .string("isEmpty")])
            : .object(["propertyId": .string(groupBy), "op": .string("eq"), "value": .string(column.id)])
        return .object(["op": .string("and"), "children": .array([condition] + (viewFilter.map { [$0] } ?? []))])
    }

    // MARK: Helpers

    /// Row title (title property) or "Untitled".
    static func title(of row: BaseRow, in base: Base?) -> String {
        let text = base?.primaryProperty.flatMap { row.cells[$0.id]?.stringValue } ?? ""
        return text.isEmpty ? PageTitle.untitled : text
    }

    /// System properties always have a value; an unchecked checkbox counts as empty.
    static func hasValue(_ property: BaseProperty, in row: BaseRow) -> Bool {
        switch property.kind {
        case .createdAt, .lastEditedAt, .lastEditedBy: return true
        case .checkbox: return row.cells[property.id]?.boolValue == true
        default:
            guard let value = row.cells[property.id], !value.isNull else { return false }
            if let string = value.stringValue { return !string.isEmpty }
            if let array = value.arrayValue { return !array.isEmpty }
            return true
        }
    }

    static func choices(of property: BaseProperty) -> [BaseChoice] {
        (property.typeOptions?["choices"]?.arrayValue ?? []).compactMap { choice in
            guard let id = choice["id"]?.stringValue, let name = choice["name"]?.stringValue else { return nil }
            return BaseChoice(
                id: id, name: name, color: choice["color"]?.stringValue ?? "gray", category: choice["category"]?.stringValue
            )
        }
    }

    /// Choices in the property's order (`choiceOrder`), unlisted ones last.
    static func orderedChoices(of property: BaseProperty) -> [BaseChoice] {
        ordered(choices(of: property), by: stringArray(property.typeOptions?["choiceOrder"]))
    }

    static func stringArray(_ value: JSONValue?) -> [String]? {
        value?.arrayValue?.compactMap(\.stringValue)
    }

    /// Items listed in `order` first (unknown IDs dropped), then the unlisted ones in their given order.
    private static func ordered<Item: Identifiable>(_ items: [Item], by order: [String]?) -> [Item] where Item.ID == String {
        guard let order, !order.isEmpty else { return items }
        return order.compactMap { id in items.first { $0.id == id } } + items.filter { !order.contains($0.id) }
    }

    /// SF Symbol per property type (header, detail sheet).
    static func symbol(for kind: BaseProperty.Kind?) -> String {
        switch kind {
        case .text: "textformat"
        case .longText: "text.alignleft"
        case .number: "number"
        case .select: "chevron.down.circle"
        case .status: "circle.dashed"
        case .multiSelect: "list.bullet"
        case .date: "calendar"
        case .person: "person"
        case .page: "doc.text"
        case .file: "paperclip"
        case .checkbox: "checkmark.square"
        case .url: "link"
        case .email: "envelope"
        case .createdAt, .lastEditedAt: "clock"
        case .lastEditedBy: "person.crop.circle"
        case .formula: "function"
        case nil: "questionmark.square.dashed"
        }
    }
}

/// Option colors: the web's color names (Mantine's palette) on the nearest system colors, so they follow light and dark
/// mode. Text gets the color mixed with the primary color, so it stays readable on the tint.
enum BaseChoiceColor {
    static func background(_ name: String) -> Color { color(name).opacity(0.2) }

    static func foreground(_ name: String) -> Color { color(name).mix(with: .primary, by: 0.35) }

    private static func color(_ name: String) -> Color {
        switch name {
        case "red": .red
        case "pink": .pink
        case "grape": .purple
        case "violet": .purple.mix(with: .indigo, by: 0.5)
        case "indigo": .indigo
        case "blue": .blue
        case "cyan": .cyan
        case "teal": .teal
        case "green": .green
        case "lime": .green.mix(with: .yellow, by: 0.5)
        case "yellow": .yellow
        case "orange": .orange
        default: .gray
        }
    }
}

/// Numbers and dates formatted as in the web client, but with device conventions (decimal separator, month names).
enum BaseFormat {
    static func number(_ value: Double, options: JSONValue?) -> String {
        let precision = options?["precision"]?.intValue
        let grouping = (options?["separators"]?.stringValue).map { $0 != "none" } ?? false
        func plain(_ number: Double) -> String {
            var style = FloatingPointFormatStyle<Double>.number.grouping(grouping ? .automatic : .never)
            style = precision.map { style.precision(.fractionLength($0)) } ?? style.precision(.fractionLength(0...4))
            return number.formatted(style)
        }
        switch options?["format"]?.stringValue {
        case "currency":
            let code = options?["currencyCode"]?.stringValue ?? "USD"
            return value.formatted(.currency(code: code).precision(.fractionLength(precision ?? 2)))
        case "percent":
            return plain(value) + "%"
        case "progress":
            return "\(Int(min(100, max(0, value)).rounded()))%"
        default:
            return plain(value)
        }
    }

    static func isProgress(_ options: JSONValue?) -> Bool {
        options?["format"]?.stringValue == "progress"
    }

    /// With time: local time, as in the web client. Without time: the local day, except at midnight UTC (a day stored
    /// without time), which would otherwise show as the previous day west of UTC.
    static func date(_ text: String, options: JSONValue?, timeZone: TimeZone = .current) -> String {
        guard let date = parseDate(text) else { return text }
        if options?["includeTime"]?.boolValue == true {
            return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: timeZone))
        }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = isMidnightUTC(date) ? .gmt : timeZone
        return date.formatted(style)
    }

    /// How date properties and today() store a day without time.
    static func isMidnightUTC(_ date: Date) -> Bool {
        date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400) == 0
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func parseDate(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        if let date = try? Date(text, strategy: .iso8601) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle().year().month().day())
    }
}
