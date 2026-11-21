import SwiftUI
import DocmostKit

/// A page's cover (`coverPhoto`, Docmost 0.98) as the web's `resolveCover` reads it: one of its presets, an image
/// uploaded to the page, or an Unsplash photo set on the web. Anything else (an unknown preset, another address) is no
/// cover: a value from a newer server shows nothing rather than something wrong.
nonisolated enum PageCover: Hashable, Sendable {
    case preset(CoverPreset)
    /// `/api/files/<id>/<name>` on the page's server.
    case file(path: String)
    /// An `https://images.unsplash.com/…` address.
    case unsplash(URL)

    init?(_ value: String?) {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix(CoverPreset.prefix) {
            guard let preset = CoverPreset.all.first(where: { $0.value == value }) else { return nil }
            self = .preset(preset)
        } else if value.wholeMatch(of: Self.filePattern) != nil {
            self = .file(path: value)
        } else if let url = URL(string: value), Self.isUnsplashPhoto(url) {
            self = .unsplash(url)
        } else {
            return nil
        }
    }

    /// The web's `COVER_FILE_PATTERN`: a file's id and a name that is neither a folder nor `.` or `..` (a shared page's
    /// cover may be public and carry a token).
    private static var filePattern: Regex<Substring> {
        #/\/api\/files\/(?:public\/)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/(?!\.\.?(?:\?|$))[^\/?#\\]+(?:\?jwt=[\w.-]+)?/#
            .ignoresCase()
    }

    /// As the web's `isUnsplashImageUrl`: HTTPS to Unsplash's image host itself, without a user or another port.
    private static func isUnsplashPhoto(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host()?.lowercased() == "images.unsplash.com" && url.user() == nil
            && url.password() == nil && (url.port == nil || url.port == 443)
    }

    /// Whether it is a picture (an image the band crops), which moves up and down; a color fills the band whatever its
    /// size.
    var isImage: Bool {
        if case .preset(let preset) = self { return preset.kind != .color }
        return true
    }

    // MARK: - Layout

    /// The position as the band shows it (`getCoverPosition`): 0–100, the middle without one.
    static func position(_ stored: Double?) -> Double {
        guard let stored, stored.isFinite else { return 50 }
        return min(100, max(0, stored))
    }

    /// The band's height, as the web's `.cover` sizes it: `clamp(120px, 18vh, 150px)` up to 768 points wide,
    /// `clamp(160px, 26vh, 240px)` above.
    static func bandHeight(width: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        width <= 768 ? min(max(viewportHeight * 0.18, 120), 150) : min(max(viewportHeight * 0.26, 160), 240)
    }

    /// The frame of a picture of `natural` size in the band, as CSS's `object-fit: cover` with `object-position: 50%
    /// <position>%` lays it out: as small as covers the band, centered across, `position` percent of what reaches past
    /// it above.
    static func imageFrame(natural: CGSize, in box: CGSize, position: Double) -> CGRect {
        guard natural.width > 0, natural.height > 0 else { return CGRect(origin: .zero, size: box) }
        let scale = max(box.width / natural.width, box.height / natural.height)
        let size = CGSize(width: natural.width * scale, height: natural.height * scale)
        return CGRect(x: (box.width - size.width) / 2, y: (box.height - size.height) * self.position(position) / 100,
                      width: size.width, height: size.height)
    }

    /// How far a picture reaches past the band in height once it covers it (`getCoverOverflow`): what repositioning moves.
    static func overflow(natural: CGSize, box: CGSize) -> CGFloat {
        guard natural.width > 0, natural.height > 0 else { return 0 }
        let scale = max(box.width / natural.width, box.height / natural.height)
        return max(0, natural.height * scale - box.height)
    }

    /// The position after a drag by `deltaY` points from `start` (`getCoverPositionAfterDrag`): the picture follows
    /// the finger, so dragging down shows more of its top.
    static func position(afterDragging deltaY: CGFloat, from start: Double, overflow: CGFloat) -> Double {
        guard overflow > 0 else { return start }
        return position(start - Double(deltaY / overflow) * 100)
    }
}

/// One of the web's preset covers (`page-cover.constants.ts`), stored as `preset:<id>`. The colors are the web's. The
/// gradients and textures are image files of Docmost's (AGPL-3.0), which the app (MIT) doesn't copy: it draws its own
/// in each preset's colors (`CoverArt`), so they look like the web's, not the same.
nonisolated struct CoverPreset: Hashable, Sendable, Identifiable {
    enum Kind: Sendable {
        case color, gradient, texture
    }

    static let prefix = "preset:"

    let id: String
    let kind: Kind
    /// The web's name, which only VoiceOver says: a tile shows the cover.
    let label: LocalizedStringResource
    /// A color preset's color.
    let hex: String?

    /// The value `coverPhoto` stores.
    var value: String { Self.prefix + id }

    var color: Color? { hex.flatMap(Color.init(hex:)) }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    private init(_ kind: Kind, _ name: String, _ label: LocalizedStringResource, hex: String? = nil) {
        id = "\(kind)-\(name)"
        self.kind = kind
        self.label = label
        self.hex = hex
    }

    static let colors = [
        CoverPreset(.color, "red", "Red", hex: "#d6645a"),
        CoverPreset(.color, "orange", "Orange", hex: "#e08a4f"),
        CoverPreset(.color, "yellow", "Yellow", hex: "#ebbd59"),
        CoverPreset(.color, "green", "Green", hex: "#5e9a6d"),
        CoverPreset(.color, "teal", "Teal", hex: "#3d8f96"),
        CoverPreset(.color, "blue", "Blue", hex: "#4a7bc4"),
        CoverPreset(.color, "purple", "Purple", hex: "#7d66b5"),
        CoverPreset(.color, "graphite", "Graphite", hex: "#4b5563"),
    ]

    static let gradients = [
        CoverPreset(.gradient, "aurora", "Aurora"),
        CoverPreset(.gradient, "sunset", "Sunset"),
        CoverPreset(.gradient, "sky", "Sky"),
        CoverPreset(.gradient, "dune", "Dune"),
        CoverPreset(.gradient, "forest", "Forest"),
        CoverPreset(.gradient, "dusk", "Dusk"),
        CoverPreset(.gradient, "berry", "Berry"),
        CoverPreset(.gradient, "slate", "Slate"),
    ]

    static let textures = [
        CoverPreset(.texture, "split-slate", "Split slate"),
        CoverPreset(.texture, "northern-lights", "Northern lights"),
        CoverPreset(.texture, "linen", "Linen"),
        CoverPreset(.texture, "terrazzo", "Terrazzo"),
        CoverPreset(.texture, "graph", "Graph paper"),
        CoverPreset(.texture, "topography", "Topography"),
        CoverPreset(.texture, "blueprint", "Blueprint"),
        CoverPreset(.texture, "waves", "Waves"),
    ]

    static let all = colors + gradients + textures

    /// The size the web's gradient and texture files have: the drawn ones are laid out in the band as those are.
    static let pictureSize = CGSize(width: 2400, height: 800)

    /// What "Add Cover" picks, as the web's `pickRandomGradient` does: one of the quieter gradients, not the cover the
    /// page has.
    static func randomGradient(replacing current: String?) -> CoverPreset {
        let quiet = ["gradient-sky", "gradient-slate", "gradient-dusk", "gradient-aurora", "gradient-dune"]
        let options = gradients.filter { quiet.contains($0.id) && $0.value != current }
        return options.randomElement() ?? gradients[2]
    }
}
