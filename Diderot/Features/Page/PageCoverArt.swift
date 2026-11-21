import SwiftUI

/// A preset cover as the app draws it, filling its frame: a color, or the app's own gradient or texture in the colors of
/// the web's preset of that name. The web's are image files of Docmost's (AGPL-3.0), which the app (MIT) doesn't copy,
/// so these look like them, not the same. Gradients and textures are drawn for the 3:1 size of the web's files
/// (`CoverPreset.pictureSize`), which the band crops as it crops those; a seeded generator keeps every scatter the same
/// from one drawing to the next.
struct CoverArt: View {
    let preset: CoverPreset

    var body: some View {
        switch preset.kind {
        case .color:
            Rectangle().fill(preset.color ?? .gray)
        case .gradient:
            gradient
        case .texture:
            Canvas { context, size in
                // Drawn in the files' 2400 × 800, scaled to the frame.
                context.scaleBy(x: size.width / CoverPreset.pictureSize.width, y: size.height / CoverPreset.pictureSize.height)
                Self.drawTexture(preset.id, in: &context)
            }
        }
    }

    // MARK: - Gradients

    /// Soft gradients across two rows of three colors, as the web's blurred ones run.
    private var gradient: some View {
        let colors: [String] = switch preset.id {
        case "gradient-aurora": ["#303c9f", "#5559d6", "#2093ad", "#3c55c4", "#4a72c8", "#1a7a82"]
        case "gradient-sunset": ["#e8704f", "#f09a6c", "#f6c495", "#e6614e", "#ee7583", "#f5bc8a"]
        case "gradient-sky": ["#78a8e7", "#cfe2f8", "#75a7e7", "#6094db", "#7aa8e4", "#94bdec"]
        case "gradient-dune": ["#e4d6c2", "#e2d0b6", "#ece3d1", "#cbb18f", "#c6a882", "#d1b894"]
        case "gradient-forest": ["#275b3a", "#649543", "#4a8448", "#1a442f", "#417c3c", "#7ba84e"]
        case "gradient-dusk": ["#2f3a72", "#735e92", "#e2b5a6", "#3c417a", "#866d9a", "#e8d3c7"]
        case "gradient-berry": ["#4f2b7a", "#a2408a", "#d15e7c", "#5b3181", "#883c89", "#c24a79"]
        default: ["#44546a", "#4c5e71", "#8696a9", "#313d4b", "#6a7d92", "#4f6175"]
        }
        return MeshGradient(width: 3, height: 2, points: [[0, 0], [0.45, 0], [1, 0], [0, 1], [0.6, 1], [1, 1]],
                            colors: colors.map(Self.tint))
    }

    // MARK: - Textures

    private static func drawTexture(_ id: String, in context: inout GraphicsContext) {
        var random = SeededRandom(seed: UInt64(truncatingIfNeeded: id.utf8.reduce(5381) { $0 &* 33 &+ Int($1) }))
        let bounds = CGRect(origin: .zero, size: CoverPreset.pictureSize)
        switch id {
        case "texture-split-slate": splitSlate(&context, bounds, &random)
        case "texture-northern-lights": northernLights(&context, bounds, &random)
        case "texture-linen": linen(&context, bounds)
        case "texture-terrazzo": terrazzo(&context, bounds, &random)
        case "texture-graph": grid(&context, bounds, paper: "#f3f2ea", line: "#a9bccb", minor: 0.35, major: 0.7)
        case "texture-topography": topography(&context, bounds, &random)
        case "texture-blueprint": grid(&context, bounds, paper: "#28568f", line: "#ffffff", minor: 0.1, major: 0.22)
        default: waves(&context, bounds)
        }
    }

    private static func tint(_ hex: String) -> Color {
        Color(hex: hex) ?? .gray
    }

    private static func fill(_ context: inout GraphicsContext, _ bounds: CGRect, _ colors: [String], from start: CGPoint, to end: CGPoint) {
        let gradient = Gradient(colors: colors.map(Self.tint))
        context.fill(Path(bounds), with: .linearGradient(gradient, startPoint: start, endPoint: end))
    }

    /// Dark slate with pale ridges running up to the right.
    private static func splitSlate(_ context: inout GraphicsContext, _ bounds: CGRect, _ random: inout SeededRandom) {
        fill(&context, bounds, ["#323a41", "#262d33", "#1d2326"], from: .zero, to: CGPoint(x: bounds.maxX, y: bounds.maxY))
        for index in 0..<7 {
            let y = CGFloat(index) * 190 + random.next(in: -40...40)
            var ridge = Path()
            ridge.move(to: CGPoint(x: -100, y: y + 420))
            ridge.addCurve(to: CGPoint(x: bounds.maxX + 100, y: y - 300),
                           control1: CGPoint(x: 800, y: y + random.next(in: 150...320)),
                           control2: CGPoint(x: 1600, y: y - random.next(in: 0...160)))
            context.stroke(ridge.offsetBy(dx: 0, dy: 14), with: .color(.black.opacity(0.35)), lineWidth: 18)
            context.stroke(ridge, with: .color(tint("#a9b4bd").opacity(random.next(in: 0.45...0.75))), lineWidth: 6)
        }
    }

    /// A green curtain of light with a bright lower edge over a night sky.
    private static func northernLights(_ context: inout GraphicsContext, _ bounds: CGRect, _ random: inout SeededRandom) {
        fill(&context, bounds, ["#221a46", "#0b1426", "#081521", "#0a1f31"], from: .zero, to: CGPoint(x: 0, y: bounds.maxY))
        func edge(_ x: CGFloat) -> CGFloat { 560 + 70 * sin(x / 380) + 40 * sin(x / 150 + 1.3) }
        for x in stride(from: CGFloat(0), through: bounds.maxX, by: 9) {
            let bottom = edge(x), top = bottom - random.next(in: 200...460)
            var streak = Path()
            streak.move(to: CGPoint(x: x, y: top))
            streak.addLine(to: CGPoint(x: x, y: bottom))
            let shade = Gradient(colors: [tint("#7d5bd0").opacity(0), tint("#2fbf8a").opacity(random.next(in: 0.35...0.8)),
                                          tint("#64fdc4")])
            context.stroke(streak, with: .linearGradient(shade, startPoint: CGPoint(x: x, y: top), endPoint: CGPoint(x: x, y: bottom)),
                           lineWidth: random.next(in: 4...9))
        }
        for _ in 0..<70 {
            let star = CGRect(x: random.next(in: 0...bounds.maxX), y: random.next(in: 0...bounds.maxY), width: 4, height: 4)
            context.fill(Path(ellipseIn: star), with: .color(.white.opacity(random.next(in: 0.2...0.6))))
        }
    }

    /// Green cloth woven of fine light and dark threads.
    private static func linen(_ context: inout GraphicsContext, _ bounds: CGRect) {
        context.fill(Path(bounds), with: .color(tint("#4a6653")))
        for (index, x) in stride(from: CGFloat(0), through: bounds.maxX, by: 7).enumerated() {
            context.fill(Path(CGRect(x: x, y: 0, width: 3, height: bounds.maxY)),
                         with: .color(index.isMultiple(of: 2) ? .white.opacity(0.05) : .black.opacity(0.07)))
        }
        for (index, y) in stride(from: CGFloat(0), through: bounds.maxY, by: 7).enumerated() {
            context.fill(Path(CGRect(x: 0, y: y, width: bounds.maxX, height: 3)),
                         with: .color(index.isMultiple(of: 3) ? .black.opacity(0.08) : .white.opacity(0.04)))
        }
    }

    /// Pale stone with chips of terracotta, slate, sage and ochre.
    private static func terrazzo(_ context: inout GraphicsContext, _ bounds: CGRect, _ random: inout SeededRandom) {
        context.fill(Path(bounds), with: .color(tint("#ede7df")))
        let chips = ["#c87b61", "#b6a8a1", "#2f3a4a", "#8d9e8a", "#d9a441", "#9aa6b2", "#a65d48"].map(tint)
        for _ in 0..<900 {
            let center = CGPoint(x: random.next(in: 0...bounds.maxX), y: random.next(in: 0...bounds.maxY))
            let radius = random.next(in: 0...1) < 0.85 ? random.next(in: 4...11) : random.next(in: 14...26)
            let corners = Int(random.next(in: 3...5.99)), turn = random.next(in: 0...(2 * .pi))
            var chip = Path()
            for corner in 0..<corners {
                let angle = turn + CGFloat(corner) / CGFloat(corners) * 2 * .pi
                let reach = radius * random.next(in: 0.6...1.2)
                let point = CGPoint(x: center.x + cos(angle) * reach, y: center.y + sin(angle) * reach)
                if corner == 0 { chip.move(to: point) } else { chip.addLine(to: point) }
            }
            chip.closeSubpath()
            context.fill(chip, with: .color(chips[Int(random.next(in: 0...CGFloat(chips.count) - 0.01))]))
        }
    }

    /// Squared paper: fine lines, and a stronger one every fifth (graph paper, blueprint).
    private static func grid(_ context: inout GraphicsContext, _ bounds: CGRect, paper: String, line: String, minor: Double, major: Double) {
        context.fill(Path(bounds), with: .color(tint(paper)))
        let ink = tint(line)
        for (index, x) in stride(from: CGFloat(0), through: bounds.maxX, by: 40).enumerated() {
            let strong = index.isMultiple(of: 5)
            context.fill(Path(CGRect(x: x, y: 0, width: strong ? 4 : 2, height: bounds.maxY)), with: .color(ink.opacity(strong ? major : minor)))
        }
        for (index, y) in stride(from: CGFloat(0), through: bounds.maxY, by: 40).enumerated() {
            let strong = index.isMultiple(of: 5)
            context.fill(Path(CGRect(x: 0, y: y, width: bounds.maxX, height: strong ? 4 : 2)), with: .color(ink.opacity(strong ? major : minor)))
        }
    }

    /// Contour lines around a few hills on pale paper: each level runs around every hill that reaches above it, so
    /// where hills meet one line goes around both, as on a map.
    private static func topography(_ context: inout GraphicsContext, _ bounds: CGRect, _ random: inout SeededRandom) {
        context.fill(Path(bounds), with: .color(tint("#e8ebe6")))
        let ink = tint("#9ea59c")
        let hills = [(CGPoint(x: 420, y: 300), 30.0), (CGPoint(x: 1250, y: 560), 36.0), (CGPoint(x: 2050, y: 220), 32.0)].map { hill in
            (center: hill.0, height: hill.1, phase: random.next(in: 0...(2 * .pi)), lobes: random.next(in: 0.1...0.2))
        }
        for level in 1..<36 {
            var outline: Path?
            for hill in hills where hill.height > Double(level) {
                let radius = CGFloat(hill.height - Double(level)) * 26
                var ring = Path()
                for step in 0...72 {
                    let angle = CGFloat(step) / 72 * 2 * .pi
                    let reach = radius * (1 + hill.lobes * sin(3 * angle + hill.phase) + 0.07 * sin(5 * angle + hill.phase * 2 + CGFloat(level) / 6))
                    let point = CGPoint(x: hill.center.x + cos(angle) * reach * 1.25, y: hill.center.y + sin(angle) * reach)
                    if step == 0 { ring.move(to: point) } else { ring.addLine(to: point) }
                }
                ring.closeSubpath()
                outline = outline.map { $0.union(ring) } ?? ring
            }
            guard let outline else { continue }
            context.stroke(outline, with: .color(ink.opacity(level.isMultiple(of: 5) ? 0.75 : 0.4)), lineWidth: level.isMultiple(of: 5) ? 4 : 2.5)
        }
    }

    /// Fine pale lines rippling across deep blue.
    private static func waves(_ context: inout GraphicsContext, _ bounds: CGRect) {
        fill(&context, bounds, ["#1b2c4a", "#21395a", "#1c3150"], from: .zero, to: CGPoint(x: bounds.maxX, y: bounds.maxY))
        let ink = tint("#8fb0db")
        for (index, base) in stride(from: CGFloat(-60), through: bounds.maxY + 60, by: 22).enumerated() {
            var line = Path()
            for x in stride(from: CGFloat(0), through: bounds.maxX, by: 24) {
                let y = base + 38 * sin(x / 260 + CGFloat(index) * 0.11) + 18 * sin(x / 95 - CGFloat(index) * 0.07)
                if x == 0 { line.move(to: CGPoint(x: x, y: y)) } else { line.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(line, with: .color(ink.opacity(0.28)), lineWidth: 3)
        }
    }
}

/// A small generator with a fixed start (xorshift), so a texture scatters the same every time it is drawn; the system's
/// generator would draw it anew on every layout.
nonisolated struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    /// A value in `range`.
    mutating func next(in range: ClosedRange<CGFloat>) -> CGFloat {
        range.lowerBound + CGFloat(Double(next() >> 11) / Double(1 << 53)) * (range.upperBound - range.lowerBound)
    }
}
