import SwiftUI
import DocmostKit

/// Image from page content: reserves space from its attributes, loads via `MediaLoader`.
struct ContentImageView: View {
    let image: ImageBlock
    @Environment(\.renderContext) private var context
    @Environment(\.displayScale) private var displayScale
    @State private var loaded: UIImage?
    @State private var standIn = MediaStandIn.loading
    @State private var gate = MediaGate()
    @State private var availableWidth: CGFloat = 0

    private var url: URL? { context.mediaURL(image.src) }

    var body: some View {
        HStack {
            if image.align == .center || image.align == .right { Spacer(minLength: 0) }
            content
                .frame(width: targetWidth)
            if image.align == .center || image.align == .left { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .task(id: TaskKey(url: url, width: targetWidth, gate: gate)) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let loaded {
            Image(uiImage: loaded)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel(image.alt ?? String(localized: "Image"))
                .opensFullScreen(ViewerMedia(src: image.src, title: image.alt, isDiagram: false))
        } else {
            switch standIn {
            case .loading:
                placeholder { ProgressView() }
            case .failed(let reason):
                Button { gate.attempt += 1 } label: {
                    placeholder {
                        VStack(spacing: 4) {
                            Label("Image unavailable", systemImage: "photo.badge.exclamationmark")
                            if let reason { Text(reason) }
                            Text("Tap to try again.")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(8)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Loads it again"))
            case .otherServer, .large:
                MediaStandInCard(standIn: standIn, icon: "photo", title: image.alt ?? String(localized: "Image"),
                                 failure: String(localized: "Image unavailable"), gate: $gate)
            }
        }
    }

    private func placeholder(@ViewBuilder _ label: () -> some View) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(.secondarySystemFill))
            .aspectRatio(image.aspectRatio ?? 16 / 9, contentMode: .fit)
            .overlay { label() }
    }

    /// Width from the attribute (points or percent), capped at the available width.
    private var targetWidth: CGFloat? {
        guard availableWidth > 0 else { return nil }
        switch image.width {
        case .points(let points) where points > 0: return min(CGFloat(points), availableWidth)
        case .percent(let percent): return availableWidth * CGFloat(min(max(percent, 5), 100)) / 100
        // No width, or none to use (zero, negative).
        default: return availableWidth
        }
    }

    private struct TaskKey: Equatable {
        let url: URL?
        let width: CGFloat?
        let gate: MediaGate
    }

    private func load() async {
        guard let url, let loader = context.mediaLoader else { return }
        if let waits = gate.standIn(before: url, in: context) { return standIn = waits }
        guard let width = targetWidth else { return }
        // Another width (a rotation) keeps the image it has until the new one is there.
        if loaded == nil { standIn = .loading }
        do {
            loaded = try await loader.image(for: url, targetWidth: width, scale: displayScale, maxBytes: gate.maxBytes)
        } catch {
            guard let failed = MediaGate.standIn(after: error) else { return }
            standIn = failed
            // File names are user content and logs can be exported, so only the folder, as the client logs it.
            AppLog.ui.debug("Image failed: \(url.deletingLastPathComponent().path, privacy: .public) – \(error.userMessage, privacy: .public)")
        }
    }
}
