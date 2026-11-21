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

    /// Where a file field's entry loads from: its URL, else the server's file, its id and name encoded as path
    /// components (a "#" or "?" in the name cut the path short).
    static func fileURL(url: String?, id: String, name: String, server: URL) -> URL? {
        if let url { return ImageURL.resolveContentMedia(url, baseURL: server) }
        return server.appending(path: "api/files").appending(component: id).appending(component: name)
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

    /// Characters a typed or pasted number may carry besides its own: spaces and apostrophes grouping thousands
    /// ("1 000", "1’000"), percent and currency signs, and the direction marks of Arabic and Persian minus signs
    /// (`numberDraft`).
    private static func isNumberOrDecoration(_ character: Character) -> Bool {
        character.isNumber || character.isWhitespace || ",.-'’%٪".contains(character)
            || character.unicodeScalars.allSatisfy { [.currencySymbol, .format].contains($0.properties.generalCategory) }
    }

    /// Number characters as the parser reads them: decimal digits of any script as ASCII (regions like Saudi Arabia or
    /// Iran show Arabic-Indic or Persian ones, `numberDraft` too), the Arabic separators as "." and ",", and every
    /// minus or dash as "-" (U+2212 in regions like Sweden): a dash inside the number then makes it invalid ("1–5")
    /// instead of vanishing ("15").
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

    /// Whether a date is written as Docmost 0.98 stores it (`{start, end?}`, `BaseDateCell`) or as the string of older
    /// servers. A cell that holds the new form is on 0.98 or newer, also where the server's version is unknown: a range
    /// kept as a string would lose its end.
    static func writesDateObject(onDocmost098: Bool, replacing current: BaseDateCell?) -> Bool {
        onDocmost098 || current?.isLegacy == false
    }

    /// The cell after the picker set `picked` (`BaseDateEditor`). In the new form the start is the picked day, or with
    /// time the picked moment; a range keeps its end while that comes after the new start, and moves with the start when
    /// only its time changed (the web's `pickDay` and `setTimeOfDay`). Older servers store the picked day as a string at
    /// midnight UTC: their web client picks days only, also with "include time". Days are Gregorian whatever the device
    /// calendar.
    static func date(
        _ picked: Date, kind: BaseDateKind, replacing current: BaseDateCell?, onDocmost098: Bool, timeZone: TimeZone = .current
    ) -> JSONValue {
        let day = CalendarDay(containing: picked, in: timeZone)
        guard writesDateObject(onDocmost098: onDocmost098, replacing: current) else {
            return BaseDateCell(start: .day(day)).value(asObject: false)
        }
        let start: BaseDateCell.Part = kind == .datetime ? .instant(picked) : .day(day)
        var end = current?.end
        if case .instant(let old)? = current?.start, case .instant(let oldEnd)? = end, case .instant(let new) = start,
           CalendarDay(containing: old, in: timeZone) == day {
            end = .instant(oldEnd.addingTimeInterval(new.timeIntervalSince(old)))
        }
        return BaseDateCell(start: start, end: end).value(asObject: true)
    }

    /// The cell after the end's picker set `picked` (Docmost 0.98, "End Date" on): the end is the picked day, or with time
    /// the picked moment, while that comes after the start, else the cell keeps its start alone. A day before the start's
    /// moves the start there instead, at its time of day, and the range ends where it ended (the web's `pickDay` and
    /// `setTimeOfDay` for the end; a cell without an end ends at its old start then).
    static func end(_ picked: Date, kind: BaseDateKind, of cell: BaseDateCell, timeZone: TimeZone = .current) -> JSONValue {
        let day = CalendarDay(containing: picked, in: timeZone)
        if day < cell.start.day(in: timeZone) {
            return BaseDateCell(start: moved(cell.start, to: day, timeZone: timeZone), end: cell.end ?? cell.start).value(asObject: true)
        }
        let end: BaseDateCell.Part = kind == .datetime ? .instant(picked) : .day(day)
        return BaseDateCell(start: cell.start, end: end).value(asObject: true)
    }

    /// The cell once "End Date" is turned on or off (Docmost 0.98), nil where nothing changes: off ends a range; on gives
    /// a moment without an end one an hour later, as the web's picker does, while a day waits for its end to be picked.
    static func endShown(_ on: Bool, kind: BaseDateKind, of cell: BaseDateCell) -> JSONValue? {
        guard on else {
            // Not `cell.end == nil ? nil : …`: there `nil` is JSONValue's null, which would empty the cell.
            guard cell.end != nil else { return nil }
            return BaseDateCell(start: cell.start).value(asObject: true)
        }
        guard kind == .datetime, cell.end == nil, case .instant(let start) = cell.start else { return nil }
        return BaseDateCell(start: cell.start, end: .instant(start.addingTimeInterval(3_600))).value(asObject: true)
    }

    /// `part` on another day: a day is that day, a moment keeps its time of day in `timeZone` (the web's `moveToDay`).
    private static func moved(_ part: BaseDateCell.Part, to day: CalendarDay, timeZone: TimeZone) -> BaseDateCell.Part {
        guard case .instant(let date) = part else { return .day(day) }
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        var components = local.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let ymd = utc.dateComponents([.year, .month, .day], from: day.date)
        (components.year, components.month, components.day) = (ymd.year, ymd.month, ymd.day)
        return .instant(local.date(from: components) ?? date)
    }

    /// The date "Add Date" sets: today; with time on Docmost 0.98 at 9:00, where the web's picker starts a new date.
    static func today(kind: BaseDateKind, onDocmost098: Bool, now: Date = .now, timeZone: TimeZone = .current) -> JSONValue {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let picked = kind == .datetime && onDocmost098 ? calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now) ?? now : now
        return date(picked, kind: kind, replacing: nil, onDocmost098: onDocmost098, timeZone: timeZone)
    }

    /// The picker's date for a cell: its start, a moment as it is where the picker shows time, else the day the cell
    /// shows (`BaseDateCell.Part.day(in:)`) at the device's midnight, where the picker shows it.
    static func pickerDate(_ cell: BaseDateCell, withTime: Bool, timeZone: TimeZone = .current) -> Date {
        if withTime, case .instant(let date) = cell.start { return date }
        let day = cell.start.day(in: timeZone)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        return local.date(from: utc.dateComponents([.year, .month, .day], from: day.date)) ?? day.date
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
