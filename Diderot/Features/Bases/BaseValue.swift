import Foundation
import DocmostKit

/// Cell values in the web client's format (`apps/client/src/ee/base`), so web and app see the same data.
enum BaseValue {
    // MARK: Text

    /// Text and title: unchanged; cleared as "" (like the web client's detail view).
    static func text(_ draft: String) -> JSONValue {
        .string(draft)
    }

    /// URL: trimmed; empty clears the cell. The server rejects URLs without a scheme ("example.com"), so like Notion
    /// the app adds `https://`.
    static func url(_ draft: String) -> JSONValue? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return .string(hasScheme(trimmed) ? trimmed : "https://" + trimmed)
    }

    /// Email: trimmed; empty clears the cell.
    static func email(_ draft: String) -> JSONValue? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : .string(trimmed)
    }

    /// URL to open a stored link; older values without a scheme get `https://`.
    static func openURL(_ link: String) -> URL? {
        URL(string: hasScheme(link) ? link : "https://" + link)
    }

    /// A scheme at the start ("https://", "ftp://", "mailto:", "tel:"); "://" further on (a query parameter) isn't one.
    private static func hasScheme(_ link: String) -> Bool {
        let lowered = link.lowercased()
        return lowered.contains(/^[a-z][a-z0-9+.-]*:\/\//) || ["mailto:", "tel:"].contains { lowered.hasPrefix($0) }
    }

    /// Long text: trimmed; empty clears the cell.
    static func longText(_ draft: String) -> JSONValue? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : .string(trimmed)
    }

    // MARK: Number

    /// Number input: empty clears the cell, unparseable or unreadable input changes nothing.
    enum NumberInput: Equatable {
        case clear
        case value(Double)
        case invalid
    }

    /// Parses numbers with comma or point, thousands separators allowed. The cell stores the plain number: percent as
    /// 50 for 50 %, progress as 0–100; decimal places only affect the display (web parity).
    static func parseNumber(_ draft: String, locale: Locale = .current) -> NumberInput {
        let mapped = draft.map(asciiNumberCharacter)
        // A character the parser can't read makes the input invalid instead of vanishing ("1/2" was 12, "1e6" 16).
        guard mapped.allSatisfy(isNumberOrDecoration) else { return .invalid }
        var text = String(mapped).filter { $0.isNumber || $0 == "," || $0 == "." || $0 == "-" }
        if text.isEmpty || text == "-" { return draft.trimmingCharacters(in: .whitespaces).isEmpty ? .clear : .invalid }
        let lastComma = text.lastIndex(of: ",")
        let lastPoint = text.lastIndex(of: ".")
        switch (lastComma, lastPoint) {
        case let (comma?, point?):
            // The later one is the decimal mark, the other groups thousands.
            let decimal: Character = comma > point ? "," : "."
            text = text.filter { $0 != (decimal == "," ? "." : ",") }
            if decimal == "," { text = text.replacingOccurrences(of: ",", with: ".") }
        case let (mark?, nil), let (nil, mark?):
            // One kind: thousands when it repeats, or when it is the locale's grouping separator between 1–999 and
            // exactly three digits ("1,000" in English, "1.000" in German); else the decimal mark ("0.500" is 0.5).
            // `Locale(identifier:)` drops a number format chosen in Settings, which `numberDraft`'s formatter ignores
            // too, so the app reads its own drafts back.
            let separator = text[mark]
            let groups = text.split(separator: separator, omittingEmptySubsequences: false)
            let isGrouping = String(separator) == Locale(identifier: locale.identifier).groupingSeparator.map { String($0.map(asciiNumberCharacter)) }
            let lead = Int(groups[0])?.magnitude ?? 0
            let thousands = groups.count > 2 || (isGrouping && groups[1].count == 3 && (1...999).contains(lead))
            text = thousands ? text.filter { $0 != separator } : text.replacingOccurrences(of: ",", with: ".")
        default:
            break
        }
        guard let number = Double(text), number.isFinite else { return .invalid }
        return .value(number)
    }

    /// Number characters as the parser reads them: decimal digits of any script as ASCII (regions like Saudi Arabia or
    /// Iran show Arabic-Indic or Persian ones, `numberDraft` too), the Arabic separators as "." and ",", and every
    /// minus or dash as "-" (U+2212 in regions like Sweden): a dash inside the number then makes it invalid ("1–5")
    /// instead of vanishing ("15").
    /// Characters a typed or pasted number may carry besides its own: spaces and apostrophes grouping thousands
    /// ("1 000", "1’000"), percent and currency signs, and the direction marks of Arabic and Persian minus signs
    /// (`numberDraft`).
    private static func isNumberOrDecoration(_ character: Character) -> Bool {
        character.isNumber || character.isWhitespace || ",.-'’%٪".contains(character)
            || character.unicodeScalars.allSatisfy { [.currencySymbol, .format].contains($0.properties.generalCategory) }
    }

    private static func asciiNumberCharacter(_ character: Character) -> Character {
        if character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first,
           scalar.properties.numericType == .decimal, let digit = character.wholeNumberValue {
            return Character(String(digit))
        }
        switch character {
        case "\u{066B}": return "."
        case "\u{066C}": return ","
        case "\u{2010}"..."\u{2015}", "\u{2212}", "\u{FE58}", "\u{FE63}", "\u{FF0D}": return "-"
        default: return character
        }
    }

    static func number(_ value: Double) -> JSONValue {
        .number(value)
    }

    /// Input text for a stored number: device locale, no thousands separators.
    static func numberDraft(_ value: Double?, locale: Locale = .current) -> String {
        guard let value else { return "" }
        return value.formatted(.number.grouping(.never).precision(.fractionLength(0...10)).locale(locale))
    }

    // MARK: Date

    /// The picked day as midnight UTC (`2026-10-09T00:00:00.000Z`), Gregorian whatever the device calendar; the web
    /// client only has a day picker, even with "include time".
    static func date(_ picked: Date) -> JSONValue {
        let day = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: picked)
        return .string(String(format: "%04d-%02d-%02dT00:00:00.000Z", day.year ?? 1970, day.month ?? 1, day.day ?? 1))
    }

    /// Picker date on the day the cell shows: midnight UTC becomes local midnight of its UTC day, other instants stay.
    static func pickerDate(_ stored: JSONValue?) -> Date? {
        guard let text = stored?.stringValue, let date = BaseFormat.parseDate(text) else { return nil }
        guard BaseFormat.isMidnightUTC(date) else { return date }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        return Calendar(identifier: .gregorian).date(from: utc.dateComponents([.year, .month, .day], from: date))
    }

    // MARK: File

    /// File cell entry after upload; `url` is server-relative (web parity).
    static func file(_ attachment: Attachment, mimeType: String) -> JSONValue {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        let name = attachment.fileName.addingPercentEncoding(withAllowedCharacters: allowed) ?? attachment.fileName
        var object: [String: JSONValue] = [
            "id": .string(attachment.id),
            "fileName": .string(attachment.fileName),
            "mimeType": .string(attachment.mimeType ?? mimeType),
            "url": .string("/api/files/\(attachment.id)/\(name)"),
        ]
        if let size = attachment.fileSize { object["fileSize"] = .number(Double(size)) }
        return .object(object)
    }

    // MARK: Select

    /// New choice ID in the web client's format.
    static func newChoiceId() -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        return "opt" + String((0..<9).map { _ in alphabet.randomElement()! })
    }

    /// Colors new options get in turn, like in the web client: Mantine's palette in its order, without black.
    static let choiceColors = ["gray", "red", "pink", "grape", "violet", "indigo", "blue", "cyan", "teal", "green", "lime", "yellow", "orange"]

    /// Options with `choice` appended, keeping a custom `choiceOrder`.
    static func typeOptions(_ options: JSONValue?, adding choice: BaseChoice) -> JSONValue {
        var object = options?.objectValue ?? [:]
        var choices = object["choices"]?.arrayValue ?? []
        choices.append(.object(["id": .string(choice.id), "name": .string(choice.name), "color": .string(choice.color)]))
        object["choices"] = .array(choices)
        let order = object["choiceOrder"]?.arrayValue ?? choices.dropLast().compactMap { $0["id"] }
        object["choiceOrder"] = .array(order + [.string(choice.id)])
        return .object(object)
    }

    // MARK: People

    /// One ID, or an array when "allow multiple" is set; none clears the cell.
    static func people(_ ids: [String], multiple: Bool) -> JSONValue? {
        guard !ids.isEmpty else { return nil }
        return multiple ? .array(ids.map(JSONValue.string)) : .string(ids[0])
    }

    static func personIds(_ value: JSONValue?) -> [String] {
        if let id = value?.stringValue { return [id] }
        return BaseLayout.stringArray(value) ?? []
    }

    static func allowsMultiplePeople(_ property: BaseProperty) -> Bool {
        property.typeOptions?["allowMultiple"]?.boolValue == true
    }
}
