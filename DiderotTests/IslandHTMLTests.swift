import Foundation
import Testing
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
}
