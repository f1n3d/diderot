import SwiftUI
import Testing
import UIKit
import WebKit
@testable import Diderot

/// The engine's page counts as visible to WebKit while `EngineHost` shows it in a window, and only then: WebKit puts the
/// web process of a page that counts as hidden into its "suspended" state between the app's calls (see `EngineHost`).
@MainActor struct EngineHostTests {
    @Test(.timeLimit(.minutes(1))) func pageCountsAsVisibleWhileShown() async throws {
        let page = WebViews.engine(server: IslandHTML.baseURL) { _ in }
        for try await _ in page.load(html: "<!doctype html><p>", baseURL: IslandHTML.baseURL) {}
        #expect(await visibility(of: page) == "hidden")

        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: EngineHost(page: page))
        window.isHidden = false
        defer { window.isHidden = true }
        #expect(await until(page, is: "visible"))

        // The page left the screen: hidden again.
        window.rootViewController = nil
        #expect(await until(page, is: "hidden"))
    }

    private func visibility(of page: WebPage) async -> String? {
        try? await page.callJavaScript("return document.visibilityState") as? String
    }

    /// Polls up to 5 s: WebKit tells the page once its view is in a window, or no longer.
    private func until(_ page: WebPage, is state: String) async -> Bool {
        for _ in 0..<100 {
            if await visibility(of: page) == state { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}
