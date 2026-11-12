import SwiftUI
import WebKit

/// The engine's page (`WebDocumentEngine`) shown out of sight while its page is on the screen, so that WebKit runs it as a
/// visible page. WebKit counts a web view as visible when it is in a window of the active app, whatever its size or
/// opacity. The engine's page had no view: between the app's calls WebKit put its web process into its "suspended" state
/// and released the network process with it (in the simulator's WebKit log on November 12, 2026: 63 s after returning to
/// the app, until the next edit). On the iPhone, back in the app after a while, the page said "Connecting" until an edit
/// called the engine: most likely the reconnect stood still in between.
struct EngineHost: View {
    let page: WebPage

    var body: some View {
        WebView(page)
            .frame(width: 1, height: 1)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
