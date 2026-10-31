import SwiftUI
import UIKit
import WebKit
import DocmostKit

/// An image or diagram the full-screen viewer shows (`MediaViewer`).
struct ViewerMedia: Hashable {
    let src: String
    /// The image's alt text, the diagram's file name.
    let title: String?
    let isDiagram: Bool

    /// Nil without a file: there is nothing to show.
    init?(src: String?, title: String?, isDiagram: Bool) {
        guard let src, !src.isEmpty else { return nil }
        self.src = src
        self.title = title
        self.isDiagram = isDiagram
    }

    /// The images and diagrams of `document` in reading order, as the web's lightbox pages through them.
    static func all(in document: ContentDocument) -> [ViewerMedia] {
        all(in: document.blocks + document.footnotes.flatMap(\.blocks))
    }

    private static func all(in blocks: [Block]) -> [ViewerMedia] {
        blocks.flatMap { block -> [ViewerMedia] in
            switch block.kind {
            case .image(let image):
                ViewerMedia(src: image.src, title: image.alt, isDiagram: false).map { [$0] } ?? []
            case .media(let media) where media.kind == .drawio || media.kind == .excalidraw:
                ViewerMedia(src: media.src, title: media.name, isDiagram: true).map { [$0] } ?? []
            case .blockquote(let blocks), .callout(_, _, let blocks), .details(_, _, let blocks), .transclusionSource(let blocks),
                 .unknown(_, let blocks):
                all(in: blocks)
            case .bulletList(let items), .orderedList(let items):
                items.flatMap { all(in: $0.blocks) }
            case .taskList(let items):
                items.flatMap { all(in: $0.blocks) }
            case .table(let table):
                table.rows.flatMap { $0.cells.flatMap { all(in: $0.blocks) } }
            case .columns(let columns, _):
                columns.flatMap { all(in: $0) }
            case .tabs(let tabs):
                tabs.flatMap { all(in: $0.blocks) }
            default:
                []
            }
        }
    }
}

/// Opens an image or diagram full screen (`View.mediaViewer`).
struct OpenMediaAction {
    let open: (ViewerMedia) -> Void

    func callAsFunction(_ media: ViewerMedia) { open(media) }
}

extension EnvironmentValues {
    /// Nil where no view around shows the viewer.
    @Entry var openMedia: OpenMediaAction?
}

extension View {
    /// Shows a tapped image or diagram full screen, with the others of `document` (read at the tap) to swipe to.
    func mediaViewer(_ document: @escaping () -> ContentDocument) -> some View {
        modifier(MediaViewerHost(document: document))
    }

    /// A tap opens `media` full screen, where a view around shows the viewer.
    func opensFullScreen(_ media: ViewerMedia?) -> some View {
        modifier(OpensFullScreen(media: media))
    }
}

private struct MediaViewerHost: ViewModifier {
    let document: () -> ContentDocument
    @State private var shown: Shown?

    private struct Shown: Identifiable {
        let id = UUID()
        let items: [ViewerMedia]
        let index: Int
    }

    func body(content: Content) -> some View {
        content
            .environment(\.openMedia, OpenMediaAction { media in
                let items = ViewerMedia.all(in: document())
                // Not among them (in a synced block from another page): it alone.
                if let index = items.firstIndex(where: { $0.src == media.src }) {
                    shown = Shown(items: items, index: index)
                } else {
                    shown = Shown(items: [media], index: 0)
                }
            })
            .fullScreenCover(item: $shown) { MediaViewer(items: $0.items, index: $0.index) }
    }
}

private struct OpensFullScreen: ViewModifier {
    let media: ViewerMedia?
    @Environment(\.openMedia) private var openMedia

    func body(content: Content) -> some View {
        if let openMedia, let media {
            content
                // Above a diagram's WebView, which would otherwise take the taps.
                .overlay {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { openMedia(media) }
                }
                .accessibilityHint(Text("Opens it full screen"))
                .accessibilityAction { openMedia(media) }
        } else {
            content
        }
    }
}

/// Images and diagrams full screen, as the web's lightbox shows them: they zoom up to 4× (pinch, double tap), swipe to
/// the page's others, and share (the web's download). The button or a pull down closes it.
struct MediaViewer: View {
    let items: [ViewerMedia]
    @State private var index: Int
    /// The loaded ones as files, for sharing.
    @State private var files: [Int: URL] = [:]
    @Environment(\.dismiss) private var dismiss

    init(items: [ViewerMedia], index: Int) {
        self.items = items
        _index = State(initialValue: index)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Above the pages, not over them: on an iPad the paging view takes the taps over it.
            HStack {
                Button("Close", systemImage: "xmark") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("media-viewer-close")
                Spacer()
                if let file = files[index] {
                    ShareLink(item: file)
                        .accessibilityIdentifier("media-viewer-share")
                }
            }
            .overlay {
                if items.count > 1 {
                    Text("\(index + 1) of \(items.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("media-viewer-counter")
                }
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .padding(.horizontal)
            .padding(.top, 8)
            TabView(selection: $index) {
                ForEach(items.indices, id: \.self) { index in
                    MediaViewerPage(media: items[index]) { dismiss() } loaded: { files[index] = $0 }
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(Color(.systemBackground))
    }
}

/// One image or diagram, loaded when its page is built.
private struct MediaViewerPage: View {
    let media: ViewerMedia
    let close: () -> Void
    /// Gets the file to share once it shows.
    let loaded: (URL) -> Void
    @Environment(\.renderContext) private var context
    @State private var image: UIImage?
    @State private var markup: String?
    @State private var failed = false
    @State private var loadsFromOtherServer = false

    private var title: String { media.title ?? (media.isDiagram ? String(localized: "Diagram") : String(localized: "Image")) }

    var body: some View {
        Group {
            if let image {
                ZoomableImage(image: image, label: title, close: close)
            } else if let markup {
                ZoomableDiagram(markup: markup, label: title, close: close)
            } else if let url = context.mediaURL(media.src), !context.loadsByItself(url), !loadsFromOtherServer {
                OtherServerCard(icon: media.isDiagram ? "pencil.and.outline" : "photo", title: title, url: url) { loadsFromOtherServer = true }
                    .padding()
            } else if failed {
                Label(media.isDiagram ? "Diagram could not be loaded." : "Image unavailable", systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: loadsFromOtherServer) { await load() }
    }

    private func load() async {
        guard let loader = context.imageLoader, let url = context.mediaURL(media.src),
              context.loadsByItself(url) || loadsFromOtherServer else { return }
        failed = false
        do {
            let data = try await loader.data(for: url)
            if media.isDiagram {
                markup = DiagramView.svg(in: data)
            } else {
                // As sharp as the loader decodes at all (`ImageLoader.maxPixels`): the viewer zooms to 4×.
                image = await ImageLoader.decode(data, targetPixelWidth: 16_384)
            }
            failed = markup == nil && image == nil
            // Shared as the web downloads it: the file with its name.
            if !failed, let server = context.baseURL,
               let file = try? TempFile.write(data, server: server, folder: ["attachments", url.deletingLastPathComponent().lastPathComponent],
                                              name: url.lastPathComponent) {
                loaded(file)
            }
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}

/// UIKit's scroll view zooms the image (SwiftUI's doesn't on iOS).
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    let label: String
    let close: () -> Void

    func makeUIView(context: Context) -> ImageZoomView {
        ImageZoomView(image: image)
    }

    func updateUIView(_ view: ImageZoomView, context: Context) {
        view.imageView.accessibilityLabel = label
        view.close = close
    }
}

/// Fits the image, zooms it up to 4× (pinch, double tap) and pans it; pulled down at its normal size, it closes.
final class ImageZoomView: UIScrollView, UIScrollViewDelegate {
    let imageView: UIImageView
    var close: () -> Void = {}
    /// The size the image was last fitted into.
    private var fittedSize: CGSize = .zero

    init(image: UIImage) {
        imageView = UIImageView(image: image)
        super.init(frame: .zero)
        delegate = self
        maximumZoomScale = 4
        // Pulls down at the normal size too; sideways the pages swipe.
        alwaysBounceVertical = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A new size (first layout, rotation) fits the image again, at the normal size.
        guard bounds.size != fittedSize, let size = imageView.image?.size, size.width > 0, size.height > 0 else { return }
        fittedSize = bounds.size
        zoomScale = 1
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        imageView.frame = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        contentSize = imageView.frame.size
        centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let pulled = -(contentOffset.y + contentInset.top)
        // Velocity in points per millisecond, negative downwards.
        if zoomScale <= minimumZoomScale, pulled > 80 || (pulled > 20 && velocity.y < -1) { close() }
    }

    /// Insets that keep an image smaller than the view in its middle.
    private func centerImage() {
        let x = max((bounds.width - contentSize.width) / 2, 0)
        let y = max((bounds.height - contentSize.height) / 2, 0)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    /// 2× around the tapped point, or back to the normal size.
    @objc private func toggleZoom(_ tap: UITapGestureRecognizer) {
        guard zoomScale <= minimumZoomScale else { return setZoomScale(minimumZoomScale, animated: true) }
        let point = tap.location(in: imageView)
        let size = CGSize(width: imageView.bounds.width / 2, height: imageView.bounds.height / 2)
        zoom(to: CGRect(origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size), animated: true)
    }
}

/// WebKit draws the diagram sharp at every zoom, up to 4× (pinch, double tap); pulled down at its normal size, it
/// closes. A WKWebView per view: SwiftUI's WebView traps when the paging view builds a page twice (one `WebPage`, two
/// views), and its HTML has nothing to navigate to (an `<img>`).
private struct ZoomableDiagram: UIViewRepresentable {
    let markup: String
    let label: String
    let close: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.isOpaque = false
        view.backgroundColor = .clear
        view.allowsLinkPreview = false
        view.isAccessibilityElement = true
        view.scrollView.alwaysBounceVertical = true
        view.scrollView.panGestureRecognizer.addTarget(context.coordinator, action: #selector(Coordinator.panned))
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.toggleZoom))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = context.coordinator
        view.addGestureRecognizer(doubleTap)
        view.loadHTMLString(IslandHTML.svg(markup, zoomable: true), baseURL: IslandHTML.baseURL)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        view.accessibilityLabel = label
        context.coordinator.close = close
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var close: () -> Void = {}

        @objc func panned(_ pan: UIPanGestureRecognizer) {
            guard pan.state == .ended, let scrollView = pan.view as? UIScrollView,
                  scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return }
            if -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top) > 80 { close() }
        }

        /// 2× around the tapped point, or back to the normal size, as for images: WebKit's own double tap (off in the
        /// HTML) zooms to the `<img>`, which already fills the view.
        @objc func toggleZoom(_ tap: UITapGestureRecognizer) {
            guard let scrollView = (tap.view as? WKWebView)?.scrollView else { return }
            guard scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else {
                return scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            }
            // In the zoomed content's points: the scroll view's divided by the scale (its zoom delegate is WebKit's own).
            let scale = scrollView.zoomScale, point = tap.location(in: scrollView)
            let size = CGSize(width: scrollView.bounds.width / (2 * scale), height: scrollView.bounds.height / (2 * scale))
            scrollView.zoom(to: CGRect(x: point.x / scale - size.width / 2, y: point.y / scale - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
        }

        /// Beside WebKit's own tap recognizers.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}
