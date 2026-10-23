import XCTest

/// Multiple servers: adds the dev instance under a second address (`DOCMOST_UITEST_ALT_SERVER`: 127.0.0.1 on the
/// simulator, the Mac's LAN address on a device), switches via workspace menu and server list, signs out of the second.
@MainActor final class ServerUITests: XCTestCase {
    override func setUpWithError() throws {
        try requireEnvironment(["DOCMOST_UITEST_ALT_SERVER"])
    }

    // MARK: - Helpers

    /// Lowercased host, since the app normalizes addresses (e.g. `Adas-MacBook-Pro.local`).
    private func host(of address: String) -> String {
        (URL(string: address)?.host() ?? address).lowercased()
    }

    /// Row in the server list. Its identifier keeps the host's case (on a device `Adas-MacBook-Pro.local`).
    private func serverRow(_ app: XCUIApplication, _ address: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier ==[c] %@", "server-" + host(of: address))).firstMatch
    }

    private func waitForHome(_ app: XCUIApplication, _ message: String) {
        let slug = environment["DOCMOST_UITEST_SPACE_SLUG"] ?? "demo"
        XCTAssertTrue(app.buttons["space-\(slug)"].waitForExistence(timeout: 30), message)
    }

    /// Opens the workspace menu, retrying: right after a server switch the first tap may do nothing.
    private func openMenu(_ app: XCUIApplication) {
        let menu = app.buttons["workspace-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "Workspace menu missing")
        let signOut = app.buttons["sign-out"]
        for _ in 0..<3 {
            menu.tap()
            if signOut.waitForExistence(timeout: 3) { return }
        }
        XCTFail("Workspace menu doesn't open")
    }

    /// Opens settings and checks the displayed server address.
    private func assertSettingsShow(server: String, in app: XCUIApplication) {
        openMenu(app)
        let settings = button(app, labels: ["Settings", "Einstellungen"])
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "“Settings” missing from the menu")
        settings.tap()
        // `LabeledContent` merges label and value into one element ("Server, http://…").
        let shown = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", server)).firstMatch
        XCTAssertTrue(shown.waitForExistence(timeout: 10), "Settings don't show \(server)")
    }

    // MARK: - Test

    func test12_AddServerSwitchAndSignOut() {
        let app = launchApp()
        let primary = environment["DOCMOST_DEBUG_SERVER"]!
        let alternate = environment["DOCMOST_UITEST_ALT_SERVER"]!
        waitForHome(app, "Home screen missing")

        // Add a second server: server entry (with Cancel), sign-in, its home screen.
        openMenu(app)
        let add = button(app, labels: ["Add Server…", "Server hinzufügen…"])
        XCTAssertTrue(add.waitForExistence(timeout: 5), "“Add Server” missing from the menu")
        add.tap()
        let address = app.textFields["server-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10), "Server entry doesn't appear")
        XCTAssertTrue(app.buttons["server-cancel"].exists, "“Cancel” missing although a sign-in is saved")
        address.tap()
        address.typeText(alternate)
        app.buttons["server-continue"].tap()
        // The dev instance runs on plain HTTP: the app asks before the password travels unencrypted, and says so then.
        let anyway = button(app, labels: ["Connect Anyway", "Trotzdem verbinden"])
        XCTAssertTrue(anyway.waitForExistence(timeout: 5), "No warning before connecting over HTTP")
        anyway.tap()
        let email = app.textFields["login-email"]
        XCTAssertTrue(email.waitForExistence(timeout: 20), "Login for the second server doesn't appear")
        XCTAssertTrue(element(app, "login-unencrypted").exists, "The sign-in doesn't say the connection is unencrypted")
        email.tap()
        email.typeText(environment["DOCMOST_DEBUG_EMAIL"]!)
        let password = app.secureTextFields["login-password"]
        password.tap()
        password.typeText(environment["DOCMOST_DEBUG_PASSWORD"]!)
        app.buttons["login-submit"].tap()
        waitForHome(app, "Home screen of the second server missing")
        snapshot(app, "12-second-server")

        // Back to the first server via the workspace menu.
        openMenu(app)
        let primaryEntry = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", host(of: primary))).firstMatch
        XCTAssertTrue(primaryEntry.waitForExistence(timeout: 5), "First server missing from the menu")
        snapshot(app, "12-menu")
        primaryEntry.tap()
        waitForHome(app, "Home screen of the first server missing after the switch")
        assertSettingsShow(server: primary, in: app)

        // To the second server via the server list in settings.
        app.buttons["settings-servers"].tap()
        let alternateRow = serverRow(app, alternate)
        XCTAssertTrue(alternateRow.waitForExistence(timeout: 5), "Second server missing from the list")
        snapshot(app, "12-servers")
        alternateRow.tap()
        waitForHome(app, "Home screen of the second server missing after the switch")
        assertSettingsShow(server: alternate, in: app)
        app.buttons["settings-done"].tap()

        // Signing out removes the second server and returns to the first.
        openMenu(app)
        let signOut = app.buttons["sign-out"]
        signOut.tap()
        waitForHome(app, "Home screen of the first server missing after sign-out")
        assertSettingsShow(server: primary, in: app)
        app.buttons["settings-servers"].tap()
        XCTAssertTrue(serverRow(app, primary).waitForExistence(timeout: 5), "First server missing from the list")
        XCTAssertFalse(serverRow(app, alternate).exists, "Second server still saved after sign-out")
        snapshot(app, "12-after")
    }
}
