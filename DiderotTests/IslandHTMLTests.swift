import Foundation
import Testing
import WebKit
@testable import Diderot

/// Island pages run JavaScript, so page content must reach them as data, never as markup.
struct IslandHTMLTests {
    @Test func diagramIsAnImage() {
        let markup = #"<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>"#
        let html = IslandHTML.svg(markup)

        #expect(html.contains(#"<img src="data:image/svg+xml;base64,\#(Data(markup.utf8).base64EncodedString())""#))
        #expect(!html.contains("<svg"))
    }

    @Test func textCannotEndTheScript() {
        let html = IslandHTML.mermaid("</script><!--<script>")

        #expect(html.contains(#""\u003C\/script>\u003C!--\u003Cscript>""#))
        #expect(!html.contains("<!--"))
    }

    /// The bundled Mermaid (Tools/build-islands.mjs) draws every kind of diagram, also one asking for the ELK layout,
    /// which it leaves out: dagre lays that one out instead of an error.
    @Test(arguments: [
        "flowchart TD\n  A --> B",
        "sequenceDiagram\n  Alice->>Bob: Hi",
        "mindmap\n  root\n    Child",
        "%%{init: {\"layout\": \"elk\"}}%%\nflowchart TD\n  A --> B",
        "flowchart-elk TD\n  A --> B",
    ])
    func diagramsRender(code: String) async throws {
        let page = WebPage()
        for try await _ in page.load(html: IslandHTML.mermaid(code), baseURL: IslandHTML.baseURL) {}
        var state = ""
        for _ in 0..<50 where state.isEmpty {
            state = try await page.callJavaScript("""
                const d = document.getElementById("d");
                return d.querySelector("svg") ? "drawn" : (d.className === "error" ? "error: " + d.textContent : "");
                """) as? String ?? ""
            if state.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(state == "drawn", "\(code)")
    }
}
