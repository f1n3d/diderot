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

#if DEBUG
/// What the engine's page answers to `document.visibilityState`, as an element a UI test reads
/// (`DOCMOST_DEBUG_ENGINE_VISIBILITY=1`, test106). WebKit says "visible" only while the page's view is in a window of the
/// active app: where the page view no longer shows `EngineHost`, the engine works on, and WebKit suspends it between
/// the app's calls on a device. The simulator doesn't stop suspended processes, so no other test noticed (code review
/// of November 12, 2026). Asked twice a second, which changes nothing about what WebKit answers, but a page that is
/// called isn't suspended: with the value set, a suspension can't be watched.
struct EngineVisibilityProbe: View {
    let page: WebPage
    @State private var answer = "not asked"
    /// Which engine page of the run this is, as its value: one closed and opened again shows the next number (test81).
    @State private var number: Int?
    private static var made = 0

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier("engine-visibility")
            .accessibilityLabel(answer)
            .accessibilityValue(number.map { "engine \($0)" } ?? "")
            .onAppear {
                if number == nil {
                    Self.made += 1
                    number = Self.made
                }
            }
            .task {
                while !Task.isCancelled {
                    answer = (try? await page.callJavaScript("return document.visibilityState") as? String) ?? "no answer"
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
    }
}
#endif
