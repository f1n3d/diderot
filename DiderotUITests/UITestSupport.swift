import XCTest

/// UI test helpers: the environment from `Tools/run-uitests.sh`, app launch, screenshots and element lookups.
@MainActor extension XCTestCase {
    nonisolated var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// Stops at the first failure; skips the test unless the dev server's sign-in and `extraKeys` are set.
    nonisolated func requireEnvironment(_ extraKeys: [String] = []) throws {
        continueAfterFailure = false
        for key in ["DOCMOST_DEBUG_SERVER", "DOCMOST_DEBUG_EMAIL", "DOCMOST_DEBUG_PASSWORD"] + extraKeys where environment[key] == nil {
            throw XCTSkip("\(key) is not set")
        }
    }

    /// Launches the app signed in to the dev server. Spaces show as a list, or as tiles with `gridLayout`; that and
    /// `arguments` go to the argument domain, so they override the device setting for this launch only.
    func launchApp(extraEnvironment: [String: String] = [:], gridLayout: Bool = false, arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var launchEnvironment = extraEnvironment
        for key in ["DOCMOST_DEBUG_SERVER", "DOCMOST_DEBUG_EMAIL", "DOCMOST_DEBUG_PASSWORD"] {
            if let value = environment[key] { launchEnvironment[key] = value }
        }
        app.launchEnvironment = launchEnvironment
        app.launchArguments = ["-home.spacesGrid", gridLayout ? "YES" : "NO"] + arguments
        app.launch()
        return app
    }

    func snapshot(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // Also written as a file (SHOTS_DIR in run-uitests.sh) so it survives a lost result bundle.
        if let directory = environment["DOCMOST_SHOTS_DIR"], !directory.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    /// Element of any type with this accessibility identifier.
    func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Button by label (English or German UI), for buttons without an identifier: `Section` menu items lose theirs.
    func button(_ app: XCUIApplication, labels: [String]) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    /// Asserts that the open confirmation shows as a popover at `anchor`, the frame of the view that opened it (read
    /// before tapping: a toolbar button hides while its popover shows). Attached to a whole screen, it would show at a
    /// fixed spot at the top.
    func assertPopover(_ app: XCUIApplication, at anchor: CGRect) {
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5), "Confirmation doesn't show as a popover")
        let frame = popover.frame
        // Widest gap between the two frames; zero or less when they touch or overlap.
        let gap = max(frame.minX - anchor.maxX, anchor.minX - frame.maxX, frame.minY - anchor.maxY, anchor.minY - frame.maxY)
        XCTAssertLessThanOrEqual(gap, 4, "Confirmation \(frame) doesn't show at the view that opened it \(anchor)")
    }

    /// Closes the open popover without choosing anything: taps the middle of the larger free band above or below it
    /// (the dismiss region's own center can lie on the popover's button).
    func dismissPopover(_ app: XCUIApplication) {
        let popover = app.popovers.firstMatch
        let frame = popover.frame, window = app.windows.firstMatch.frame
        let y = frame.minY - window.minY > window.maxY - frame.maxY ? (window.minY + frame.minY) / 2 : (frame.maxY + window.maxY) / 2
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.midX, dy: y)).tap()
        XCTAssertTrue(popover.waitForNonExistence(timeout: 5), "Confirmation doesn't close")
    }
}
