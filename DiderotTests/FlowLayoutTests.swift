import SwiftUI
import Testing
@testable import Diderot

/// Pills in the detail sheet wrap like words; a pill wider than the row truncates instead of running past the edge.
struct FlowLayoutTests {
    @Test func longPillWrapsAndStaysInsideTheRow() throws {
        let long = String(repeating: "Very long option name ", count: 10)
        let frames = placedFrames(of: ["iOS", long], width: 200)
        let short = try #require(frames["iOS"]), wide = try #require(frames[long])
        #expect(wide.minY > short.maxY)
        #expect(wide.minX == 0 && wide.maxX <= 200)
    }

    /// Where FlowLayout places pills with these names in a row `width` points wide, in the row's coordinates.
    private func placedFrames(of names: [String], width: CGFloat) -> [String: CGRect] {
        final class Frames { var byName: [String: CGRect] = [:] }
        let frames = Frames()
        let row = FlowLayout {
            ForEach(names, id: \.self) { name in
                ChoicePill(choice: BaseChoice(id: name, name: name, color: "blue"))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("row")) } action: { frames.byName[name] = $0 }
            }
        }
        .coordinateSpace(.named("row"))
        .frame(width: width)
        _ = ImageRenderer(content: row).cgImage
        return frames.byName
    }
}
