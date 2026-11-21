import Foundation
import Testing
import DocmostKit
@testable import Diderot

/// Page covers (Docmost 0.98), read and laid out as the web's `page-cover.utils.ts` does.
struct PageCoverTests {
    private static let fileId = "019a1f00-0000-7000-8000-0000000000aa"

    /// Every kind the web shows: a color, a gradient or texture of its presets, an upload on the server (also a shared
    /// page's public one), an Unsplash photo.
    @Test func coversOfEveryKindAreRead() throws {
        let red = try #require(CoverPreset.colors.first)
        #expect(PageCover("preset:color-red") == .preset(red))
        #expect(red.color != nil && red.kind == .color)
        #expect(kind("preset:gradient-aurora") == .gradient)
        #expect(kind("preset:texture-graph") == .texture)
        #expect(PageCover("/api/files/\(Self.fileId)/team offsite.jpg") == .file(path: "/api/files/\(Self.fileId)/team offsite.jpg"))
        #expect(PageCover("/API/Files/\(Self.fileId.uppercased())/Cover.JPG") != nil)
        #expect(PageCover("/api/files/public/\(Self.fileId)/cover.jpg?jwt=eyJh.eyJw.sig-_") != nil)
        let unsplash = "https://images.unsplash.com/photo-1?ixid=abc&w=2560&q=80&auto=format&fit=max"
        #expect(PageCover(unsplash) == .unsplash(URL(string: unsplash)!))
        #expect(PageCover("https://images.unsplash.com:443/photo-1") != nil)
        #expect(CoverPreset.all.count == 24 && Set(CoverPreset.all.map(\.id)).count == 24)
        #expect(CoverPreset.all.allSatisfy { PageCover($0.value) == .preset($0) })
    }

    /// Anything else is no cover: an unknown preset (a newer server's), an address elsewhere, a path that leaves the file,
    /// a lookalike of Unsplash's host.
    @Test func unknownValuesAreNoCover() {
        let values: [String?] = [
            nil, "", "preset:does-not-exist", "preset:", "https://tracker.example/pixel.png", "//tracker.example/pixel.png",
            "javascript:alert(1)", "/api/files/\(Self.fileId)/cover.jpg?w=1", "/api/files/\(Self.fileId)/../../secret",
            "/api/files/\(Self.fileId)/..", "/api/files/\(Self.fileId)/.", "/api/files/\(Self.fileId)/a\\b.png",
            "/api/files/not-an-id/cover.jpg", "/files/\(Self.fileId)/cover.jpg",
            "http://images.unsplash.com/photo-1", "https://images.unsplash.com.evil.example/photo-1",
            "https://evil.example/?https://images.unsplash.com/photo-1", "https://user@images.unsplash.com/photo-1",
            "https://images.unsplash.com:8443/photo-1",
        ]
        for value in values {
            #expect(PageCover(value) == nil, "\(value ?? "nil")")
        }
    }

    /// The position as shown: 0–100, the middle without one.
    @Test func positionsStayWithinTheBand() {
        let cases: [(Double?, Double)] = [(42, 42), (0, 0), (100, 100), (150, 100), (-5, 0), (nil, 50), (.nan, 50), (.infinity, 50)]
        for (stored, shown) in cases {
            #expect(PageCover.position(stored) == shown, "\(String(describing: stored))")
        }
    }

    /// Only pictures move: a color fills the band at any position.
    @Test func picturesMoveColorsDont() throws {
        #expect(PageCover("preset:color-blue")?.isImage == false)
        #expect(PageCover("preset:gradient-dusk")?.isImage == true)
        #expect(PageCover("preset:texture-waves")?.isImage == true)
        #expect(PageCover("/api/files/\(Self.fileId)/a.png")?.isImage == true)
        #expect(PageCover("https://images.unsplash.com/photo-1")?.isImage == true)
    }

    /// As high as the web's band: `clamp(120px, 18vh, 150px)` up to 768 points wide, `clamp(160px, 26vh, 240px)` above.
    @Test func theBandIsAsHighAsTheWebs() {
        #expect(PageCover.bandHeight(width: 420, viewportHeight: 880) == 150)
        #expect(PageCover.bandHeight(width: 768, viewportHeight: 500) == 120)
        #expect(PageCover.bandHeight(width: 375, viewportHeight: 750) == 135)
        #expect(PageCover.bandHeight(width: 956, viewportHeight: 400) == 160)
        #expect(PageCover.bandHeight(width: 1024, viewportHeight: 1300) == 240)
    }

    /// `object-fit: cover`: the picture covers the band, centered across; the position says how much of what reaches past
    /// it shows above (0 its top, 100 its bottom).
    @Test func picturesCoverTheBandAtTheirPosition() {
        let box = CGSize(width: 1200, height: 280)
        #expect(PageCover.imageFrame(natural: CGSize(width: 2400, height: 800), in: box, position: 50) == CGRect(x: 0, y: -60, width: 1200, height: 400))
        #expect(PageCover.imageFrame(natural: CGSize(width: 2400, height: 800), in: box, position: 0).minY == 0)
        #expect(PageCover.imageFrame(natural: CGSize(width: 2400, height: 800), in: box, position: 100).maxY == 280)
        // Wider than the band: it fills the height and is cut at both sides.
        #expect(PageCover.imageFrame(natural: CGSize(width: 2400, height: 400), in: box, position: 30) == CGRect(x: -240, y: 0, width: 1680, height: 280))
        #expect(PageCover.imageFrame(natural: .zero, in: box, position: 50) == CGRect(origin: .zero, size: box))
    }

    /// What repositioning moves (`getCoverOverflow`), and where a drag puts the picture (`getCoverPositionAfterDrag`).
    @Test func dragsMoveThePictureWithTheFinger() {
        let box = CGSize(width: 1200, height: 280)
        #expect(abs(PageCover.overflow(natural: CGSize(width: 2400, height: 800), box: box) - 120) < 0.001)
        #expect(abs(PageCover.overflow(natural: CGSize(width: 1000, height: 1000), box: CGSize(width: 1000, height: 250)) - 750) < 0.001)
        #expect(PageCover.overflow(natural: CGSize(width: 2400, height: 400), box: box) == 0)
        #expect(PageCover.overflow(natural: .zero, box: box) == 0)
        let drags: [(start: Double, deltaY: CGFloat, overflow: CGFloat, end: Double)] = [
            (50, 60, 120, 0), (50, -30, 120, 75), (50, 500, 120, 0), (50, -500, 120, 100), (40, 10, 0, 40),
        ]
        for drag in drags {
            #expect(abs(PageCover.position(afterDragging: drag.deltaY, from: drag.start, overflow: drag.overflow) - drag.end) < 0.001, "\(drag)")
        }
    }

    /// "Add Cover" picks one of the quieter gradients, never the cover the page has.
    @Test func addCoverPicksAQuietGradient() {
        var picked = Set<String>()
        for _ in 0..<300 {
            picked.insert(CoverPreset.randomGradient(replacing: "preset:gradient-sky").id)
        }
        #expect(picked == ["gradient-slate", "gradient-dusk", "gradient-aurora", "gradient-dune"])
    }

    private func kind(_ value: String) -> CoverPreset.Kind? {
        if case .preset(let preset) = PageCover(value) { preset.kind } else { nil }
    }
}

extension AppSessionRaceTests {
    /// Cover changes (`PageCoverEdit`): shown at once, sent one after another, the page loaded again after the newest.
    @Suite struct PageCovers: SessionStubbing {
        let store = SessionStore(keychain: MemorySecretStore())

        /// A second pick waits for the first to be answered, as the web's queue per page does, so the server can't end up
        /// with the first; the band shows the newest at once, and only the newest loads the page again.
        @Test(.timeLimit(.minutes(1))) func coverChangesGoOutOneAfterAnother() async throws {
            let session = try await sessionOnA()
            let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id": "p1", "spaceId": "s1", "coverPhoto": null}"#.utf8))
            let edit = PageCoverEdit()
            var loads = 0
            var reports: [String] = []
            let actions = PageCoverActions(edits: PageEdits(page: page, owner: try #require(session.ready), session: session, changes: ContentChanges()),
                                           reload: { loads += 1 }, report: { reports.append($0) })
            func updates() -> Int { StubURLProtocol.requests.withLock { $0 }.count { $0 == "a.example.com/api/pages/update" } }
            StubURLProtocol.requests.withLock { $0 = [] }
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "p1"}}"# }
            defer { StubURLProtocol.body.withLock { $0 = nil } }
            let (answer, release) = AsyncStream<Void>.makeStream()
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = "a.example.com/api/pages/update" }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { for await _ in answer { break } } }
            defer { StubURLProtocol.beforeNextAnswerFor.withLock { $0 = nil } }

            let first = edit.send(.photo("preset:color-red"), shown: edit.fields(of: page), with: actions)
            let second = edit.send(.photo("preset:gradient-sky"), shown: edit.fields(of: page), with: actions)
            #expect(edit.fields(of: page) == PageCoverEdit.Fields(photo: "preset:gradient-sky", position: nil))
            for _ in 0..<200 where updates() == 0 { try await Task.sleep(for: .milliseconds(10)) }
            try await Task.sleep(for: .milliseconds(200))
            #expect(updates() == 1, "The second change went out before the first was answered")
            release.yield()
            #expect(await first.value)
            #expect(await second.value)
            #expect(updates() == 2 && loads == 1 && reports.isEmpty)
            #expect(edit.pending == nil)
            await removeCaches()
        }

        /// A change the server refuses says so, as the web does, and the band shows the page's cover again.
        @Test func aRefusedChangeSaysSo() async throws {
            let session = try await sessionOnA()
            let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id": "p1", "coverPhoto": "preset:color-red", "coverPosition": 20}"#.utf8))
            let edit = PageCoverEdit()
            var loads = 0
            var reports: [String] = []
            let actions = PageCoverActions(edits: PageEdits(page: page, owner: try #require(session.ready), session: session, changes: ContentChanges()),
                                           reload: { loads += 1 }, report: { reports.append($0) })
            StubURLProtocol.status.withLock { $0 = 403 }
            StubURLProtocol.body.withLock { $0 = #"{"statusCode": 403, "message": "Forbidden"}"# }
            defer {
                StubURLProtocol.status.withLock { $0 = 200 }
                StubURLProtocol.body.withLock { $0 = nil }
            }
            let sent = edit.send(.position(80), shown: edit.fields(of: page), with: actions)
            #expect(edit.fields(of: page) == PageCoverEdit.Fields(photo: "preset:color-red", position: 80))
            #expect(await sent.value == false)
            #expect(reports == [String(localized: "Failed to update cover")] && loads == 0)
            #expect(edit.fields(of: page) == PageCoverEdit.Fields(photo: "preset:color-red", position: 20))
            await removeCaches()
        }
    }
}
