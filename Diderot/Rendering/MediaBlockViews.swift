import SwiftUI
import AVKit
import PDFKit
import QuickLook
import DocmostKit

// MARK: - Math, Mermaid, diagrams

struct MathBlockView: View {
    let latex: String

    var body: some View {
        WebIslandView(html: IslandHTML.math(latex, displayMode: true), minHeight: 48)
            .accessibilityLabel("Math: \(latex)")
    }
}

struct MermaidView: View {
    let code: String
    @State private var showsSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            WebIslandView(html: IslandHTML.mermaid(code), minHeight: 80)
                .accessibilityLabel("Mermaid diagram")
            Button(showsSource ? "Hide source" : "Show source") { showsSource.toggle() }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            if showsSource {
                CodeBlockView(language: "mermaid", code: code)
            }
        }
    }
}

/// Draw.io and Excalidraw diagrams are stored as SVG behind the API.
struct DiagramView: View {
    let media: MediaBlock
    @Environment(\.renderContext) private var context
    @State private var markup: String?
    @State private var loadedSrc: String?
    @State private var failed = false

    var body: some View {
        Group {
            if let markup {
                WebIslandView(html: IslandHTML.svg(markup), minHeight: 80)
                    .accessibilityLabel(media.name ?? String(localized: "Diagram"))
            } else if failed {
                PlaceholderCard(icon: "pencil.and.outline", title: media.name ?? media.kind.title,
                                detail: String(localized: "Diagram could not be loaded."))
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .task(id: media.src) { await load() }
    }

    private func load() async {
        // Back in view (scrolling, returning to the page): keep the diagram instead of reloading.
        guard markup == nil || loadedSrc != media.src else { return }
        failed = false
        // A new file that fails shows the error, not the previous file.
        func fail() { markup = nil; failed = true }
        guard let loader = context.imageLoader, let url = context.mediaURL(media.src) else { return fail() }
        do {
            let data = try await loader.data(for: url)
            guard let text = String(data: data, encoding: .utf8), text.contains("<svg") else { return fail() }
            // Keep only the <svg> element (drop the XML prolog).
            markup = text[text.range(of: "<svg")!.lowerBound...].description
            loadedSrc = media.src
        } catch {
            // Scrolling past or opening another page cancels the download; it starts again on return.
            if !Task.isCancelled { fail() }
        }
    }
}

// MARK: - Video / Audio

struct VideoBlockView: View {
    let media: MediaBlock
    @Environment(\.renderContext) private var context
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(media.kind == .audio ? nil : 16 / 9, contentMode: .fit)
                    .frame(height: media.kind == .audio ? 64 : nil)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                PlaceholderCard(icon: media.kind == .audio ? "waveform" : "video", title: media.name ?? media.kind.title,
                                detail: String(localized: "Media unavailable."))
            }
        }
        .task(id: media.src) {
            // Back in view: keep the player where it paused; retry one that failed to load (offline).
            guard let url = context.mediaURL(media.src),
                  player?.currentItem?.status == .failed || (player?.currentItem?.asset as? AVURLAsset)?.url != url else { return }
            var options: [String: Any] = [:]
            if let cookie = context.authCookie() {
                // The server checks the cookie before the bearer header; AVFoundation can't set custom headers.
                options[AVURLAssetHTTPCookiesKey] = [cookie]
            }
            let asset = AVURLAsset(url: url, options: options)
            player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        }
        .onDisappear { player?.pause() }
    }
}

// MARK: - PDF

struct PDFBlockView: View {
    let media: MediaBlock
    @Environment(\.renderContext) private var context
    @State private var document: PDFDocument?
    @State private var loadedSrc: String?
    @State private var failed = false
    @State private var showsFullScreen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let document {
                // A tap opens the full-screen view, also on a link: links open there.
                PDFKitView(document: document, followsLinks: false)
                    .frame(height: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(.separator)))
                    .onTapGesture { showsFullScreen = true }
                HStack {
                    Label(media.name ?? "PDF", systemImage: "doc.richtext").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open") { showsFullScreen = true }.font(.caption)
                }
            } else if failed {
                PlaceholderCard(icon: "doc.richtext", title: media.name ?? "PDF", detail: String(localized: "PDF could not be loaded."))
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .task(id: media.src) { await load() }
        .sheet(isPresented: $showsFullScreen) {
            if let document {
                NavigationStack {
                    PDFKitView(document: document)
                        .ignoresSafeArea(edges: .bottom)
                        .navigationTitle(media.name ?? "PDF")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .opensExternalLinks()
            }
        }
    }

    private func load() async {
        // Back in view: keep the PDF at its current page instead of reloading.
        guard document == nil || loadedSrc != media.src else { return }
        failed = false
        // A new file that fails shows the error, not the previous file.
        func fail() { document = nil; failed = true }
        guard let loader = context.imageLoader, let url = context.mediaURL(media.src) else { return fail() }
        do {
            let data = try await loader.data(for: url)
            if let pdf = PDFDocument(data: data) { document = pdf; loadedSrc = media.src } else { fail() }
        } catch {
            // Scrolling past or opening another page cancels the download; it starts again on return.
            if !Task.isCancelled { fail() }
        }
    }
}

/// A PDF whose links open like those on the page (PDFKit would hand any of them to the system itself).
struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    var followsLinks = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
        context.coordinator.openURL = followsLinks ? context.environment.openURL : nil
    }

    final class Coordinator: NSObject, PDFViewDelegate {
        var openURL: OpenURLAction?

        func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
            openURL?(url)
        }
    }
}

// MARK: - Attachments

struct AttachmentBlockView: View {
    let media: MediaBlock
    @Environment(\.renderContext) private var context
    @State private var localURL: URL?
    @State private var isDownloading = false
    @State private var errorMessage: String?

    var body: some View {
        Button {
            Task { await open() }
        } label: {
            PlaceholderCard(icon: "paperclip", title: media.name ?? String(localized: "Attachment"), detail: detail, titleLineLimit: 2) {
                if isDownloading {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .quickLookPreview($localURL)
    }

    private var detail: String {
        var parts: [String] = []
        if let size = media.size {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if let errorMessage { parts.append(errorMessage) }
        return parts.isEmpty ? String(localized: "Tap to download") : parts.joined(separator: " · ")
    }

    private func open() async {
        guard let client = context.client, let url = context.mediaURL(media.src) else { return }
        isDownloading = true
        errorMessage = nil
        defer { isDownloading = false }
        do {
            let (data, _) = try await client.fetchFile(at: url)
            localURL = try TempFile.write(data, folder: ["attachments", media.attachmentId ?? UUID().uuidString], name: media.name ?? url.lastPathComponent)
        } catch {
            errorMessage = error.userMessage
        }
    }
}

// MARK: - Embeds

struct EmbedBlockView: View {
    let media: MediaBlock
    @Environment(\.openURL) private var openURL

    private var url: URL? { media.src.flatMap(URL.init(string:)) }

    /// `nil` for an iframe without a host: then it is just "Embed".
    private var providerName: String? {
        let provider = media.provider ?? (media.kind == .youtube ? "youtube" : "")
        switch provider {
        case "youtube": return "YouTube"
        case "gdrive": return "Google Drive"
        case "gsheets": return "Google Sheets"
        case "iframe", "": return url?.host()
        default: return provider.capitalized
        }
    }

    var body: some View {
        Button {
            if let url { openURL(url) }
        } label: {
            PlaceholderCard(icon: media.kind == .youtube || media.provider == "youtube" ? "play.rectangle" : "rectangle.on.rectangle",
                            title: providerName ?? String(localized: "Embed"), detail: url?.absoluteString, detailLineLimit: 1) {
                Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .accessibilityLabel(providerName.map { Text("\($0) embed, opens in browser") } ?? Text("Embed, opens in browser"))
    }
}

// MARK: - Subpages, synced blocks

struct SubpagesBlockView: View {
    @Environment(\.renderContext) private var context
    @Environment(ReaderNavigation.self) private var navigation
    @State private var state: LoadState<[SidebarPage]> = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch state {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 40)
            case .failed(let error):
                PlaceholderCard(icon: "doc.on.doc", title: String(localized: "Subpages"), detail: error.userMessage)
            case .loaded(let pages):
                if pages.isEmpty {
                    Text("No subpages.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(pages) { page in
                        Button {
                            navigation.open(PageSelection(page: page))
                        } label: {
                            HStack(spacing: 8) {
                                PageIconView(icon: page.icon, size: 18)
                                Text(page.displayTitle).foregroundStyle(Color.accentColor)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .task(id: context.pageId) { await load() }
    }

    private func load() async {
        guard let client = context.client, let pageId = context.pageId else { return }
        if state.value == nil { state = .loading }
        do {
            let pages = try await Paginated.all { try await client.send(Endpoints.Pages.children(of: pageId, cursor: $0)) }
            state = .loaded(pages)
        } catch is CancellationError {
        } catch {
            if state.value == nil { state = .failed(error) }
        }
    }
}

struct TransclusionReferenceView: View {
    let sourcePageId: String?
    let transclusionId: String?
    /// Incrementing reloads the content ("Refresh").
    var refreshToken = 0
    var showsIcon = true
    @Environment(\.renderContext) private var context
    @State private var state: LoadState<ContentDocument> = .idle

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showsIcon {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .accessibilityLabel("Synced block")
            }
            switch state {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 32)
            case .failed(let error):
                Text(error.userMessage).font(.subheadline).foregroundStyle(.secondary)
            case .loaded(let document):
                if document.isEmpty {
                    Text("Synced block is empty.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    BlockStack(blocks: document.blocks)
                        .environment(\.listDepth, 0)
                }
            }
        }
        .task(id: key) { await load() }
        // Another reference landing here (blocks shifted by an edit) or "Refresh" shows the spinner, not old content.
        // The new load has already begun: a failure it set at once (incomplete reference) stays.
        .onChange(of: key) { if state.value != nil { state = .idle } }
    }

    private var key: String { "\(sourcePageId ?? "")/\(transclusionId ?? "")/\(refreshToken)" }

    private func load() async {
        guard let client = context.client, let sourcePageId, let transclusionId else {
            state = .failed(APIError.notFound(message: String(localized: "Synced block reference is incomplete.")))
            return
        }
        if state.value == nil { state = .loading }
        do {
            let lookup = try await client.send(Endpoints.Transclusions.lookup([.init(sourcePageId: sourcePageId, transclusionId: transclusionId)]))
            guard let item = lookup.items.first else { state = .loaded(.empty); return }
            switch item.status {
            case "not_found": state = .failed(APIError.notFound(message: String(localized: "The synced block source no longer exists.")))
            case "no_access": state = .failed(APIError.forbidden(message: String(localized: "You don't have access to the synced block source.")))
            default: state = .loaded(ContentDocument(json: item.content))
            }
        } catch is CancellationError {
        } catch {
            if state.value == nil { state = .failed(error) }
        }
    }
}

extension MediaBlock.Kind {
    /// Placeholder title of a file without a name.
    var title: String {
        switch self {
        case .drawio: String(localized: "Draw.io diagram")
        case .excalidraw: String(localized: "Excalidraw drawing")
        case .video: String(localized: "Video")
        case .audio: String(localized: "Audio")
        case .pdf: "PDF"
        case .attachment: String(localized: "File attachment")
        case .embed, .youtube: String(localized: "Embed")
        }
    }
}
