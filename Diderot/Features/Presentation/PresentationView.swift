import SwiftUI
import UIKit
import DocmostKit

/// A page as slides, as Docmost's web client presents it (0.97; here on every server): first its title, then its blocks
/// as `SlideLayout` splits them, in larger type. Swiping, the bar below or an iPad keyboard (the web's keys) move between
/// slides; on an iPad a laser pointer can follow the pointer. The screen stays on meanwhile.
struct PresentationView: View {
    let pageId: String
    let title: String
    /// Takes page, database entry and comment links, after the presentation closed for them.
    let openLink: (URL) -> Void

    @Environment(AppSession.self) private var session
    @Environment(ReaderNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    private let document: ContentDocument
    /// The page's blocks and footnotes, and what each does to the slides.
    private let items: [SlideItem]
    private let roles: [SlideLayout.Role]
    private let anchors: [String: String]
    @State private var heights: [CGFloat]
    /// The slides' size, the bar below excluded.
    @State private var stage: CGSize = .zero
    @State private var slides: [SlideLayout.Slide] = []
    /// 0 is the title slide.
    @State private var index = 0
    @State private var scrollRequest: SlideScrollRequest?
    @State private var showsLaserPointer = false
    @State private var pointer: CGPoint?
    @FocusState private var focused: Bool
    /// Subpages and databases on a slide open on the page's stack, once the presentation has closed.
    @State private var slideNavigation = ReaderNavigation()

    private static let spacing: CGFloat = 16

    init(pageId: String, title: String, document: ContentDocument, openLink: @escaping (URL) -> Void) {
        self.pageId = pageId
        self.title = title
        self.openLink = openLink
        self.document = document
        var items = document.blocks.map(SlideItem.block)
        if !document.footnotes.isEmpty { items.append(.footnotes(document.footnotes)) }
        self.items = items
        roles = items.map(\.role)
        anchors = document.anchors
        _heights = State(initialValue: Array(repeating: 0, count: items.count))
    }

    private var slideCount: Int { slides.count + 1 }

    /// The web's margins: a twentieth of the width at the sides, more space above than below.
    private var padding: EdgeInsets {
        let side = max(16, (stage.width * 0.05).rounded())
        return EdgeInsets(top: max(16, (stage.height * 0.06).rounded()), leading: side,
                          bottom: max(16, (stage.height * 0.04).rounded()), trailing: side)
    }

    /// Headings 1 to 3 as much larger than the text as on the web's slides (3, 2.25 and 1.75 times its 1.3 rem).
    private var headingFont: (Int) -> Font {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(slideTypeSize))
        let text = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).pointSize
        return { level in
            switch level {
            case 1: .system(size: (text * 2.3).rounded(), weight: .bold)
            case 2: .system(size: (text * 1.73).rounded(), weight: .bold)
            case 3: .system(size: (text * 1.35).rounded(), weight: .bold)
            default: HeadingView.font(level: level)
            }
        }
    }

    /// Larger type, as the web's: three steps up from the reader's.
    private var slideTypeSize: DynamicTypeSize {
        let sizes = DynamicTypeSize.allCases
        let current = sizes.firstIndex(of: typeSize) ?? 0
        return sizes[min(current + 3, sizes.count - 1)]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Above the slides, not over them: on an iPad the slides' paging view takes the taps over it.
            Button("Exit Presentation Mode", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .font(.title3)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .keyboardShortcut(.cancelAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal)
                .padding(.top, 8)
                .accessibilityIdentifier("presentation-close")
            TabView(selection: $index) {
                TitleSlide(title: title)
                    .padding(padding)
                    .tag(0)
                ForEach(Array(slides.enumerated()), id: \.offset) { offset, slide in
                    SlidePage(items: slide.blocks.map { items[$0] }, number: offset + 1, viewport: stage.height, padding: padding,
                              spacing: Self.spacing, request: scrollRequest) { forward in
                        forward ? showNext() : showPrevious()
                    }
                    .tag(offset + 1)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .dynamicTypeSize(slideTypeSize)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { stage = $0 }
            .background(alignment: .topLeading) {
                if stage.width > 0 { measurement }
            }
            controls
        }
        .background(Color(.systemBackground))
        .overlay { laserPointer }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): pointer = location
            case .ended: pointer = nil
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.rightArrow, .return, .leftArrow, .home, .end, .downArrow, .upArrow, .pageDown, .space, .pageUp, .escape]) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            switch press.key {
            // The close button's Escape doesn't reach it while the slides have the keyboard's focus.
            case .escape: dismiss()
            case .rightArrow, .return: showNext()
            case .leftArrow: showPrevious()
            case .home: index = 0
            case .end: index = slideCount - 1
            case .downArrow: scrollOrMove(by: 0.15)
            case .upArrow: scrollOrMove(by: -0.15)
            case .pageDown, .space: scrollOrMove(by: 0.9)
            default: scrollOrMove(by: -0.9)
            }
            return .handled
        }
        .handlesLinks { url, outside in
            switch ContentLinkRouter.destination(for: url, serverURL: session.server?.url) {
            case .anchor(let anchor): show(anchor: anchor)
            case .external(let external): outside(external)
            case .user: break
            case .page, .databaseEntry, .comment:
                dismiss()
                openLink(url)
            }
        }
        .opensExternalLinks()
        .mediaViewer { document }
        .environment(\.renderContext, RenderContext(session: session, pageId: pageId))
        .environment(\.linkPreviews, session.linkPreviews)
        .environment(slideNavigation)
        // Comment marks neither show nor open their comment, as on the web.
        .environment(\.showsCommentMarks, false)
        .environment(\.headingFont, headingFont)
        .onChange(of: heights) { paginate() }
        .onChange(of: stage) { paginate() }
        .onChange(of: index) { _, index in
            AccessibilityNotification.Announcement(String(localized: "Slide \(index + 1) of \(slideCount)")).post()
        }
        .onAppear {
            focused = true
            UIApplication.shared.isIdleTimerDisabled = true
            let pageNavigation = navigation
            slideNavigation.redirect = { [dismiss] selection in
                dismiss()
                pageNavigation.open(selection)
            }
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: - Slides

    /// Every block that can be on a slide, at the slides' width and type size, invisible: their heights split the slides.
    private var measurement: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                if roles[index] != .hidden && roles[index] != .divider {
                    items[index].view
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            if abs(heights[index] - height) >= 0.5 { heights[index] = height }
                        }
                }
            }
        }
        .frame(width: stage.width - padding.leading - padding.trailing)
        .fixedSize(horizontal: false, vertical: true)
        .dynamicTypeSize(slideTypeSize)
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Splits again after a size or height changed, staying at the block the current slide begins with.
    private func paginate() {
        guard stage.height > 0 else { return }
        let height = stage.height - padding.top - padding.bottom
        let updated = SlideLayout.slides(roles: roles, heights: heights, height: height, spacing: Self.spacing)
        guard updated != slides else { return }
        let anchor = index > 0 && index <= slides.count ? slides[index - 1].blocks.first : nil
        slides = updated
        if let anchor {
            index = SlideLayout.slide(showing: anchor, in: updated) + 1
        }
        index = min(index, updated.count)
    }

    private func showNext() {
        if index < slideCount - 1 { index += 1 }
    }

    private func showPrevious() {
        if index > 0 { index -= 1 }
    }

    /// Down and up keys scroll a slide that scrolls, by `fraction` of its height, and move on at its end, as on the web.
    private func scrollOrMove(by fraction: CGFloat) {
        if index > 0, index <= slides.count, slides[index - 1].scrolls {
            scrollRequest = SlideScrollRequest(slide: index, fraction: fraction)
        } else if fraction > 0 {
            showNext()
        } else {
            showPrevious()
        }
    }

    /// A link to a heading or synced block of this page: its slide.
    private func show(anchor: String) {
        guard let id = anchors[anchor], let block = items.firstIndex(where: { $0.contains(id) }) else { return }
        index = SlideLayout.slide(showing: block, in: slides) + 1
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 4) {
            // As shortcuts too: on an iPad the slides' scroll view takes the arrow keys before `onKeyPress` gets them.
            Button("Previous Slide", systemImage: "chevron.left", action: showPrevious)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(index == 0)
                .accessibilityIdentifier("presentation-previous")
            Text(verbatim: "\(index + 1) / \(slideCount)")
                .font(.body.monospacedDigit())
                .frame(minWidth: 72)
                .accessibilityLabel("Slide \(index + 1) of \(slideCount)")
                .accessibilityIdentifier("presentation-counter")
            Button("Next Slide", systemImage: "chevron.right", action: showNext)
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(index == slideCount - 1)
                .accessibilityIdentifier("presentation-next")
            // On the web the dot follows the mouse and hides for touch: here on an iPad, for a trackpad or mouse.
            if UIDevice.current.userInterfaceIdiom == .pad {
                Divider().frame(height: 24).padding(.horizontal, 4)
                Toggle("Laser Pointer", systemImage: "cursorarrow.rays", isOn: $showsLaserPointer)
                    .toggleStyle(.button)
                    .accessibilityIdentifier("presentation-laser-pointer")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.title3)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var laserPointer: some View {
        if showsLaserPointer, let pointer {
            Circle()
                .fill(Color.blue.opacity(0.65))
                .frame(width: 14, height: 14)
                .shadow(color: .blue.opacity(0.5), radius: 8)
                .position(pointer)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// What the presentation mode shows: the page as it was when it opened.
struct Presentation: Identifiable {
    let id = UUID()
    let pageId: String
    let title: String
    let document: ContentDocument
}

/// A block of the page, or its footnotes after the last one.
private enum SlideItem: Identifiable {
    case block(Block)
    case footnotes([Footnote])

    var id: String {
        switch self {
        case .block(let block): block.id
        case .footnotes: "footnotes"
        }
    }

    var role: SlideLayout.Role {
        switch self {
        case .block(let block): SlideLayout.Role(block.kind)
        case .footnotes: .content
        }
    }

    @ViewBuilder
    var view: some View {
        switch self {
        case .block(let block): BlockView(block: block)
        case .footnotes(let footnotes): FootnotesView(footnotes: footnotes)
        }
    }

    /// Whether this is the block with `id` or holds it (a footnote).
    func contains(_ id: String) -> Bool {
        switch self {
        case .block(let block): block.id == id
        case .footnotes(let footnotes): footnotes.contains { $0.id == id }
        }
    }
}

/// The down and up keys' scroll of slide `slide` (its number, 1 for the first after the title).
private struct SlideScrollRequest: Equatable {
    let slide: Int
    /// Of the slide's height; negative scrolls up.
    let fraction: CGFloat
    private let id = UUID()

    init(slide: Int, fraction: CGFloat) {
        self.slide = slide
        self.fraction = fraction
    }
}

private struct TitleSlide: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 52, weight: .bold))
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("presentation-title")
    }
}

/// One slide: its blocks in the middle, or from the top when they are taller and scroll.
private struct SlidePage: View {
    let items: [SlideItem]
    let number: Int
    let viewport: CGFloat
    let padding: EdgeInsets
    let spacing: CGFloat
    let request: SlideScrollRequest?
    /// The keys went past the slide's end (`true`) or start.
    let onEdge: (Bool) -> Void

    @State private var position = ScrollPosition(edge: .top)
    @State private var geometry = ScrollGeometryBox()

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(items) { item in
                    item.view
                }
            }
            .padding(padding)
            .frame(maxWidth: .infinity, minHeight: viewport, alignment: .center)
        }
        .scrollPosition($position)
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, value in geometry.value = value }
        .onChange(of: request) { _, request in
            guard let request, request.slide == number, let value = geometry.value else { return }
            let end = max(value.contentSize.height - value.containerSize.height, 0)
            let target = min(max(value.contentOffset.y + request.fraction * value.containerSize.height, 0), end)
            if abs(target - value.contentOffset.y) < 1 {
                onEdge(request.fraction > 0)
            } else {
                withAnimation { position.scrollTo(y: target) }
            }
        }
    }
}

/// The scroll geometry without updating the view at every scrolled point.
private final class ScrollGeometryBox {
    var value: ScrollGeometry?
}
