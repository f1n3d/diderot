import SwiftUI
import Testing
import DocmostKit
@testable import Diderot

/// A code block not being edited numbers its lines in a column beside the code. Each number sits on its line's
/// baseline, at every text size, also below a line too long for the block (which scrolls sideways rather than wraps).
struct CodeBlockLayoutTests {
    @Test(arguments: [DynamicTypeSize.xSmall, .large, .xxxLarge, .accessibility3])
    func lineNumbersSitOnTheirLines(size: DynamicTypeSize) async throws {
        // "x" and the digits stand on the baseline, so where their ink ends is where the line's baseline is.
        let lines = (1...11).map { $0 == 4 ? String(repeating: "x", count: 200) : "x" }
        let bottoms = try await inkBottoms(ofCode: lines.joined(separator: "\n"), size: size, lines: lines.count)
        #expect(bottoms.numbers.count == lines.count, "\(bottoms.numbers)")
        #expect(bottoms.code.count == lines.count, "\(bottoms.code)")
        for (line, (number, code)) in zip(bottoms.numbers, bottoms.code).enumerated() {
            // Within a point: round digits such as 0 dip a little below the baseline.
            #expect(abs(number - code) <= 1, "Line \(line + 1): number ends at \(number), code at \(code)")
        }
    }

    /// As many numbers as the code has lines: an empty block and an empty last line count as lines too.
    @Test func numbersEveryLine() {
        #expect(CodeNodeView.lineNumbers(of: "") == "1")
        #expect(CodeNodeView.lineNumbers(of: "let a = 1") == "1")
        #expect(CodeNodeView.lineNumbers(of: "a\n\nb\n") == "1\n2\n3\n4")
    }

    /// Where the ink of each number and of each line of code ends, in points from the window's top, top to bottom,
    /// once the block not being edited shows `count` of each in a window (up to 2 s), drawn at `size`.
    private func inkBottoms(ofCode text: String, size: DynamicTypeSize, lines count: Int) async throws -> (numbers: [CGFloat], code: [CGFloat]) {
        let code = PMNode(type: "codeBlock", content: [PMNode(type: "text", text: text)])
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: nil, readOnlyReason: .noPermission)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIHostingController(rootView: VStack {
            CodeNodeView(model: model, node: code, ref: NodeRef(path: [0], node: code))
            Spacer(minLength: 0)
        }.dynamicTypeSize(size))
        window.isHidden = false
        defer { window.isHidden = true }
        var bottoms: (numbers: [CGFloat], code: [CGFloat]) = ([], [])
        for _ in 0..<20 where bottoms.numbers.count != count || bottoms.code.count != count {
            try await Task.sleep(for: .milliseconds(100))
            window.layoutIfNeeded()
            bottoms = try inkBottoms(in: window)
        }
        return bottoms
    }

    /// The same for what `window` draws now; none if it shows no numbers beside code yet.
    private func inkBottoms(in window: UIWindow) throws -> (numbers: [CGFloat], code: [CGFloat]) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let bitmap = try #require(Bitmap(image))
        // The left third holds the numbers and the start of the code, "Copy" is at the right. The widest gap between
        // stretches of ink there is the one between the numbers and the code.
        let third = bitmap.width / 3
        let inkColumns = (0..<third).filter { x in (0..<bitmap.height).contains { bitmap.isInk(x: x, y: $0) } }
        let runs = Self.runs(of: inkColumns)
        guard let first = runs.first,
              let gap = zip(runs, runs.dropFirst()).max(by: { $0.1.lowerBound - $0.0.upperBound < $1.1.lowerBound - $1.0.upperBound })
        else { return ([], []) }

        func bottoms(in columns: ClosedRange<Int>) -> [CGFloat] {
            let inkRows = (0..<bitmap.height).filter { y in columns.contains { bitmap.isInk(x: $0, y: y) } }
            return Self.runs(of: inkRows).map { CGFloat($0.upperBound + 1) / image.scale }
        }
        return (bottoms(in: first.lowerBound...gap.0.upperBound), bottoms(in: gap.1.lowerBound...(third - 1)))
    }

    /// Runs of consecutive values in `values`, which ascend.
    private static func runs(of values: [Int]) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        for value in values {
            if let last = runs.last, last.upperBound == value - 1 {
                runs[runs.count - 1] = last.lowerBound...value
            } else {
                runs.append(value...value)
            }
        }
        return runs
    }

    /// An image's pixels, to tell text from the block's light background.
    private struct Bitmap {
        let width: Int
        let height: Int
        private let rgba: [UInt8]

        init?(_ image: UIImage) {
            guard let cgImage = image.cgImage else { return nil }
            width = cgImage.width
            height = cgImage.height
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = rgba.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(data: bytes.baseAddress, width: cgImage.width, height: cgImage.height,
                                              bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
                return true
            }
            guard drawn else { return nil }
            self.rgba = rgba
        }

        /// Darker than the window's white and the block's light gray, as even the numbers' tertiary gray is.
        func isInk(x: Int, y: Int) -> Bool {
            let index = (y * width + x) * 4
            return min(rgba[index], rgba[index + 1], rgba[index + 2]) < 220
        }
    }
}
