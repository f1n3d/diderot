import SwiftUI
import DocmostKit

/// Image from page content: reserves space from its attributes, loads via `ImageLoader`.
struct ContentImageView: View {
    let image: ImageBlock
    @Environment(\.renderContext) private var context
    @Environment(\.displayScale) private var displayScale
    @State private var loaded: UIImage?
    @State private var failed = false
    @State private var availableWidth: CGFloat = 0
    @State private var loadsFromOtherServer = false

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
        .task(id: TaskKey(url: url, width: targetWidth, allowed: loadsFromOtherServer)) { await load() }
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
        } else if let url, !context.loadsByItself(url), !loadsFromOtherServer {
            OtherServerCard(icon: "photo", title: image.alt ?? String(localized: "Image"), url: url) { loadsFromOtherServer = true }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(.secondarySystemFill))
            .aspectRatio(image.aspectRatio ?? 16 / 9, contentMode: .fit)
            .overlay {
                if failed {
                    Label("Image unavailable", systemImage: "photo.badge.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
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
        let allowed: Bool
    }

    private func load() async {
        guard let url, let loader = context.imageLoader, let width = targetWidth,
              context.loadsByItself(url) || loadsFromOtherServer else { return }
        failed = false
        do {
            loaded = try await loader.image(for: url, targetWidth: width, scale: displayScale)
        } catch {
            failed = true
            // File names are user content and logs can be exported, so only the folder, as `fetchFile` logs it.
            AppLog.ui.debug("Image failed: \(url.deletingLastPathComponent().path, privacy: .public) – \(error.userMessage, privacy: .public)")
        }
    }
}
