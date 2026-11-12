import XCTest

/// Home screen: notifications, search tab, space menus, Recently Updated and Favorites. `Tools/run-uitests.sh` seeds
/// two mentions first (test18 opens one, test31 swipes one away).
@MainActor final class HomeUITests: XCTestCase {
    private var slug: String { environment["DOCMOST_UITEST_SPACE_SLUG"] ?? "demo" }
    private var pageTitle: String { environment["DOCMOST_UITEST_PAGE_TITLE"] ?? "Editor-Test" }
    private let stamp = ProcessInfo.processInfo.environment["DOCMOST_STAMP"] ?? String(Int(Date().timeIntervalSince1970) % 100_000)

    override func setUpWithError() throws {
        try requireEnvironment()
    }

    // MARK: - Helpers

    /// Launches on the home screen; `gridLayout` (tiles) and `arguments` apply to this launch only (argument domain).
    private func launchHome(gridLayout: Bool = false, arguments: [String] = []) -> XCUIApplication {
        let app = launchApp(gridLayout: gridLayout, arguments: arguments)
        let space = app.buttons[gridLayout ? "space-tile-\(slug)" : "space-\(slug)"]
        XCTAssertTrue(space.waitForExistence(timeout: 30), "Home screen not loaded")
        return app
    }

    private func waitForPage(_ app: XCUIApplication, _ message: String) {
        let status = element(app, "page-status")
        XCTAssertTrue(status.waitForExistence(timeout: 30), message)
    }

    // MARK: - Tests

    /// The bell opens notifications as a popover; tapping an item closes it and opens the item's page.
    func test18_ActivityPopoverOpensPage() {
        let app = launchHome()
        let bell = app.buttons["home-activity"]
        XCTAssertTrue(bell.waitForExistence(timeout: 10), "Bell missing")
        bell.tap()
        let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'notification-'")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "No notification in the popover (Tools/seed-notifications.py)")
        snapshot(app, "18-popover")
        entry.tap()
        waitForPage(app, "Page from the notification doesn't open")
        XCTAssertFalse(entry.exists, "Popover still there after opening the page")
        snapshot(app, "18-page")
    }

    /// The magnifier opens the search field in the tab bar; the home screen shows above it until results replace it.
    /// A result opens its page, "Back" returns to the results.
    func test19_SearchTabShowsHomeThenResults() {
        let app = launchHome()
        let searchTab = button(app, labels: ["Search", "Suche"])
        XCTAssertTrue(searchTab.waitForExistence(timeout: 10), "Search button missing")
        searchTab.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Search field doesn't appear")
        XCTAssertTrue(app.buttons["space-\(slug)"].waitForExistence(timeout: 15), "Home screen missing from the Search tab")
        snapshot(app, "19-search-idle")
        field.typeText(pageTitle)
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-result-' AND label CONTAINS %@", pageTitle)).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20), "Result “\(pageTitle)” missing")
        let space = app.buttons["space-\(slug)"]
        if space.exists { XCTAssertFalse(space.isHittable, "Results don't replace the home screen") }
        snapshot(app, "19-search-results")
        result.tap()
        waitForPage(app, "Page from the result doesn't open")
        backButton(app).tap()
        XCTAssertTrue(result.waitForExistence(timeout: 10), "Results missing after “Back”")
    }

    /// Bell: swiping left marks a notification as read. With "Unread Only" (the default) it disappears and stays gone
    /// after a relaunch because the server stores it as read.
    func test31_ActivitySwipeMarksRead() {
        let unreadOnly = ["-notifications.unreadOnly", "YES"]
        var app = launchHome(arguments: unreadOnly)
        app.buttons["home-activity"].tap()
        let entries = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'notification-'"))
        XCTAssertTrue(entries.firstMatch.waitForExistence(timeout: 15), "No unread notification (Tools/seed-notifications.py --count 2)")
        let id = entries.firstMatch.identifier
        app.buttons[id].swipeLeft()
        let markRead = button(app, labels: ["Mark as Read", "Gelesen"])
        if markRead.waitForExistence(timeout: 2) { markRead.tap() }
        XCTAssertTrue(app.buttons[id].waitForNonExistence(timeout: 5), "Swiped notification stays in “Unread Only”")
        snapshot(app, "31-swiped")

        app.terminate()
        app = launchHome(arguments: unreadOnly)
        app.buttons["home-activity"].tap()
        // The popover has loaded once an item or the empty state shows.
        let empty = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["No unread notifications", "Keine ungelesenen Benachrichtigungen"])).firstMatch
        for _ in 0..<30 where !(entries.firstMatch.exists || empty.exists) { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertTrue(entries.firstMatch.exists || empty.exists, "Notifications don't load after relaunch")
        XCTAssertFalse(app.buttons[id].exists, "Notification is unread again after relaunch")
        snapshot(app, "31-reopened")
    }

    /// A long press on a space tile opens the same menu as "…" in the list view.
    func test20_SpaceTileContextMenu() {
        let app = launchHome(gridLayout: true)
        app.buttons["space-tile-\(slug)"].press(forDuration: 1.2)
        let copy = button(app, labels: ["Copy Link", "Link kopieren"])
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Long press on the tile shows no menu")
        snapshot(app, "20-tile-menu")
        copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5), "Menu doesn't close")
    }

    /// The list card also shows the menu on long press.
    func test21_SpaceCardContextMenu() {
        let app = launchHome()
        app.buttons["space-\(slug)"].press(forDuration: 1.2)
        let copy = button(app, labels: ["Copy Link", "Link kopieren"])
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Long press on the card shows no menu")
        snapshot(app, "21-card-menu")
        copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5), "Menu doesn't close")
    }

    /// Opens the page whose title begins with `title` from the list on the screen (Recently Updated, Favorites) and
    /// waits until its title field shows `title`.
    @discardableResult
    private func openPage(_ app: XCUIApplication, _ title: String, from list: String = "Recently Updated") -> XCUIElement {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "“\(title)” missing from \(list)")
        row.tap()
        let field = app.textFields["page-title"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "“\(title)” doesn't open")
        wait(for: [expectation(for: NSPredicate(format: "value == %@", title), evaluatedWith: field)], timeout: 15)
        return field
    }

    /// Puts `title` in place of the page's title, all of it: a double tap selects the title, a single word, and the
    /// typed text replaces it. Return (`save`) saves it; without, the field keeps its focus. A tap at the field's end
    /// and a fixed pause used to place the caret for appending; on November 12, 2026 test51's title came out unsaved
    /// that way, cause unknown.
    private func retitle(_ field: XCUIElement, to title: String, save: Bool) {
        field.tap()
        let focused = NSPredicate { _, _ in (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: nil)], timeout: 5), .completed,
                       "The title field takes no focus")
        field.doubleTap()
        field.typeText(title + (save ? "\n" : ""))
        XCTAssertEqual(field.value as? String, title, "The title field shows another title than the one typed")
    }

    // The rename tests below each have a page of their own under "Fixtures", which `Tools/run-uitests.sh` names back
    // every run: a test that fails halfway leaves only its own page renamed.

    /// Recently Updated reloads when shown again, like the web: a page renamed after opening it from the list shows
    /// its new title after "Back".
    func test51_RecentlyUpdatedShowsRename() {
        let app = launchHome()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'All'")).firstMatch.tap()
        let renamed = "Umbenennen51x\(stamp)"
        retitle(openPage(app, "Umbenennen51"), to: renamed, save: true)
        XCTAssertTrue(app.navigationBars[renamed].waitForExistence(timeout: 15), "Title “\(renamed)” wasn't saved")
        backButton(app).tap()
        let shown = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", renamed)).firstMatch.waitForExistence(timeout: 10)
        snapshot(app, "51-after-back")
        XCTAssertTrue(shown, "Recently Updated still shows the old title after “Back”")
    }

    /// "Back" while the title is still being edited saves it, like the web's save on navigation.
    func test47_BackSavesTitle() {
        let app = launchHome()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'All'")).firstMatch.tap()
        let renamed = "Umbenennen47x\(stamp)"
        // No Return: the field keeps its focus.
        retitle(openPage(app, "Umbenennen47"), to: renamed, save: false)
        backButton(app).tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Umbenennen47")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Recently Updated doesn't show after “Back”")
        row.tap()
        let saved = app.navigationBars[renamed].waitForExistence(timeout: 15)
        snapshot(app, "47-reopened")
        XCTAssertTrue(saved, "Title typed before “Back” wasn't saved")
    }

    /// Favorites reload when shown again, like Recently Updated (test51). Adds its page through the page menu, renames
    /// it, and removes the favorite again before asserting (the script removes it at each run's start too).
    func test48_FavoritesShowRename() {
        let app = launchHome()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'All'")).firstMatch.tap()
        let original = "Umbenennen48", renamed = "Umbenennen48x\(stamp)"
        func pageMenu(_ labels: [String]) {
            app.buttons["page-more"].tap()
            let item = button(app, labels: labels)
            XCTAssertTrue(item.waitForExistence(timeout: 5), "Page menu shows no “\(labels[0])”")
            item.tap()
        }
        openPage(app, original)
        pageMenu(["Add to Favorites", "Zu Favoriten hinzufügen"])
        backButton(app).tap()
        button(app, labels: ["Favorites", "Favoriten"]).tap()
        retitle(openPage(app, original, from: "Favorites"), to: renamed, save: true)
        XCTAssertTrue(app.navigationBars[renamed].waitForExistence(timeout: 15), "Title “\(renamed)” wasn't saved")
        backButton(app).tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", original)).firstMatch
        let shown = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", renamed)).firstMatch.waitForExistence(timeout: 10)
        snapshot(app, "48-after-back")
        openPage(app, renamed, from: "Favorites")
        pageMenu(["Remove from Favorites", "Aus Favoriten entfernen"])
        backButton(app).tap()
        // Also waits for the removal to reach the server before the app ends.
        let removed = row.waitForNonExistence(timeout: 10)
        XCTAssertTrue(shown, "Favorites still show the old title after “Back”")
        XCTAssertTrue(removed, "“\(renamed)” is still a favorite")
    }

    /// The trash confirmation shows at the tree row's "…" and at the long-pressed row in "Recent", not at a fixed spot
    /// at the top (regression). Closed without choosing, so nothing is deleted.
    func test50_TrashConfirmationAtRow() {
        let app = launchHome()
        app.buttons["space-\(slug)"].tap()
        let menus = app.buttons.matching(NSPredicate(format: "label IN %@", ["More", "Mehr"]))
        XCTAssertTrue(menus.firstMatch.waitForExistence(timeout: 20), "Page tree missing")
        guard let menu = menus.allElementsBoundByIndex.first(where: \.isHittable) else { return XCTFail("No “…” in the page tree") }
        let menuFrame = menu.frame
        menu.tap()
        let trash = button(app, labels: ["Move to Trash", "In den Papierkorb"])
        XCTAssertTrue(trash.waitForExistence(timeout: 5), "“Move to Trash” missing from the row menu")
        trash.tap()
        assertPopover(app, at: menuFrame)
        snapshot(app, "50-tree")
        dismissPopover(app)

        button(app, labels: ["Recent", "Zuletzt"]).tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", pageTitle)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "“\(pageTitle)” missing from Recent")
        let rowFrame = row.frame
        row.press(forDuration: 1.2)
        XCTAssertTrue(trash.waitForExistence(timeout: 5), "Long press on the row shows no “Move to Trash”")
        trash.tap()
        assertPopover(app, at: rowFrame)
        snapshot(app, "50-recent")
        dismissPopover(app)
    }

    /// Settings › Licenses lists the app's license and those of the bundled libraries, each with its text.
    func test59_Licenses() {
        let app = launchHome()
        let menu = app.buttons["workspace-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20), "Workspace menu missing")
        let settings = button(app, labels: ["Settings", "Einstellungen"])
        for _ in 0..<3 where !settings.exists {
            menu.tap()
            _ = settings.waitForExistence(timeout: 3)
        }
        settings.tap()
        let licenses = app.buttons["settings-licenses"]
        for _ in 0..<3 where !licenses.isHittable {
            app.swipeUp()
        }
        licenses.tap()
        XCTAssertTrue(app.staticTexts["Diderot"].waitForExistence(timeout: 10), "The app's own license missing")
        let tiptap = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "@tiptap/core")).firstMatch
        XCTAssertTrue(tiptap.waitForExistence(timeout: 5), "TipTap missing from the licenses")
        snapshot(app, "59-licenses")
        tiptap.tap()
        let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Permission is hereby granted")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5), "TipTap's license text missing")
    }
}
