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

    /// A formula's sizes are capped (KaTeX's `maxSize`): `\rule{1em}{100000em}` asked for a web view about 1.7 million
    /// points tall (code review R34).
    @Test func formulaSizesAreCapped() async throws {
        let page = WebPage()
        for try await _ in page.load(html: IslandHTML.math(#"\rule{1em}{100000em}"#, displayMode: true), baseURL: IslandHTML.baseURL) {}
        let height = try await page.callJavaScript("await document.fonts.ready; return document.body.getBoundingClientRect().height;")
        #expect(try #require((height as? NSNumber)?.doubleValue) < 2_000)
    }

    /// An island is at most `maxHeight` tall, whatever its page measures: a diagram or picture from the page can be any
    /// height, and a web view millions of points tall is no use to anyone (code review R34).
    @Test func islandHeightIsCapped() {
        #expect(WebIslandView.height(measured: 1_700_000, minHeight: 44) == WebIslandView.maxHeight)
        #expect(WebIslandView.height(measured: .nan, minHeight: 44) == 44)
        #expect(WebIslandView.height(measured: 10, minHeight: 44) == 44)
        #expect(WebIslandView.height(measured: 500, minHeight: 44) == 500)
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
        // Up to 20 s: beside the other tests (or on GitHub's runners) a web process draws far slower than alone.
        for _ in 0..<200 where state.isEmpty {
            state = try await page.callJavaScript("""
                const d = document.getElementById("d");
                return d.querySelector("svg") ? "drawn" : (d.className === "error" ? "error: " + d.textContent : "");
                """) as? String ?? ""
            if state.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(state == "drawn", "\(code)")
    }
}
