import CoreGraphics
import DocmostKit

/// How the presentation mode splits a page into slides, as Docmost's web client does (0.97): blocks follow each other on
/// a slide while they fit its height. A heading 1 begins a new slide, a divider ends one without showing, and a table
/// or database is the last block of its slide; empty text blocks and page breaks are left out. A block taller than the
/// slide gets one of its own, which scrolls.
nonisolated enum SlideLayout {
    struct Slide: Equatable {
        /// Indexes into the blocks given to `slides`.
        var blocks: [Int]
        /// Taller than the slide: it scrolls.
        var scrolls: Bool
    }

    /// What a block does to the slides.
    enum Role: Equatable {
        case content
        /// A heading 1: begins a slide.
        case section
        /// A table or database: the last block of its slide.
        case closing
        /// A divider: ends the slide and isn't shown.
        case divider
        /// Empty text, a page break: not shown.
        case hidden

        init(_ kind: Block.Kind) {
            switch kind {
            case .heading(let level, let text):
                self = text.isBlank ? .hidden : level == 1 ? .section : .content
            case .paragraph(let text):
                self = text.isBlank ? .hidden : .content
            case .codeBlock(_, let code):
                self = code.allSatisfy(\.isWhitespace) ? .hidden : .content
            case .horizontalRule:
                self = .divider
            case .pageBreak:
                self = .hidden
            case .table, .base:
                self = .closing
            default:
                self = .content
            }
        }
    }

    /// Slides for blocks of these roles and heights, `spacing` apart, on slides `height` tall.
    static func slides(roles: [Role], heights: [CGFloat], height: CGFloat, spacing: CGFloat) -> [Slide] {
        var slides: [Slide] = []
        var current: [Int] = []
        var used: CGFloat = 0

        func close() {
            guard !current.isEmpty else { return }
            slides.append(Slide(blocks: current, scrolls: used > height))
            current = []
            used = 0
        }

        for (index, role) in roles.enumerated() {
            switch role {
            case .hidden:
                continue
            case .divider:
                close()
                continue
            case .content, .section, .closing:
                let blockHeight = index < heights.count ? heights[index] : 0
                if !current.isEmpty, role != .section, used + spacing + blockHeight <= height {
                    current.append(index)
                    used += spacing + blockHeight
                } else {
                    close()
                    current = [index]
                    used = blockHeight
                }
                if role == .closing { close() }
            }
        }
        close()
        return slides
    }

    /// The slide that shows `block`, or else the first one after it (it was left out); the last slide if none.
    static func slide(showing block: Int, in slides: [Slide]) -> Int {
        slides.firstIndex { ($0.blocks.last ?? -1) >= block } ?? max(slides.count - 1, 0)
    }
}

extension TextBlock {
    /// Only spaces and line breaks: an empty line.
    nonisolated var isBlank: Bool {
        inlines.allSatisfy { inline in
            switch inline {
            case .text(let text, _): text.allSatisfy(\.isWhitespace)
            case .hardBreak: true
            default: false
            }
        }
    }
}
