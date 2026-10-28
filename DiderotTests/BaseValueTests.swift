import Foundation
import Testing
import DocmostKit
@testable import Diderot

/// Base cell values in the web client's format. The server takes only absolute URLs, so a missing `https://` is added.
@MainActor
struct BaseValueTests {
    @Test func urlAddsMissingScheme() {
        #expect(BaseValue.url("docmost.com") == .string("https://docmost.com"))
        #expect(BaseValue.url("  www.example.com/pfad?x=1 ") == .string("https://www.example.com/pfad?x=1"))
        #expect(BaseValue.url("localhost:3000/x") == .string("https://localhost:3000/x"))
    }

    @Test func urlKeepsExistingScheme() {
        #expect(BaseValue.url("http://example.com") == .string("http://example.com"))
        #expect(BaseValue.url("HTTPS://Example.com") == .string("HTTPS://Example.com"))
        #expect(BaseValue.url("mailto:team@example.com") == .string("mailto:team@example.com"))
        #expect(BaseValue.url("ftp://files.example.com") == .string("ftp://files.example.com"))
    }

    @Test func emptyLinksClearTheCell() {
        #expect(BaseValue.url("   ") == nil)
        #expect(BaseValue.email("") == nil)
        #expect(BaseValue.email(" team@example.com ") == .string("team@example.com"))
    }

    /// Only a scheme at the start counts: "://" inside a link (a query parameter) used to keep `https://` away, and the
    /// server rejects links without a scheme.
    @Test func schemeOnlyAtTheStart() {
        #expect(BaseValue.url("example.com/?next=https://x") == .string("https://example.com/?next=https://x"))
        #expect(BaseValue.url("ftp://files.example.com") == .string("ftp://files.example.com"))
        #expect(BaseValue.openURL("example.com/?next=https://x")?.absoluteString == "https://example.com/?next=https://x")
    }

    @Test func storedLinksOpenWithScheme() {
        #expect(BaseValue.openURL("docmost.com")?.absoluteString == "https://docmost.com")
        #expect(BaseValue.openURL("mailto:team@example.com")?.absoluteString == "mailto:team@example.com")
        #expect(BaseValue.openURL("https://example.com/a")?.absoluteString == "https://example.com/a")
    }

    @Test func numbersTakeCommaOrPointAsDecimalMark() {
        // Characters the parser can't read make the input invalid instead of vanishing ("1/2" was 12, "1e6" 16).
        for text in ["1/2", "3:30", "1e6", "12abc"] {
            #expect(BaseValue.parseNumber(text) == .invalid, "\(text)")
        }
        #expect(BaseValue.parseNumber("1 000") == .value(1000))
        #expect(BaseValue.parseNumber("50 %") == .value(50))
        #expect(BaseValue.parseNumber("€ 12,50", locale: Locale(identifier: "de_DE")) == .value(12.5))
        #expect(BaseValue.parseNumber("4,5") == .value(4.5))
        #expect(BaseValue.parseNumber("4.5") == .value(4.5))
        #expect(BaseValue.parseNumber("1.234,56") == .value(1234.56))
        #expect(BaseValue.parseNumber("1,234.56") == .value(1234.56))
        #expect(BaseValue.parseNumber("1,234,567") == .value(1_234_567))
        #expect(BaseValue.parseNumber("-3") == .value(-3))
    }

    /// Any dash before a number is its minus; a dash inside it makes the input invalid, it used to vanish ("1–5" → 15).
    @Test func dashesAreMinusOrInvalid() {
        #expect(BaseValue.parseNumber("\u{2013}5") == .value(-5))
        #expect(BaseValue.parseNumber("\u{2014}2,5") == .value(-2.5))
        #expect(BaseValue.parseNumber("1\u{2013}5") == .invalid)
        #expect(BaseValue.parseNumber("\u{0661}\u{0662}\u{0663}") == .value(123))
    }

    @Test func emptyNumberClearsAndTextIsRejected() {
        #expect(BaseValue.parseNumber("") == .clear)
        #expect(BaseValue.parseNumber("  ") == .clear)
        #expect(BaseValue.parseNumber("abc") == .invalid)
    }

    /// A repeated separator, or the device's grouping separator between 1–999 and exactly 3 digits, marks thousands.
    @Test func thousandsSeparatorsFollowTheDeviceLocale() {
        let english = Locale(identifier: "en_US"), german = Locale(identifier: "de_DE")
        #expect(BaseValue.parseNumber("1,000", locale: english) == .value(1000))
        #expect(BaseValue.parseNumber("1.5", locale: english) == .value(1.5))
        #expect(BaseValue.parseNumber("4,5", locale: english) == .value(4.5))
        #expect(BaseValue.parseNumber("0,500", locale: english) == .value(0.5))
        #expect(BaseValue.parseNumber("1,000,000", locale: english) == .value(1_000_000))
        #expect(BaseValue.parseNumber("1.000.000", locale: english) == .value(1_000_000))
        #expect(BaseValue.parseNumber("1.000", locale: german) == .value(1000))
        #expect(BaseValue.parseNumber("1,000", locale: german) == .value(1))
        #expect(BaseValue.parseNumber("4,5", locale: german) == .value(4.5))
        #expect(BaseValue.parseNumber("0.500", locale: german) == .value(0.5))
        #expect(BaseValue.parseNumber("1234.567", locale: german) == .value(1234.567))
        #expect(BaseValue.parseNumber("1.000,5", locale: german) == .value(1000.5))
    }

    /// A stored number's field draft parses back to it, also with the U+2212 minus of regions like Sweden and Finland
    /// and the Arabic-Indic and Persian digits of Saudi Arabia, Egypt and Iran.
    @Test(arguments: ["en_US", "de_DE", "sv_SE", "fi_FI", "ar_SA", "ar_EG", "fa_IR"])
    func numberDraftRoundTrips(identifier: String) {
        let locale = Locale(identifier: identifier)
        #expect(BaseValue.parseNumber("-", locale: locale) == .invalid)
        #expect(BaseValue.parseNumber("", locale: locale) == .clear)
        #expect(BaseValue.parseNumber("\u{2212}5", locale: locale) == .value(-5))
        #expect(BaseValue.parseNumber(BaseValue.numberDraft(1.234, locale: locale), locale: locale) == .value(1.234))
        #expect(BaseValue.parseNumber(BaseValue.numberDraft(-1.5, locale: locale), locale: locale) == .value(-1.5))
    }

    /// The picked local day is stored as midnight UTC and shows as the same day in the picker, at any hour. The stored
    /// day is Gregorian in every device calendar (without that, fails only in a region like TH: `-testRegion TH`).
    @Test(arguments: [0, 23])
    func pickedDayRoundTrips(hour: Int) throws {
        let gregorian = Calendar(identifier: .gregorian)
        let picked = try #require(gregorian.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: hour, minute: 30)))
        let stored = BaseValue.date(picked)
        #expect(stored == .string("2026-10-09T00:00:00.000Z"))
        let shown = gregorian.dateComponents([.year, .month, .day], from: try #require(BaseValue.pickerDate(stored)))
        #expect([shown.year, shown.month, shown.day] == [2026, 10, 9])
    }

    /// A stored instant other than midnight UTC (from another client) opens on its local day, the day the cell shows.
    @Test func pickerKeepsAnInstant() {
        let instant = "2026-10-09T23:00:00.000Z"
        #expect(BaseValue.pickerDate(.string(instant)) == BaseFormat.parseDate(instant))
    }

    @Test func fileEntryLinksToTheEncodedName() {
        let entry = BaseValue.file(Attachment(id: "a", fileName: "a b(1).pdf", fileSize: 3), mimeType: "application/pdf")
        #expect(entry == [
            "id": "a", "fileName": "a b(1).pdf", "mimeType": "application/pdf", "url": "/api/files/a/a%20b(1).pdf", "fileSize": 3,
        ])
        let image = BaseValue.file(Attachment(id: "b", fileName: "b.png", mimeType: "image/png"), mimeType: "application/octet-stream")
        #expect(image["mimeType"]?.stringValue == "image/png")
    }

    @Test func newChoiceKeepsTheOrder() {
        let choice = BaseChoice(id: "c", name: "C", color: "red")
        let custom = BaseValue.typeOptions(["choices": [["id": "a"], ["id": "b"]], "choiceOrder": ["b", "a"]], adding: choice)
        #expect(custom["choiceOrder"] == ["b", "a", "c"])
        let plain = BaseValue.typeOptions(["choices": [["id": "a"], ["id": "b"]]], adding: choice)
        #expect(plain["choiceOrder"] == ["a", "b", "c"])
        #expect(plain["choices"]?[2] == ["id": "c", "name": "C", "color": "red"])
    }

    @Test func newChoiceIdLooksLikeTheWebClients() {
        #expect(BaseValue.newChoiceId().wholeMatch(of: /opt[0-9a-z]{9}/) != nil)
    }

    @Test func personCellHoldsOneIdOrAnArray() {
        #expect(BaseValue.people([], multiple: true) == nil)
        #expect(BaseValue.people(["u1", "u2"], multiple: false) == .string("u1"))
        #expect(BaseValue.people(["u1", "u2"], multiple: true) == ["u1", "u2"])
        #expect(BaseValue.personIds("u1") == ["u1"])
        #expect(BaseValue.personIds(["u1", "u2"]) == ["u1", "u2"])
        #expect(BaseValue.personIds(nil) == [])
    }
}
