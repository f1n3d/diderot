import XCTest

/// App Store screenshots (Tools/screenshots.sh): the demo space as its member Alex sees it (Tools/seed-demo.py), in
/// the language the script picks. Skipped in the normal runs.
@MainActor final class ScreenshotUITests: XCTestCase {
    private var language: String { environment["DOCMOST_UITEST_SCREENSHOTS"] ?? "" }
    /// The demo pages' slug IDs by name (welcome, roadmap, sync, engineering, brand, tasks).
    private var pages: [String: String] = [:]

    override func setUpWithError() throws {
        try XCTSkipIf(language.isEmpty, "Only for Tools/screenshots.sh")
        try requireEnvironment(["DOCMOST_UITEST_SCREENSHOT_PAGES"])
        pages = try JSONDecoder().decode([String: String].self, from: Data(environment["DOCMOST_UITEST_SCREENSHOT_PAGES", default: ""].utf8))
    }

    private func launch(page: String? = nil, _ extra: [String: String] = [:]) -> XCUIApplication {
        var launchEnvironment = extra
        if let page { launchEnvironment["DOCMOST_DEBUG_PAGE"] = pages[page] }
        return launchApp(extraEnvironment: launchEnvironment,
                         arguments: ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "de" ? "de_DE" : "en_US"])
    }

    private func text(_ app: XCUIApplication, _ english: String, _ german: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", language == "de" ? german : english)).firstMatch
    }

    /// The whole screen, status bar included, as `<name>.png` in the script's folder.
    private func shoot(_ name: String, settle: TimeInterval = 1.5) {
        Thread.sleep(forTimeInterval: settle)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = environment["DOCMOST_SHOTS_DIR"], !directory.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    func test1_Page() {
        let app = launch(page: "welcome")
        XCTAssertTrue(text(app, "Try it", "Ausprobieren").waitForExistence(timeout: 30), "Welcome page missing")
        shoot("1-page", settle: 3)
    }

    func test2_TableAndDiagram() {
        let app = launch(page: "roadmap")
        XCTAssertTrue(text(app, "Offline editing", "Offline bearbeiten").waitForExistence(timeout: 30), "Roadmap missing")
        shoot("2-roadmap", settle: 4)
    }

    func test3_Editing() {
        let app = launch(page: "sync")
        // A line near the middle above the keyboard: a tap centers its line, and the title stays in view.
        let item = text(app, "Decisions", "Entscheidungen")
        XCTAssertTrue(item.waitForExistence(timeout: 30), "Weekly Sync missing")
        // Editable once the engine has synced, as the editor tests wait for it.
        let pill = element(app, "page-status")
        XCTAssertTrue(pill.waitForExistence(timeout: 40), "Page didn't load")
        wait(for: [expectation(for: NSPredicate(format: "label IN %@", ["Saved", "Gespeichert"]), evaluatedWith: pill)], timeout: 30)
        // At the end of the line, as the editor tests tap.
        item.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.85)).withOffset(CGVector(dx: -2, dy: 0)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "Editing doesn't start (on-screen keyboard off?)")
        // A fresh simulator's keyboard first explains swiping across the letters.
        let introduction = app.buttons.matching(NSPredicate(format: "label IN %@", ["Continue", "Fortfahren", "Weiter"])).firstMatch
        if introduction.waitForExistence(timeout: 2) { introduction.tap() }
        shoot("3-editing")
    }

    func test4_Comments() {
        let app = launch(page: "sync", ["DOCMOST_DEBUG_ROUTE": "comments"])
        XCTAssertTrue(text(app, "Tuesday it is", "dann Dienstag").waitForExistence(timeout: 30), "Comments missing")
        shoot("4-comments")
    }

    func test5_Board() {
        let app = launch(page: "tasks", ["DOCMOST_DEBUG_BASE_VIEW": "Board"])
        XCTAssertTrue(element(app, "base-kanban").waitForExistence(timeout: 30), "Board missing")
        shoot("5-board", settle: 3)
    }
}
