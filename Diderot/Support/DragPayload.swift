import SwiftUI
import UniformTypeIdentifiers

/// The app's own drags (page tree rows, blocks, kanban cards) carry "prefix + id" as a private type that only this app
/// sees: other apps get no ids as text, and text dragged in from them isn't taken for one of these drags.
enum DragPayload {
    /// Declared in Info.plist.
    nonisolated static let type = UTType(exportedAs: "io.github.f1n3d.diderot.drag")
    static let types = [type]

    /// For `.onDrag` and UIKit drags.
    static func provider(_ payload: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(Data(payload.utf8), nil)
            return nil
        }
        return provider
    }

    /// For `.draggable`.
    nonisolated struct Item: Transferable {
        let payload: String

        static var transferRepresentation: some TransferRepresentation {
            DataRepresentation(exportedContentType: DragPayload.type) { Data($0.payload.utf8) }.visibility(.ownProcess)
        }
    }

    /// Reads the dragged id from the drop and hands it to `then` on the main actor; `false` without a payload.
    @discardableResult
    static func load(_ info: DropInfo, prefix: String, then: @escaping @MainActor @Sendable (String) -> Void) -> Bool {
        guard let provider = info.itemProviders(for: types).first else { return false }
        _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let text = data.map({ String(decoding: $0, as: UTF8.self) }), text.hasPrefix(prefix) else { return }
            let id = String(text.dropFirst(prefix.count))
            Task { @MainActor in then(id) }
        }
        return true
    }
}
