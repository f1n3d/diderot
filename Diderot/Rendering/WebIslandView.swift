import SwiftUI
import WebKit

/// Small web island for content SwiftUI can't render natively (KaTeX, Mermaid, SVG), sized to its content height.
/// The app bundle is the base URL, so the bundled scripts and fonts resolve.
struct WebIslandView: View {
    let html: String
    var minHeight: CGFloat = 44

    @State private var page = WebPage(navigationDecider: WebNavigationLimit(home: IslandHTML.baseURL))
    @State private var height: CGFloat?
    /// What is shown at the measured height; back in view, it isn't rendered again unless the web process ended (iOS
    /// reclaimed its memory, a crash) and left the page blank, without a URL.
    @State private var rendered: Look?
    @State private var width: CGFloat = 0
    /// Counts renders after the web process ended while the island stayed in view (the app in the background).
    @State private var revivals = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase

    /// Everything the rendered page depends on; the width only changes its height.
    private struct Look: Equatable {
        let html: String
        let colorScheme: ColorScheme
        let typeSize: DynamicTypeSize
        let revivals: Int
    }

    var body: some View {
        let look = Look(html: html, colorScheme: colorScheme, typeSize: typeSize, revivals: revivals)
        WebView(page)
            // One element for VoiceOver, read with the label its user sets (formula, diagram): not the web content
            // and its two scroll bars.
            .accessibilityElement(children: .ignore)
            .frame(height: height ?? minHeight)
            .opacity(height == nil ? 0 : 1)
            .overlay {
                if height == nil { ProgressView() }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { width = $0 }
            .task(id: look) { await render(look) }
            // A new width (rotation, iPad window, columns) reflows the content: measure again.
            .task(id: width) { if rendered == look { try? await measureHeight() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, rendered != nil, page.url == nil { revivals += 1 }
            }
    }

    private func render(_ look: Look) async {
        guard rendered != look || page.url == nil else { return }
        rendered = nil
        height = nil
        page.load(html: look.html, baseURL: IslandHTML.baseURL)
        do {
            // Page-wide events, not the load's: those stop the load on task cancel, then callJavaScript never returns.
            for try await event in page.navigations {
                if case .finished = event { break }
            }
            try await measureHeight(afterFonts: true)
            // A cancelled render may have measured before its page loaded; it renders again on return.
            if !Task.isCancelled { rendered = look }
        } catch {
            AppLog.ui.debug("Island failed: \(error.localizedDescription, privacy: .public)")
            height = minHeight
        }
    }

    /// The body's height: the document's scroll height never drops below the view's current height.
    private func measureHeight(afterFonts: Bool = false) async throws {
        let script = (afterFonts ? "await document.fonts.ready; " : "") + "return Math.ceil(document.body.getBoundingClientRect().height);"
        let measured = try await page.callJavaScript(script)
        height = max(CGFloat((measured as? NSNumber)?.doubleValue ?? 0), minHeight)
    }
}

/// HTML templates for the islands. Text is embedded as JSON and diagram SVGs as `<img>`, where their scripts don't run.
/// The bundled scripts and fonts load; nothing from the network, so not even a flaw in KaTeX or Mermaid could send
/// content anywhere.
nonisolated enum IslandHTML {
    /// The app bundle, where the scripts and fonts are.
    static let baseURL = Bundle.main.resourceURL ?? Bundle.main.bundleURL

    private static let baseStyle = """
    <meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src file: 'unsafe-inline'; style-src file: 'unsafe-inline'; font-src file:; img-src file: data:">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
    <meta name="color-scheme" content="light dark">
    <style>
      :root { color-scheme: light dark; }
      html, body { margin: 0; padding: 0; background: transparent; color: CanvasText;
                   font: -apple-system-body; font-family: -apple-system, system-ui; overflow: hidden; }
      body { padding: 4px 0; }
      svg, img { max-width: 100%; height: auto; }
    </style>
    """

    static func math(_ latex: String, displayMode: Bool) -> String {
        """
        <!doctype html><html><head>\(baseStyle)
        <link rel="stylesheet" href="katex.min.css">
        <script src="katex.min.js"></script>
        <style>.katex-display { margin: 0; overflow-x: auto; overflow-y: hidden; } .error { color: #e03131; font-family: ui-monospace, monospace; }</style>
        </head><body><div id="m"></div>
        <script>
          try {
            katex.render(\(json(latex)), document.getElementById("m"), { displayMode: \(displayMode), throwOnError: false });
          } catch (e) { Object.assign(document.getElementById("m"), { className: "error", textContent: String(e) }); }
        </script></body></html>
        """
    }

    static func mermaid(_ code: String) -> String {
        """
        <!doctype html><html><head>\(baseStyle)
        <script src="mermaid.min.js"></script>
        <style>#d svg { max-width: 100%; } .error { color: #e03131; font-family: ui-monospace, monospace; white-space: pre-wrap; }</style>
        </head><body><div id="d"></div>
        <script>
          (async () => {
            const dark = window.matchMedia("(prefers-color-scheme: dark)").matches;
            mermaid.initialize({ startOnLoad: false, theme: dark ? "dark" : "default", securityLevel: "strict" });
            try {
              const { svg } = await mermaid.render("diagram", \(json(code)));
              document.getElementById("d").innerHTML = svg;
            } catch (e) {
              Object.assign(document.getElementById("d"), { className: "error", textContent: String(e) });
            }
          })();
        </script></body></html>
        """
    }

    static func svg(_ markup: String) -> String {
        """
        <!doctype html><html><head>\(baseStyle)</head><body><img src="data:image/svg+xml;base64,\(Data(markup.utf8).base64EncodedString())" alt=""></body></html>
        """
    }

    private static func json(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text), let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        // Escaping `<` keeps `</script>` and `<!--` in the content from ending or breaking the script element.
        return encoded.replacingOccurrences(of: "<", with: "\\u003C")
    }
}
