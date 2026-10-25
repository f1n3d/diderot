import Foundation
import SwiftUI

/// The embed providers the web editor offers. Stores the entered link (`src`) like the web; the page shows a card that
/// opens it in the browser.
enum EmbedProvider: String, CaseIterable {
    case iframe, airtable, loom, figma, typeform, miro, youtube, vimeo, framer, gdrive, gsheets

    var name: String {
        switch self {
        case .iframe: "Iframe"
        case .airtable: "Airtable"
        case .loom: "Loom"
        case .figma: "Figma"
        case .typeform: "Typeform"
        case .miro: "Miro"
        case .youtube: "YouTube"
        case .vimeo: "Vimeo"
        case .framer: "Framer"
        case .gdrive: "Google Drive"
        case .gsheets: "Google Sheets"
        }
    }

    var symbol: String {
        switch self {
        case .iframe: "globe"
        case .airtable, .gsheets: "tablecells"
        case .loom: "record.circle"
        case .figma: "paintpalette"
        case .typeform: "list.bullet.clipboard"
        case .miro: "rectangle.on.rectangle.angled"
        case .youtube, .vimeo: "play.rectangle"
        case .framer: "rectangle.on.rectangle"
        case .gdrive: "externaldrive"
        }
    }

    /// Search words besides the name.
    var searchTerms: [String] {
        switch self {
        case .iframe: ["iframe", "website", "webseite"]
        case .youtube: ["youtube", "yt", "video"]
        case .vimeo: ["vimeo", "video"]
        case .gdrive: ["google drive", "gdrive", "drive"]
        case .gsheets: ["google sheets", "gsheets", "spreadsheet"]
        default: [rawValue]
        }
    }

    /// Whether a link has the form of the provider's share or embed links (`validated` has made sure it is http or https
    /// with a host). Iframe takes any link.
    func embeds(_ url: URL) -> Bool {
        let host = url.host()?.lowercased() ?? ""
        let https = url.scheme?.lowercased() == "https"
        let parts = url.pathComponents.filter { $0 != "/" }
        func isHost(_ domain: String, _ subdomains: Set<String> = ["www"]) -> Bool {
            host == domain || subdomains.contains { host == "\($0).\(domain)" }
        }
        /// The path part at `index` if it is made of `characters` only, with at least `minimum` of them.
        func part(_ index: Int, _ characters: CharacterSet = Self.alphanumerics, minimum: Int = 1) -> String? {
            guard index < parts.count, parts[index].count >= minimum,
                  parts[index].unicodeScalars.allSatisfy(characters.contains) else { return nil }
            return parts[index]
        }
        switch self {
        case .iframe:
            return true
        case .loom:
            return isHost("loom.com") && ["share", "embed"].contains(parts.first) && part(1) != nil
        case .airtable:
            return https && isHost("airtable.com") && part(0, minimum: 2) != nil && parts.count >= 2
        case .figma:
            let kinds: Set = ["file", "proto", "board", "design", "slides", "deck"]
            return https && host.hasSuffix(".figma.com") && parts.first.map(kinds.contains) == true
                && part(1, minimum: 22).map { $0.count <= 128 } == true
        case .typeform:
            return host.hasSuffix(".typeform.com") && parts.first == "to" && parts.count >= 2
        case .miro:
            return https && isHost("miro.com") && parts.starts(with: ["app", "board"])
                && part(2, Self.identifier.union(["="]))?.hasSuffix("=") == true
        case .youtube:
            if host == "youtu.be" { return part(0, Self.identifier) != nil }
            guard isHost("youtube.com", ["www", "m", "music"]) else { return false }
            if parts == ["watch"] {
                let video = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
                return video.map { !$0.isEmpty && $0.unicodeScalars.allSatisfy(Self.identifier.contains) } ?? false
            }
            return ["embed", "v", "shorts", "live"].contains(parts.first) && part(1, Self.identifier) != nil
        case .vimeo:
            // The video's number comes last: vimeo.com/123, /video/123, /channels/name/123, /album/1/video/123 …
            return https && isHost("vimeo.com", ["www", "player"])
                && parts.contains { $0.unicodeScalars.allSatisfy(Self.digits.contains) }
        case .framer:
            return https && isHost("framer.com") && parts.first == "embed" && part(1, Self.identifier) != nil
        // Google links: the document's ID, then what to do with it (`/view`, `/edit` …).
        case .gdrive:
            return isHost("drive.google.com", ["www", "m"]) && parts.starts(with: ["file", "d"]) && part(2, Self.identifier) != nil
                && parts.count > 3
        case .gsheets:
            return isHost("docs.google.com", ["www", "m"]) && parts.starts(with: ["spreadsheets", "d"])
                && part(2, Self.identifier) != nil && parts.count > 3
        }
    }

    private static let digits = CharacterSet(charactersIn: "0123456789")
    /// ASCII letters and digits.
    private static let alphanumerics = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ").union(digits)
    /// Letters and digits plus "-" and "_", as in video and document IDs.
    private static let identifier = alphanumerics.union(["-", "_"])

    /// Cleans and checks a link: http or https with a host, in the provider's form. Without a scheme, the app adds
    /// `https://` as for database links. `nil` = invalid for this provider.
    func validated(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if !text.contains("://") { text = "https://" + text.drop(while: { $0 == "/" }) }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), host.contains(".") || host == "localhost"
        else { return nil }
        return embeds(url) ? text : nil
    }
}

/// Slash menu and "+" entries, in the web editor's order; Camera is app-only. Mermaid inserts a code block, Draw.io and
/// Excalidraw a placeholder (drawing happens in the web editor).
enum InsertCommand: Hashable, Identifiable {
    case block(BlockTemplate)
    case pageBreak, footnote
    case image, camera, video, audio, pdf, attachment
    case base, kanban
    case mathInline, mathBlock
    case mermaid, drawio, excalidraw
    case date, time, status, emoji
    case subpages, syncedBlock
    /// Docmost 0.97 and newer.
    case tabs
    case columns(Int)
    case embed(EmbedProvider)
    /// Embeds a synced block copied earlier in the app.
    case pasteSyncedBlock

    /// All entries except `pasteSyncedBlock`, in web editor order.
    static let all: [InsertCommand] = {
        var commands: [InsertCommand] = [
            .block(.paragraph), .block(.taskList), .block(.heading1), .block(.heading2), .block(.heading3),
            .block(.bulletList), .block(.orderedList), .block(.quote), .block(.codeBlock), .block(.divider),
            .pageBreak, .footnote, .image, .camera, .video, .audio, .pdf, .attachment, .block(.table), .base, .kanban,
            .block(.toggle), .tabs, .block(.callout), .mathInline, .mathBlock, .mermaid, .drawio, .excalidraw,
            .date, .time, .status, .emoji, .subpages, .syncedBlock, .columns(2), .columns(3), .columns(4), .columns(5),
        ]
        commands += EmbedProvider.allCases.map { .embed($0) }
        return commands
    }()

    var id: String {
        switch self {
        case .block(let template): "block-\(template.rawValue)"
        case .pageBreak: "page-break"
        case .footnote: "footnote"
        case .image: "image"
        case .camera: "camera"
        case .video: "video"
        case .audio: "audio"
        case .pdf: "pdf"
        case .attachment: "attachment"
        case .base: "base"
        case .kanban: "kanban"
        case .mathInline: "math-inline"
        case .mathBlock: "math-block"
        case .mermaid: "mermaid"
        case .drawio: "drawio"
        case .excalidraw: "excalidraw"
        case .date: "date"
        case .time: "time"
        case .status: "status"
        case .emoji: "emoji"
        case .subpages: "subpages"
        case .syncedBlock: "synced-block"
        case .tabs: "tabs"
        case .columns(let count): "columns-\(count)"
        case .embed(let provider): "embed-\(provider.rawValue)"
        case .pasteSyncedBlock: "paste-synced-block"
        }
    }

    /// Title in the app language.
    var title: String {
        switch self {
        case .block(let template): String(localized: template.titleResource)
        case .columns(let count): String(localized: "\(count) Columns")
        case .embed(.iframe): String(localized: "Iframe embed")
        case .embed(let provider): provider.name
        default: String(localized: titleResource)
        }
    }

    /// English title as on the web; search matches it besides the localized one.
    var englishTitle: String {
        switch self {
        case .block(let template): template.titleResource.key
        case .columns(let count): "\(count) Columns"
        case .embed(.iframe): "Iframe embed"
        case .embed(let provider): provider.name
        default: titleResource.key
        }
    }

    private var titleResource: LocalizedStringResource {
        switch self {
        case .pageBreak: "Page break"
        case .footnote: "Footnote"
        case .image: "Image"
        case .camera: "Camera"
        case .video: "Video"
        case .audio: "Audio"
        case .pdf: "Embed PDF"
        case .attachment: "File attachment"
        case .base: "Database (inline)"
        case .kanban: "Kanban"
        case .mathInline: "Math inline"
        case .mathBlock: "Math block"
        case .mermaid: "Mermaid diagram"
        case .drawio: "Draw.io (diagrams.net)"
        case .excalidraw: "Excalidraw (Whiteboard)"
        case .date: "Date"
        case .time: "Time"
        case .status: "Status"
        case .emoji: "Emoji"
        case .subpages: "Subpages"
        case .syncedBlock: "Synced block"
        case .tabs: "Tabs"
        case .pasteSyncedBlock: "Paste synced block"
        case .block, .columns, .embed: ""
        }
    }

    var symbol: String {
        switch self {
        case .block(let template): template.symbol
        case .pageBreak: "rectangle.split.1x2"
        case .footnote: "textformat.superscript"
        case .image: "photo"
        case .camera: "camera"
        case .video: "video"
        case .audio: "waveform"
        case .pdf: "doc.richtext"
        case .attachment: "paperclip"
        case .base: "tablecells.badge.ellipsis"
        case .kanban: "rectangle.3.group"
        case .mathInline: "function"
        case .mathBlock: "x.squareroot"
        case .mermaid: "flowchart"
        case .drawio: "pencil.and.outline"
        case .excalidraw: "scribble.variable"
        case .date: "calendar"
        case .time: "clock"
        case .status: "tag"
        case .emoji: "face.smiling"
        case .subpages: "list.bullet.indent"
        case .syncedBlock, .pasteSyncedBlock: "arrow.triangle.2.circlepath"
        case .tabs: "rectangle.topthird.inset.filled"
        case .columns(let count): count == 2 ? "rectangle.split.2x1" : "rectangle.split.3x1"
        case .embed(let provider): provider.symbol
        }
    }

    /// Search words besides the titles, in English and German.
    var keywords: [String] {
        switch self {
        case .block(let template):
            switch template {
            case .paragraph: ["text", "plain", "body", "absatz", "fließtext", "fliesstext"]
            case .taskList: ["todo", "checklist", "checkbox", "tasks", "aufgaben", "checkliste", "erledigen"]
            case .heading1: ["h1", "heading", "title", "überschrift", "ueberschrift", "titel"]
            case .heading2: ["h2", "heading", "section", "überschrift", "ueberschrift", "abschnitt"]
            case .heading3: ["h3", "heading", "subsection", "überschrift", "ueberschrift", "unterabschnitt"]
            case .bulletList: ["bullets", "unordered", "list", "aufzählung", "aufzaehlung", "liste", "punkte"]
            case .orderedList: ["numbered", "ordered", "list", "ol", "nummeriert", "liste", "nummern"]
            case .quote: ["quote", "citation", "blockquote", "zitat"]
            case .codeBlock: ["code", "snippet", "programming", "quelltext", "programmcode"]
            case .divider: ["hr", "separator", "line", "rule", "trennlinie", "linie", "trenner"]
            case .table: ["grid", "rows", "columns", "tabelle", "zeilen", "spalten"]
            case .toggle: ["toggle", "collapse", "expand", "details", "aufklappen", "einklappen", "ausklappbar"]
            case .callout: ["callout", "note", "info", "warning", "tip", "box", "hinweis", "warnung", "infobox"]
            }
        case .pageBreak: ["page break", "pagebreak", "print", "new page", "seitenumbruch", "umbruch", "drucken"]
        case .footnote: ["footnote", "note", "reference", "source", "fußnote", "fussnote", "anmerkung", "quelle"]
        case .image: ["picture", "photo", "upload", "gallery", "bild", "foto", "grafik"]
        case .camera: ["camera", "photo", "take", "kamera", "foto", "aufnehmen"]
        case .video: ["movie", "clip", "mp4", "upload", "film"]
        case .audio: ["sound", "music", "recording", "mp3", "upload", "ton", "musik", "aufnahme"]
        case .pdf: ["pdf", "document", "viewer", "dokument", "einbetten"]
        case .attachment: ["file", "upload", "download", "datei", "anhang", "hochladen"]
        case .base: ["database", "table", "records", "spreadsheet", "datenbank", "tabelle", "inline"]
        case .kanban: ["kanban", "board", "cards", "columns", "tasks", "karten", "tafel", "datenbank"]
        case .mathInline: ["math", "formula", "equation", "latex", "katex", "inline", "formel", "gleichung", "mathe"]
        case .mathBlock: ["math", "formula", "equation", "latex", "katex", "block", "formel", "gleichung", "matheblock", "formelblock"]
        case .mermaid: ["mermaid", "diagram", "flowchart", "chart", "uml", "diagramm", "flussdiagramm"]
        case .drawio: ["drawio", "draw.io", "diagrams.net", "diagram", "flowchart", "uml", "diagramm", "zeichnen"]
        case .excalidraw: ["excalidraw", "whiteboard", "sketch", "drawing", "skizze", "zeichnen"]
        case .date: ["date", "today", "calendar", "datum", "heute", "kalender"]
        case .time: ["time", "now", "clock", "uhrzeit", "zeit", "jetzt"]
        case .status: ["status", "label", "tag", "state", "etikett", "zustand"]
        case .emoji: ["emoji", "smiley", "icon", "emoticon", "symbol"]
        case .subpages: ["subpages", "children", "child pages", "contents", "toc", "unterseiten", "inhaltsverzeichnis", "verzeichnis"]
        case .syncedBlock: ["synced", "sync", "reuse", "shared", "transclusion", "synchronisiert", "wiederverwenden"]
        case .pasteSyncedBlock: ["paste", "synced", "sync", "einfügen", "einsetzen", "synchronisiert"]
        case .tabs: ["tabs", "tabbed", "multi", "panel", "reiter", "registerkarten"]
        case .columns(let count): ["columns", "layout", "side by side", "split", "spalten", "nebeneinander", "\(count)"]
        case .embed(let provider): provider.searchTerms + ["embed", "einbetten"]
        }
    }

    /// Inserts inline at the cursor instead of adding a block.
    var isInline: Bool {
        switch self {
        case .date, .time, .status, .emoji, .mathInline, .footnote: true
        default: false
        }
    }

    /// Converts the current block (like "Turn into") instead of inserting a new one.
    var conversionTemplate: BlockTemplate? {
        guard case .block(let template) = self, template.firstTextPath != nil, template != .table else { return nil }
        return template
    }

    /// The query is a character subsequence of a title, or part of a search word.
    func matches(_ query: String) -> Bool {
        let query = query.lowercased()
        guard !query.isEmpty else { return true }
        return Self.isSubsequence(query, of: englishTitle.lowercased()) || Self.isSubsequence(query, of: title.lowercased())
            || keywords.contains { $0.contains(query) }
    }

    func titleContains(_ query: String) -> Bool {
        let query = query.lowercased()
        return englishTitle.lowercased().contains(query) || title.lowercased().contains(query)
    }

    private static func isSubsequence(_ query: String, of target: String) -> Bool {
        var remaining = query[...]
        for character in target where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }

    /// Title matches first, as on the web; otherwise in web editor order.
    static func filtered(_ commands: [InsertCommand], query: String) -> [InsertCommand] {
        guard !query.isEmpty else { return commands }
        let matching = commands.filter { $0.matches(query) }
        return matching.filter { $0.titleContains(query) } + matching.filter { !$0.titleContains(query) }
    }
}

/// Floating "+" menu: common text blocks directly, the rest grouped (like the web toolbar) to fit on screen. Inserts
/// at the end of the page; inline entries go into a new paragraph there.
struct AddBlockMenuContent: View {
    let model: DocumentModel

    private static let basics: [InsertCommand] = [
        .block(.paragraph), .block(.heading1), .block(.heading2), .block(.bulletList), .block(.taskList), .block(.table),
    ]
    private static let moreText: [InsertCommand] = [
        .block(.heading3), .block(.orderedList), .block(.quote), .block(.codeBlock), .block(.toggle), .block(.callout),
    ]
    private static let media: [InsertCommand] = [.image, .camera, .video, .audio, .pdf, .attachment]
    private static let blocks: [InsertCommand] = [
        .block(.divider), .pageBreak, .subpages, .syncedBlock, .pasteSyncedBlock, .mathBlock, .base, .kanban,
    ]
    private static let columns: [InsertCommand] = [.columns(2), .columns(3), .columns(4), .columns(5)]
    private static let inline: [InsertCommand] = [.date, .time, .status, .emoji, .mathInline, .footnote]
    private static let diagrams: [InsertCommand] = [.mermaid, .drawio, .excalidraw]

    var body: some View {
        let available = model.availableCommands()
        ForEach(Self.basics.filter(available.contains)) { button($0) }
        group("More Text Blocks", symbol: "text.append", Self.moreText, available)
        Divider()
        group("Media", symbol: "photo.on.rectangle", Self.media, available)
        Menu {
            ForEach(Self.blocks.filter(available.contains)) { button($0) }
            group("Columns", symbol: "rectangle.split.3x1", Self.columns, available)
        } label: {
            Label("More Blocks", systemImage: "square.grid.2x2")
        }
        group("In the Text", symbol: "text.cursor", Self.inline, available)
        group("Diagrams", symbol: "flowchart", Self.diagrams, available)
        group("Embeds", symbol: "globe", EmbedProvider.allCases.map { .embed($0) }, available)
    }

    private func group(_ title: LocalizedStringKey, symbol: String, _ commands: [InsertCommand], _ available: [InsertCommand]) -> some View {
        Menu {
            ForEach(commands.filter(available.contains)) { button($0) }
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private func button(_ command: InsertCommand) -> some View {
        Button(command.title, systemImage: command.symbol) {
            model.performAtEnd(command)
        }
        .disabled(!model.isEnabled(command))
    }
}
