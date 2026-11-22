import SwiftUI
import DocmostKit

/// The page's cover as a band above its title, as the web shows it (`PageCover`): edge to edge and as high as there, a
/// color, a drawn preset (`CoverArt`) or an image cropped to it at its position, gray until the image is there. People
/// who may edit the page change it on the band: "Change Cover" opens the gallery (`CoverPickerSheet`), "Reposition"
/// moves the image up and down, the bin removes the cover. Readers see no band where the image doesn't load, editors
/// "Cover image not found". An image from another server (an Unsplash photo set on the web) loads as other servers'
/// images in pages do (`RenderContext.loadsByItself`).
struct PageCoverBand: View {
    let page: Page
    let edit: PageCoverEdit
    /// Nil for readers.
    let actions: PageCoverActions?

    @Environment(\.renderContext) private var context
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var size = CGSize.zero
    @State private var image: UIImage?
    @State private var standIn = MediaStandIn.loading
    @State private var gate = MediaGate()
    /// The cover when "Change Cover" opened the picker.
    @State private var picking: PageCoverEdit.Fields?
    /// The position being tried while repositioning.
    @State private var draft: Double?
    /// Where the drag started, and how far the image reaches past the band then.
    @State private var dragStart: (position: Double, overflow: CGFloat)?

    private var fields: PageCoverEdit.Fields { edit.fields(of: page) }
    private var position: Double { PageCover.position(draft ?? fields.position) }

    private var imageURL: URL? {
        switch PageCover(fields.photo) {
        case .file(let path): context.baseURL.flatMap { ImageURL.resolveContentMedia(path, baseURL: $0) }
        case .unsplash(let url): url
        default: nil
        }
    }

    /// The picture's own size, which the band crops: an image's once it is there.
    private var natural: CGSize? {
        switch PageCover(fields.photo) {
        case .preset(let preset) where preset.kind != .color: CoverPreset.pictureSize
        case .file, .unsplash: image?.size
        default: nil
        }
    }

    /// An image that didn't load.
    private var failed: Bool {
        if case .failed = standIn { imageURL != nil && image == nil } else { false }
    }

    var body: some View {
        // Always there, also without a band, so that a change of cover always clears what the last one left.
        ZStack {
            if let cover = PageCover(fields.photo), !(failed && actions == nil) {
                band(cover)
            }
        }
        .onChange(of: fields.photo) { _, _ in
            image = nil
            standIn = .loading
            gate = MediaGate()
            stopRepositioning()
        }
        .onChange(of: actions == nil) { _, readOnly in
            // Edit rights gone (offline, trashed): repositioning and the picker end, as on the web.
            if readOnly {
                stopRepositioning()
                picking = nil
            }
        }
    }

    private func band(_ cover: PageCover) -> some View {
        ZStack {
            artwork(cover)
            if edit.isRepositioning, actions != nil { repositionSurface }
        }
        .frame(maxWidth: .infinity)
        .containerRelativeFrame(.vertical) { length, _ in
            // Before the band's width is known, the size class's guess, so an iPad's band doesn't start too low.
            PageCover.bandHeight(width: size.width > 0 ? size.width : horizontalSizeClass == .regular ? 1024 : 390, viewportHeight: length)
        }
        .background(Color(.secondarySystemFill))
        .clipped()
        .overlay(alignment: .bottomTrailing) {
            if let actions { controls(cover, actions) }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .task(id: LoadKey(url: imageURL, width: size.width, gate: gate)) { await load() }
        .onDisappear { stopRepositioning() }
        .linkSheet(isPresented: Binding { picking != nil } set: { if !$0 { picking = nil } }) {
            if let actions, let picking {
                CoverPickerSheet(page: page, edit: edit, actions: actions, opened: picking)
                    .environment(\.renderContext, context)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page-cover")
        // With the 760-point column's own padding, the web's 28 points to the title.
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func artwork(_ cover: PageCover) -> some View {
        switch cover {
        case .preset(let preset) where preset.kind == .color:
            CoverArt(preset: preset)
        case .preset(let preset):
            CoverFit(natural: CoverPreset.pictureSize, position: position) { CoverArt(preset: preset) }
        case .file, .unsplash:
            if let image {
                CoverFit(natural: image.size, position: position) { ResizableImage(image: image) }
                    .transition(.opacity)
                    .accessibilityHidden(true)
            } else {
                standInView
            }
        }
    }

    @ViewBuilder
    private var standInView: some View {
        switch standIn {
        case .loading:
            Color.clear
        case .otherServer(let url):
            Button { gate.loadsFromOtherServer = true } label: {
                note(String(localized: "From \(url.host() ?? url.absoluteString). Tap to load."))
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Loads it from that server"))
        case .large:
            Button { gate.loadsLargeFile = true } label: { note(MediaStandIn.largeDetail(size: nil)) }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Loads it"))
        case .failed:
            // Only editors see it: for readers the band goes.
            Button { gate.attempt += 1 } label: { note(String(localized: "Cover image not found")) }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Loads it again"))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
    }

    // MARK: - Editing

    private func controls(_ cover: PageCover, _ actions: PageCoverActions) -> some View {
        HStack(spacing: 6) {
            if edit.isRepositioning {
                Button { nudge(10) } label: { Image(systemName: "arrow.up") }
                    .accessibilityLabel("Move Image Up")
                    .accessibilityIdentifier("cover-move-up")
                Button { nudge(-10) } label: { Image(systemName: "arrow.down") }
                    .accessibilityLabel("Move Image Down")
                    .accessibilityIdentifier("cover-move-down")
                Button("Save Position") { savePosition(actions) }
                    .accessibilityIdentifier("cover-save-position")
                Button("Cancel") { stopRepositioning() }
                    .accessibilityIdentifier("cover-cancel-position")
            } else {
                Button("Change Cover") { picking = fields }
                    .accessibilityIdentifier("page-change-cover")
                if canReposition(cover) {
                    Button("Reposition") { startRepositioning() }
                        .accessibilityIdentifier("page-reposition-cover")
                }
                Button { edit.send(.photo(nil), shown: fields, with: actions) } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Remove Cover")
                    .accessibilityIdentifier("page-remove-cover")
            }
        }
        .font(.footnote.weight(.medium))
        .buttonStyle(.glass)
        .controlSize(.small)
        .padding(12)
    }

    /// Only a picture that reaches well past the band moves: a wide one on a narrow screen (a gradient on an iPhone) has
    /// next to nothing to show above or below, so it offers no "Reposition", where the web's would do next to nothing.
    private func canReposition(_ cover: PageCover) -> Bool {
        guard cover.isImage, let natural else { return false }
        return PageCover.overflow(natural: natural, box: size) >= 10
    }

    /// Drags move the image with the finger; VoiceOver moves it in the web's steps of 10.
    private var repositionSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let start = dragStart ?? (position, PageCover.overflow(natural: natural ?? .zero, box: size))
                    dragStart = start
                    draft = PageCover.position(afterDragging: value.translation.height, from: start.position, overflow: start.overflow)
                }
                .onEnded { _ in dragStart = nil })
            .overlay {
                Text("Drag the image up or down")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    .allowsHitTesting(false)
            }
            .accessibilityElement()
            .accessibilityLabel(Text("Cover position"))
            .accessibilityValue(Text("\(position / 100, format: .percent.precision(.fractionLength(0))) from the top"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: nudge(10)
                case .decrement: nudge(-10)
                @unknown default: break
                }
            }
    }

    private func startRepositioning() {
        picking = nil
        draft = PageCover.position(fields.position)
        edit.isRepositioning = true
    }

    private func stopRepositioning() {
        draft = nil
        dragStart = nil
        edit.isRepositioning = false
    }

    private func nudge(_ delta: Double) {
        draft = PageCover.position(position + delta)
    }

    /// Rounded to hundredths, as the web saves it; the same position sends nothing.
    private func savePosition(_ actions: PageCoverActions) {
        let rounded = (position * 100).rounded() / 100
        if rounded != PageCover.position(fields.position) {
            edit.send(.position(rounded), shown: fields, with: actions)
        }
        stopRepositioning()
    }

    // MARK: - Loading

    private struct LoadKey: Equatable {
        let url: URL?
        let width: CGFloat
        let gate: MediaGate
    }

    /// As a page's image loads (`ContentImageView`): for the band's width, keeping the last one until another width's
    /// is there.
    private func load() async {
        guard let url = imageURL, let loader = context.mediaLoader, size.width > 0 else { return }
        if let waits = gate.standIn(before: url, in: context) { return standIn = waits }
        if gate.stillWaits(standIn) { return }
        if image == nil { standIn = .loading }
        do {
            let loaded = try await loader.image(for: url, targetWidth: size.width, scale: displayScale, maxBytes: gate.maxBytes)
            // As for a page's image: a load cancelled meanwhile (a rotation) leaves the newer one's picture.
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { image = loaded }
        } catch {
            guard let failed = MediaGate.standIn(after: error) else { return }
            standIn = failed
            AppLog.ui.debug("Cover failed: \(url.deletingLastPathComponent().path, privacy: .public) – \(error.userMessage, privacy: .public)")
        }
    }
}

/// A picture of `natural` size laid out as CSS's `object-fit: cover` with `object-position: 50% <position>%`.
struct CoverFit<Content: View>: View {
    let natural: CGSize
    let position: Double
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            let frame = PageCover.imageFrame(natural: natural, in: proxy.size, position: position)
            content
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
        }
        .clipped()
    }
}

/// "Add Cover" above the title, for people who may edit a page without a cover, as on the web: a quiet gradient picked
/// at random, which the band's "Change Cover" then replaces.
struct AddCoverButton: View {
    let page: Page
    let edit: PageCoverEdit
    /// Nil for readers.
    let actions: PageCoverActions?

    var body: some View {
        let fields = edit.fields(of: page)
        if let actions, page.isBase != true, PageCover(fields.photo) == nil {
            Button {
                edit.send(.photo(CoverPreset.randomGradient(replacing: fields.photo).value), shown: fields, with: actions)
            } label: {
                Label("Add Cover", systemImage: "photo")
            }
            .buttonStyle(.borderless)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("page-add-cover")
        }
    }
}
