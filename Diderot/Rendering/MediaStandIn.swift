import SwiftUI
import DocmostKit

/// What a media view shows in place of a file that isn't showing. The media views (image, diagram, PDF, the image
/// viewer's page) share these four and what a tap does in each: each had its own, with its own gaps (code review S3f).
enum MediaStandIn: Equatable {
    /// From another server: it loads after a tap (`RenderContext.loadsByItself`).
    case otherServer(URL)
    /// Over `MediaLoader.maxAutomaticBytes`: it loads after a tap.
    case large
    /// It didn't load: `reason` in the error's words, nil for a file that isn't what the view shows. A tap loads again.
    case failed(reason: String?)
    case loading

    /// The line under a large file's name: its size where the page knows it.
    static func largeDetail(size: Int?) -> String {
        let limit = ByteCountFormatter.string(fromByteCount: MediaLoader.maxAutomaticBytes, countStyle: .file)
        let text = size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? String(localized: "Larger than \(limit)")
        return String(localized: "\(text). Tap to load.")
    }

    /// The line under a failed file's name: the view's own words, the reason, and what a tap does.
    static func failureDetail(_ words: String, reason: String?) -> String {
        // A server's message often ends without a period ("Invalid file id") and would run into the next sentence.
        let reason = reason.map { $0.last.map { ".!?…".contains($0) } == false ? $0 + "." : $0 }
        return [words, reason, String(localized: "Tap to try again.")].compactMap(\.self).joined(separator: " ")
    }
}

/// The taps a media view has taken for its file. A view is made anew for another file (`BlockView`), so they hold for
/// that file only. As a task's id, each tap loads again.
struct MediaGate: Hashable {
    var loadsFromOtherServer = false
    var loadsLargeFile = false
    /// Counts the taps on a failure.
    var attempt = 0

    /// The most a load may bring by itself; nil once a tap allowed more.
    var maxBytes: Int64? { loadsLargeFile ? nil : MediaLoader.maxAutomaticBytes }

    /// What stands in before a load; nil if the file may load.
    func standIn(before url: URL, in context: RenderContext) -> MediaStandIn? {
        context.loadsByItself(url) || loadsFromOtherServer ? nil : .otherServer(url)
    }

    /// What stands in after a load failed; nil for one that was cancelled (scrolled past, another width): no failure,
    /// and the next load's spinner stays.
    static func standIn(after error: any Error) -> MediaStandIn? {
        if error is CancellationError || Task.isCancelled { return nil }
        if case APIError.tooLarge = error { return .large }
        if error is MediaUnreadable { return .failed(reason: nil) }
        return .failed(reason: error.userMessage)
    }
}

/// A file that loaded but isn't what the view shows: no image, no SVG, no PDF.
struct MediaUnreadable: Error {}

/// The stand-in as a card, for the media that show as one (a diagram, a PDF, the viewer's page), and for an image
/// from another server or too large.
struct MediaStandInCard: View {
    let standIn: MediaStandIn
    let icon: String
    let title: String
    /// The view's words for a failure ("PDF could not be loaded.").
    let failure: String
    /// The file's size, where the page knows it.
    var size: Int?
    @Binding var gate: MediaGate

    var body: some View {
        switch standIn {
        case .otherServer(let url):
            OtherServerCard(icon: icon, title: title, url: url) { gate.loadsFromOtherServer = true }
        case .large:
            Button { gate.loadsLargeFile = true } label: {
                PlaceholderCard(icon: icon, title: title, detail: MediaStandIn.largeDetail(size: size))
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Loads it"))
        case .failed(let reason):
            Button { gate.attempt += 1 } label: {
                PlaceholderCard(icon: icon, title: title, detail: MediaStandIn.failureDetail(failure, reason: reason))
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Loads it again"))
        case .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: 80)
        }
    }
}
