import SwiftUI
import Testing
@testable import Diderot

/// The presentation mode's laser pointer (on an iPad): its dot follows the pointer while it is on and goes when the
/// pointer leaves. A move of the pointer draws the dot again and nothing else: the presentation's body read the
/// position, so each of the pointer's 60 to 120 moves a second ran it again, and with it every heading of the page.
struct LaserPointerTests {
    @Test func dotFollowsThePointerAndNothingElseDrawsAgain() async throws {
        let position = LaserPointerPosition()
        let runs = BodyRuns()
        let host = UIHostingController(rootView: Stage(position: position, isOn: true, runs: runs))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }

        let first = CGPoint(x: 60, y: 120)
        let second = CGPoint(x: 200, y: 300)
        position.point = first
        #expect(await poll { dot(at: first, in: window) }, "at the pointer")
        let before = runs.count
        position.point = second
        #expect(await poll { dot(at: second, in: window) && !dot(at: first, in: window) }, "follows it")
        #expect(runs.count == before, "the views under the dot didn't run again")
        position.point = nil
        #expect(await poll { !dot(at: second, in: window) }, "goes when the pointer leaves")

        position.point = first
        #expect(await poll { dot(at: first, in: window) })
        host.rootView = Stage(position: position, isOn: false, runs: runs)
        #expect(await poll { !dot(at: first, in: window) }, "none while the laser pointer is off")
    }

    /// The dot over a view that counts its body's runs, as over the slides. This body hands that view a new closure
    /// each time it runs, as the presentation hands the headings their fonts (one capturing nothing would be the same
    /// each time): so the view runs again whenever this body does.
    private struct Stage: View {
        let position: LaserPointerPosition
        let isOn: Bool
        let runs: BodyRuns

        var body: some View {
            let size = UIFont.preferredFont(forTextStyle: .body).pointSize
            Probe(runs: runs)
                .environment(\.headingFont) { _ in .system(size: size * 2) }
                .overlay { LaserDot(position: position, isOn: isOn) }
                // The dot's coordinates are then the window's.
                .ignoresSafeArea()
        }
    }

    private struct Probe: View {
        let runs: BodyRuns
        @Environment(\.headingFont) private var headingFont

        var body: some View {
            let _ = runs.record()
            Color.clear
        }
    }

    private final class BodyRuns {
        private(set) var count = 0
        func record() { count += 1 }
    }

    /// Whether the window shows the dot's blue at `point` (over white, or black in dark mode).
    private func dot(at point: CGPoint, in window: UIWindow) -> Bool {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)), format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let cgImage = image.cgImage else { return false }
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Int(pixel[2]) - Int(pixel[0]) > 60
    }

    /// Polls `condition` while SwiftUI draws (up to 5 s).
    private func poll(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}
