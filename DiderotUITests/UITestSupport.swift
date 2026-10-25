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

    /// Skips a test of content Docmost 0.97 introduced unless the dev server runs 0.97 or newer
    /// (`PORT=3001 Tools/run-uitests.sh`; the script passes the server's version).
    nonisolated func requireDocmost097() throws {
        let version = environment["DOCMOST_SERVER_VERSION"] ?? ""
        let parts = version.split(separator: ".").prefix(2).compactMap { Int($0) }
        guard parts.count == 2, (parts[0], parts[1]) >= (0, 97) else {
            throw XCTSkip("Needs Docmost 0.97 or newer, the server runs \(version.isEmpty ? "an unknown version" : version)")
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

    /// Taps a sheet's bar button such as Done. On the iPhone Duo's outer display the sheet's bar hides while its
    /// content is scrolled down, so this first drags the content back, slowly from the left edge.
    func tapSheetBarButton(_ button: XCUIElement, in sheet: XCUIElement) {
        for _ in 0..<8 where !button.exists {
            let start = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.3))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 150)), withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        button.tap()
    }

    /// The in-app browser's close button: "Close", or "Cancel" on the iPhone Duo's outer display.
    func browserCloseButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@ OR identifier == 'CancelBarItemButton'", ["Close", "Schließen"])).firstMatch
    }

    /// The back button that can be tapped, by its identifier: on the iPhone Duo's outer display the bar's buttons sit
    /// in a column beside the status bar, outside the navigation bar's element. Under a sheet, the page's stays in
    /// the tree but can't be tapped.
    func backButton(_ app: XCUIApplication) -> XCUIElement {
        let buttons = app.buttons.matching(identifier: "BackButton")
        return buttons.allElementsBoundByIndex.first(where: \.isHittable) ?? buttons.firstMatch
    }

    /// Asserts that the open confirmation shows as a popover at `anchor`, the frame of the view that opened it (read
    /// before tapping: a toolbar button hides while its popover shows). Attached to a whole screen, it would show at a
    /// fixed spot at the top.
    func assertPopover(_ app: XCUIApplication, at anchor: CGRect) {
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5), "Confirmation doesn't show as a popover")
        let frame = popover.frame
        // Widest gap between the two frames; zero or less when they touch or overlap. Up to 24 points: on the iPhone
        // Duo's outer display the popover can sit beside the view, its arrow in between.
        let gap = max(frame.minX - anchor.maxX, anchor.minX - frame.maxX, frame.minY - anchor.maxY, anchor.minY - frame.maxY)
        XCTAssertLessThanOrEqual(gap, 24, "Confirmation \(frame) doesn't show at the view that opened it \(anchor)")
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
