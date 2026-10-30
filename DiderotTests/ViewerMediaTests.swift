import Testing
import DocmostKit
@testable import Diderot

/// The full-screen viewer pages through the page's images and diagrams in reading order, as the web's lightbox: also
/// those inside lists, tables, columns, tabs and footnotes. Videos and media without a file aren't among them.
struct ViewerMediaTests {
    private func node(_ type: String, src: String? = nil, _ content: [PMNode] = []) -> PMNode {
        PMNode(type: type, attrs: src.map { ["src": .string($0)] }, content: content)
    }

    @Test func collectsImagesAndDiagramsInReadingOrder() {
        let doc = node("doc", [
            node("image", src: "/a.png"),
            node("bulletList", [node("listItem", [node("paragraph"), node("image", src: "/b.png")])]),
            node("video", src: "/clip.mp4"),
            node("table", [node("tableRow", [node("tableCell", [node("image", src: "/c.png")])])]),
            node("drawio", src: "/d.drawio.svg"),
            node("image", src: ""),
            node("columns", [node("column", [node("excalidraw", src: "/e.excalidraw.svg")])]),
            node("tabs", [node("tab", [node("tabLabel"), node("tabPanel", [node("image", src: "/f.png")])])]),
            node("footnotes", [node("footnote", [node("image", src: "/g.png")])]),
        ])
        let media = ViewerMedia.all(in: ContentParser.parse(doc))
        #expect(media.map(\.src) == ["/a.png", "/b.png", "/c.png", "/d.drawio.svg", "/e.excalidraw.svg", "/f.png", "/g.png"])
        #expect(media.map(\.isDiagram) == [false, false, false, true, true, false, false])
    }
}
