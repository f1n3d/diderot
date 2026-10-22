import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ObjectiveC

/// Synced blocks on the clipboard in the web editor's format: copying writes
/// `<div data-type="transclusionReference" data-source-page-id="…" data-transclusion-id="…"></div>` as HTML (so the
/// web client can paste it too), plus a custom type the app detects without reading the clipboard. Plain text holds
/// readable content, not the HTML the web client puts there: the keyboard offers it as a paste suggestion.
nonisolated enum SyncedBlockClipboard {
    struct Reference: Codable, Equatable, Sendable {
        let sourcePageId: String
        let transclusionId: String
    }

    static let appType = "io.github.f1n3d.diderot.synced-block"

    static func html(for reference: Reference) -> String {
        "<div data-type=\"transclusionReference\" data-source-page-id=\"\(reference.sourcePageId)\" data-transclusion-id=\"\(reference.transclusionId)\"></div>"
    }

    @MainActor static func copy(_ reference: Reference, text: String?) {
        let html = html(for: reference)
        let plain = text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? String(localized: "Synced block")
        var item: [String: Any] = [UTType.html.identifier: html, UTType.utf8PlainText.identifier: plain]
        if let data = try? JSONEncoder().encode(reference) { item[appType] = data }
        UIPasteboard.general.setItems([item])
    }

    /// Whether a block copied in the app is available (checkable without reading the clipboard).
    @MainActor static var hasAppContent: Bool { UIPasteboard.general.contains(pasteboardTypes: [appType]) }

    /// Block copied in the app (the paste-synced-block command is offered only when `hasAppContent` is true).
    @MainActor static func read() -> Reference? {
        UIPasteboard.general.data(forPasteboardType: appType)
            .flatMap { try? JSONDecoder().decode(Reference.self, from: $0) }
    }

    /// Extracts the reference from the web editor's HTML or text.
    static func parse(_ text: String) -> Reference? {
        guard text.contains("transclusionReference") else { return nil }
        func attribute(_ name: String) -> String? {
            guard let range = text.range(of: "\(name)=\"") else { return nil }
            let rest = text[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            let value = String(rest[..<end])
            return value.isEmpty ? nil : value
        }
        guard let source = attribute("data-source-page-id"), let id = attribute("data-transclusion-id") else { return nil }
        return Reference(sourcePageId: source, transclusionId: id)
    }
}

/// "Paste" in the active editor embeds a copied synced block as in the web client. SwiftUI has no hook, so this proxy
/// becomes `pasteDelegate` of the `TextEditor`'s UIKit text view and forwards the rest to the previous delegate.
final class SyncedBlockPasteProxy: NSObject, UITextPasteDelegate {
    // Also read by `responds(to:)`/`forwardingTarget(for:)`, which UIKit calls nonisolated, always on the main thread.
    private nonisolated weak let previous: (any UITextPasteDelegate)?
    private let onReference: @MainActor (SyncedBlockClipboard.Reference) -> Void
    private static var key: UInt8 = 0

    private init(previous: (any UITextPasteDelegate)?, onReference: @escaping @MainActor (SyncedBlockClipboard.Reference) -> Void) {
        self.previous = previous
        self.onReference = onReference
    }

    /// Attaches the proxy to the currently focused text view (once per view).
    @MainActor static func install(onReference: @escaping @MainActor (SyncedBlockClipboard.Reference) -> Void) {
        guard let textView = FirstResponder.current as? UITextView else { return }
        if let proxy = objc_getAssociatedObject(textView, &key) as? SyncedBlockPasteProxy, textView.pasteDelegate === proxy {
            return
        }
        let proxy = SyncedBlockPasteProxy(previous: textView.pasteDelegate, onReference: onReference)
        // `pasteDelegate` is weak; the text view retains the proxy itself.
        objc_setAssociatedObject(textView, &key, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        textView.pasteDelegate = proxy
    }

    // The previous delegate handles everything except transforming the pasted items.
    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (previous?.responds(to: selector) ?? false)
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        previous?.responds(to: selector) == true ? previous : nil
    }

    func textPasteConfigurationSupporting(_ supporting: any UITextPasteConfigurationSupporting, transform item: any UITextPasteItem) {
        let provider = item.itemProvider
        // Loading calls back on a background thread; finishing runs on the main thread.
        let context = PasteContext(item: item, supporting: supporting, previous: previous, onReference: onReference)
        let finish: @Sendable (SyncedBlockClipboard.Reference?) -> Void = { reference in
            Task { @MainActor in context.finish(with: reference) }
        }
        if provider.hasItemConformingToTypeIdentifier(SyncedBlockClipboard.appType) {
            _ = provider.loadDataRepresentation(forTypeIdentifier: SyncedBlockClipboard.appType) { data, _ in
                finish(data.flatMap { try? JSONDecoder().decode(SyncedBlockClipboard.Reference.self, from: $0) })
            }
        } else if let type = [UTType.html, UTType.utf8PlainText, UTType.plainText].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                finish(data.flatMap { String(data: $0, encoding: .utf8) }.flatMap(SyncedBlockClipboard.parse))
            }
        } else {
            context.finish(with: nil)
        }
    }
}

/// One in-flight paste: either as a synced block or unchanged via the previous delegate.
private final class PasteContext {
    private let item: any UITextPasteItem
    private let supporting: any UITextPasteConfigurationSupporting
    private weak var previous: (any UITextPasteDelegate)?
    private let onReference: @MainActor (SyncedBlockClipboard.Reference) -> Void

    init(item: any UITextPasteItem, supporting: any UITextPasteConfigurationSupporting, previous: (any UITextPasteDelegate)?,
         onReference: @escaping @MainActor (SyncedBlockClipboard.Reference) -> Void) {
        self.item = item
        self.supporting = supporting
        self.previous = previous
        self.onReference = onReference
    }

    func finish(with reference: SyncedBlockClipboard.Reference?) {
        if let reference {
            item.setNoResult()
            onReference(reference)
        } else if let previous, previous.responds(to: #selector(UITextPasteDelegate.textPasteConfigurationSupporting(_:transform:))) {
            previous.textPasteConfigurationSupporting?(supporting, transform: item)
        } else {
            item.setDefaultResult()
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
