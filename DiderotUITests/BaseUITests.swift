import XCTest

/// Databases (bases): database pages (table, board), embedded databases (cards), editing, creating, moving and deleting
/// rows. `Tools/run-uitests.sh` seeds data via `Tools/seed-bases.py`, then verifies the written values on the server.
@MainActor final class BaseUITests: XCTestCase {
    override func setUpWithError() throws {
        try requireEnvironment(["DOCMOST_UITEST_BASE", "DOCMOST_UITEST_BASE_HOST", "DOCMOST_UITEST_BASE_FULL"])
    }

    private func launch(page: String? = nil, arguments: [String] = []) -> XCUIApplication {
        launchApp(extraEnvironment: page.map { ["DOCMOST_DEBUG_PAGE": $0] } ?? [:], arguments: arguments)
    }

    private func closeDetailIfOpen(_ app: XCUIApplication) {
        guard element(app, "base-row-detail").exists else { return }
        tapSheetBarButton(element(app, "base-detail-done"), in: element(app, "base-row-detail"))
        XCTAssertTrue(element(app, "base-row-detail").waitForNonExistence(timeout: 8), "Detail sheet doesn't close")
    }

    private let stamp = ProcessInfo.processInfo.environment["DOCMOST_STAMP"] ?? String(Int(Date().timeIntervalSince1970) % 100_000)

    /// Property and status option IDs of the database "Datenbank-Test" (from `Tools/seed-bases.py`).
    private var ids: [String: String] {
        guard let data = environment["DOCMOST_UITEST_BASE_IDS"]?.data(using: .utf8),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return map
    }

    private func waitForLabel(_ element: XCUIElement, contains text: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Drags the detail sheet's content up until the element is hittable.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        // Drag slowly, don't swipe: momentum overshoots fields just below the edge (iPhone 16 Pro Max: to the list's
        // end). 300 points also reliably expand a half-height sheet fully.
        for _ in 0..<10 where !(element.exists && element.isHittable) {
            dragDetail(app, by: 300)
        }
    }

    /// Drags the detail sheet's content up by `points` without momentum, from the left edge beside the fields so no
    /// switch or text field gets the touch.
    private func dragDetail(_ app: XCUIApplication, by points: CGFloat) {
        let start = element(app, "base-row-detail").coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.85))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -points)), withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    /// Whether the element lies left of or above the visible area (scrolled away); `isHittable` is unreliable for that.
    private func isScrolledAway(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists else { return true }
        let frame = element.frame
        // Off screen the LazyVStack no longer lays out the header: frame (∞, ∞, 0, 0).
        if frame.isNull || frame.isEmpty { return true }
        return frame.maxX <= 1 || frame.maxY <= app.navigationBars.firstMatch.frame.maxY + 1
    }

    private func button(_ app: XCUIApplication, labelContains text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Waits for the view tab with this name and taps it (not by text alone: cells can contain the same text).
    @discardableResult
    private func openView(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let tab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'base-view-' AND label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "Tab “\(name)” missing")
        tab.tap()
        return tab
    }

    /// Database "Kanban-Test": kanban view with at least one card, no editor engine.
    private func assertBaseScreen(_ app: XCUIApplication, _ message: String) {
        XCTAssertTrue(element(app, "base-screen").waitForExistence(timeout: 30), message)
        XCTAssertTrue(element(app, "base-kanban").waitForExistence(timeout: 15), "Kanban view missing")
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'base-card-'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "No card in the kanban view")
        // No document, no engine: the page view's status pill is absent.
        XCTAssertFalse(element(app, "page-status").exists, "Database page starts the editor engine")
    }

    /// Database page from the page tree: overview, no editable document, no "Append Note" in the menu.
    func test22_BasePageFromTree() {
        let app = launch()
        let slug = environment["DOCMOST_UITEST_SPACE_SLUG"] ?? "demo"
        let space = app.buttons["space-\(slug)"]
        XCTAssertTrue(space.waitForExistence(timeout: 30), "Space “\(slug)” missing from the home screen")
        space.tap()
        let row = app.buttons["page-\(environment["DOCMOST_UITEST_BASE"]!)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Database missing from the page tree")
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        row.tap()
        assertBaseScreen(app, "Database page shows no overview")
        snapshot(app, "22-base-page")
        app.buttons["page-more"].tap()
        let favorite = button(app, labels: ["Add to Favorites", "Remove from Favorites", "Zu Favoriten hinzufügen", "Aus Favoriten entfernen"])
        XCTAssertTrue(favorite.waitForExistence(timeout: 5), "Page menu did not open")
        let appendNote = button(app, labels: ["Append Note", "Notiz anhängen"])
        XCTAssertFalse(appendNote.exists, "Menu offers “Append Note” for a database")
        snapshot(app, "22-base-menu")
    }

    /// Embedded database: card with title; a tap opens the database page.
    func test23_BaseEmbedOpensBase() {
        let app = launch(page: environment["DOCMOST_UITEST_BASE_HOST"])
        let card = app.buttons["base-embed-\(environment["DOCMOST_UITEST_BASE"]!)"]
        XCTAssertTrue(card.waitForExistence(timeout: 40), "Embedded database card missing")
        let titled = expectation(for: NSPredicate(format: "label CONTAINS %@", "Kanban-Test"), evaluatedWith: card)
        wait(for: [titled], timeout: 15)
        snapshot(app, "23-embed-card")
        card.tap()
        assertBaseScreen(app, "Card doesn't open the database")
        snapshot(app, "23-base-page")
    }

    /// Table (all property types) scrolls freely: title column sideways, page header up and away (also in landscape),
    /// column headers stay pinned. A row opens its detail sheet with the computed formula.
    func test24_BaseTableAndRowDetail() {
        let app = launch(page: environment["DOCMOST_UITEST_BASE_FULL"])
        openView(app, "Tabelle")
        let table = element(app, "base-table")
        XCTAssertTrue(table.waitForExistence(timeout: 15), "Table view missing")
        let row = button(app, labelContains: "Aufgabe 05")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Row “Aufgabe 05” missing")
        snapshot(app, "24-table")
        let title05 = app.staticTexts["Aufgabe 05"]
        Thread.sleep(forTimeInterval: 1.0)
        // On the two-way scrolling table a swipe can land as a tap (opens a detail sheet): close it and swipe again.
        for _ in 0..<4 where !isScrolledAway(title05, in: app) {
            closeDetailIfOpen(app)
            table.swipeLeft()
        }
        snapshot(app, "24-table-scrolled")
        XCTAssertTrue(isScrolledAway(title05, in: app), "Title column doesn't scroll sideways")
        for _ in 0..<4 where isScrolledAway(title05, in: app) {
            closeDetailIfOpen(app)
            table.swipeRight()
        }
        let pageTitle = app.textFields["page-title"]
        XCTAssertTrue(pageTitle.isHittable, "Page header missing above the table")
        for _ in 0..<3 where !isScrolledAway(pageTitle, in: app) {
            closeDetailIfOpen(app)
            table.swipeUp()
        }
        snapshot(app, "24-table-down")
        XCTAssertTrue(isScrolledAway(pageTitle, in: app), "Page header doesn't scroll away with the table")
        XCTAssertTrue(app.staticTexts["Status"].isHittable, "Column headers don't stay pinned when scrolling down")
        table.swipeDown()
        table.swipeDown()

        // Landscape: the header scrolls away here too.
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1.5)
        for _ in 0..<3 where !isScrolledAway(pageTitle, in: app) {
            closeDetailIfOpen(app)
            table.swipeUp()
        }
        snapshot(app, "24-landscape-down")
        XCTAssertTrue(isScrolledAway(pageTitle, in: app), "Page header stays put in landscape")
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 1.5)
        table.swipeDown()
        table.swipeDown()
        // Long press: "Delete Entry" asks at the pressed row; closed without choosing, so nothing is deleted.
        let rowFrame = row.frame
        row.press(forDuration: 1.2)
        let delete = button(app, labels: ["Delete Entry", "Eintrag löschen"])
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "Long press on the row shows no “Delete Entry”")
        delete.tap()
        assertPopover(app, at: rowFrame)
        dismissPopover(app)
        row.tap()
        XCTAssertTrue(element(app, "base-row-detail").waitForExistence(timeout: 10), "Detail sheet doesn't open")
        snapshot(app, "24-detail")
        // Aufwand (effort) 3.5 → formula "Doppelt" = 7, computed by the server; the field sits further down the sheet.
        let formula = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Doppelt' AND label CONTAINS '7'")).firstMatch
        for _ in 0..<5 where !formula.exists { app.swipeUp() }
        XCTAssertTrue(formula.waitForExistence(timeout: 5), "Formula value missing from the detail sheet")
        snapshot(app, "24-detail-scrolled")
        // The arrows step through the view's entries, as in the web's entry header.
        let title = element(app, "base-row-title")
        for (arrow, expected) in [("base-detail-next", "Aufgabe 06"), ("base-detail-previous", "Aufgabe 05")] {
            element(app, arrow).tap()
            let shown = expectation(for: NSPredicate(format: "value == %@", expected), evaluatedWith: title)
            XCTAssertEqual(XCTWaiter().wait(for: [shown], timeout: 8), .completed, "\(arrow) doesn't show \(expected)")
        }
        snapshot(app, "24-detail-arrows")
    }

    /// A link field opens in the in-app browser over the entry, as a link on a page does ("Aufgabe 06" has one,
    /// Tools/seed-bases.py).
    func test65_LinkFieldOpensInTheApp() {
        let app = launch(page: environment["DOCMOST_UITEST_BASE_FULL"])
        openView(app, "Tabelle")
        let row = button(app, labelContains: "Aufgabe 06")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Row “Aufgabe 06” missing")
        row.tap()
        let detail = element(app, "base-row-detail")
        XCTAssertTrue(detail.waitForExistence(timeout: 10), "Detail sheet doesn't open")
        let openLink = app.links.matching(NSPredicate(format: "label IN %@", ["Open Link", "Link öffnen"])).firstMatch
        for _ in 0..<5 where !openLink.isHittable { app.swipeUp() }
        openLink.tap()
        let close = browserCloseButton(app)
        XCTAssertTrue(close.waitForExistence(timeout: 10), "The link field doesn't open the in-app browser")
        snapshot(app, "65-link-field")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5), "The in-app browser doesn't close")
        XCTAssertTrue(detail.exists, "The entry closes with the browser")
    }

    /// A web link to an entry (`?row=…&rowBase=…`) opens its database and the entry, also one the view doesn't show:
    /// "Aufgabe 27" is done, and the board hides "Erledigt".
    func test57_EntryLinkOpensTheEntry() throws {
        let base = try XCTUnwrap(environment["DOCMOST_UITEST_BASE_FULL"])
        let row = try XCTUnwrap(ids["row:Aufgabe 27"], "Row id missing (Tools/seed-bases.py)")
        let server = environment["DOCMOST_DEBUG_SERVER"] ?? "http://localhost:3000"
        let app = launch(page: base)
        openView(app, "Board")
        let web = "\(server)/p/\(base)?row=\(row)&rowBase=\(base)"
        app.open(try XCTUnwrap(URL(string: "diderot://open?url=" + (web.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))))
        // iOS may ask whether to open the link in the app.
        let confirm = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons
            .matching(NSPredicate(format: "label IN %@", ["Open", "Öffnen"])).firstMatch
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }
        XCTAssertTrue(element(app, "base-row-detail").waitForExistence(timeout: 20), "The linked entry doesn't open")
        let shown = expectation(for: NSPredicate(format: "value == %@", "Aufgabe 27"), evaluatedWith: element(app, "base-row-title"))
        XCTAssertEqual(XCTWaiter().wait(for: [shown], timeout: 8), .completed, "Another entry opened")
        snapshot(app, "57-entry-link")
    }

    /// Kanban board: columns per status including "No value", sideways swiping, a card opens its detail sheet.
    func test25_BaseKanbanColumnsAndCard() {
        let app = launch(page: environment["DOCMOST_UITEST_BASE_FULL"])
        let boardTab = openView(app, "Board")
        let board = element(app, "base-kanban")
        XCTAssertTrue(board.waitForExistence(timeout: 15), "Kanban view missing")
        XCTAssertTrue(app.staticTexts["Offen"].waitForExistence(timeout: 15), "Column “Offen” missing")
        snapshot(app, "25-kanban")
        let noValue = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["No value", "Ohne Wert"])).firstMatch
        for _ in 0..<4 where !(noValue.exists && noValue.isHittable) { board.swipeLeft() }
        XCTAssertTrue(noValue.isHittable, "Column “No value” missing")
        snapshot(app, "25-kanban-end")
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'base-card-'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), "No card in the column")

        // Landscape: the page header goes away and only the tabs remain, leaving more height for the columns.
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(app.textFields["page-title"].exists, "Page header takes up space in landscape")
        XCTAssertTrue(boardTab.exists, "Tabs missing in landscape")
        snapshot(app, "25-landscape")
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 1.5)
        card.tap()
        XCTAssertTrue(element(app, "base-row-detail").waitForExistence(timeout: 10), "Detail sheet doesn't open")
        snapshot(app, "25-detail")
    }

    /// Table: "+" creates a row whose detail sheet opens with the cursor in the title. Edits title, status, a new tag
    /// option, a number (the server recomputes the formula), checkbox, person and a link without scheme. Then a tap on
    /// the status cell opens the sheet scrolled to that field. Tools/run-uitests.sh verifies the values.
    func test26_BaseCreateAndEditEntry() throws {
        let ids = self.ids
        guard let titleId = ids["Title"], let statusId = ids["Status"], let tagsId = ids["Tags"], let effortId = ids["Aufwand"],
              let doneId = ids["Erledigt"], let personId = ids["Verantwortlich"], let linkId = ids["Link"]
        else { throw XCTSkip("DOCMOST_UITEST_BASE_IDS missing") }
        let title = "UITest-Eintrag\(stamp)"
        let app = launch(page: environment["DOCMOST_UITEST_BASE_FULL"])
        openView(app, "Tabelle")
        XCTAssertTrue(element(app, "base-table").waitForExistence(timeout: 15), "Table view missing")
        let add = element(app, "base-new-entry")
        XCTAssertTrue(add.waitForExistence(timeout: 10), "“+” for new entries missing")
        add.tap()

        // Title: the cursor is already in it; Return commits.
        let titleField = element(app, "base-row-title")
        XCTAssertTrue(titleField.waitForExistence(timeout: 10), "New entry's detail sheet doesn't open")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Title doesn't get the cursor for a new entry")
        titleField.typeText(title + "\n")
        snapshot(app, "26-title")

        // Status via the picker list; choosing a value returns to the detail sheet.
        let status = element(app, "base-field-\(statusId)")
        status.tap()
        let inProgress = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'base-choice-' AND label == 'In Arbeit'")).firstMatch
        XCTAssertTrue(inProgress.waitForExistence(timeout: 5), "Status list doesn't open")
        snapshot(app, "26-status-picker")
        inProgress.tap()
        XCTAssertTrue(waitForLabel(status, contains: "In Arbeit"), "Status doesn't show the selected value")
        // Back in the sheet the title must not grab the cursor again (regression: focus re-ran on every reappearance).
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 2), "Title grabs the cursor again after the picker list")

        // Create a new tag option; it is selected afterwards.
        element(app, "base-field-\(tagsId)").tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Tag list without a search field")
        search.tap()
        search.typeText("UITest-Option\(stamp)")
        let addOption = element(app, "base-add-option")
        XCTAssertTrue(addOption.waitForExistence(timeout: 5), "“Add Option” missing")
        addOption.tap()
        let option = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'base-choice-' AND label CONTAINS %@", "UITest-Option\(stamp)")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 10), "New option doesn't appear")
        XCTAssertTrue(option.isSelected, "New option isn't selected")
        snapshot(app, "26-tags")
        backButton(app).tap()
        XCTAssertTrue(waitForLabel(element(app, "base-field-\(tagsId)"), contains: "UITest-Option\(stamp)"), "Tag missing from the detail sheet")

        // Number: Aufwand (effort) 4.5; the server computes formula "Doppelt" as 9, checked below.
        let effort = app.textFields["base-input-\(effortId)"]
        reveal(effort, in: app)
        effort.tap()
        effort.typeText("4,5")
        element(app, "base-keyboard-done").tap()

        // Checkbox and person (they sit between Aufwand and the formula).
        let done = app.switches["base-field-\(doneId)"]
        reveal(done, in: app)
        let knob = done.switches.firstMatch
        (knob.exists ? knob : done).tap()
        XCTAssertTrue(waitForValue(done, "1"), "Checkbox can't be checked")
        let person = element(app, "base-field-\(personId)")
        reveal(person, in: app)
        person.tap()
        let colleague = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'base-person-' AND label CONTAINS 'Test-Kollegin'")).firstMatch
        XCTAssertTrue(colleague.waitForExistence(timeout: 10), "Person list without Test-Kollegin")
        colleague.tap()
        XCTAssertTrue(waitForLabel(person, contains: "Test-Kollegin"), "Person doesn't show the selection")
        // Link without scheme gets https:// (the server rejects "docmost.com"); run-uitests.sh checks the stored value.
        let link = app.textFields["base-input-\(linkId)"]
        reveal(link, in: app)
        link.tap()
        link.typeText("docmost.com/uitest-\(stamp)")
        element(app, "base-keyboard-done").tap()
        XCTAssertTrue(waitForValue(link, "https://docmost.com/uitest-\(stamp)"), "Link without a scheme doesn't get https://")
        let formula = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Doppelt' AND label CONTAINS '9'")).firstMatch
        reveal(formula, in: app)
        XCTAssertTrue(formula.waitForExistence(timeout: 10), "Formula isn't recomputed after entering the number")
        snapshot(app, "26-detail-edited")

        // Close: the row shows in the table. A tap on its status cell jumps to the status field.
        tapSheetBarButton(element(app, "base-detail-done"), in: element(app, "base-row-detail"))
        let titleCell = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "base-cell-\(titleId)", title)).firstMatch
        XCTAssertTrue(titleCell.waitForExistence(timeout: 10), "New entry missing from the table")
        snapshot(app, "26-table")
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'base-row-'"))
            .containing(NSPredicate(format: "label == %@", title)).firstMatch
        row.buttons["base-cell-\(statusId)"].tap()
        XCTAssertTrue(element(app, "base-row-detail").waitForExistence(timeout: 10), "Detail sheet doesn't open")
        Thread.sleep(forTimeInterval: 1.2)
        snapshot(app, "26-jump")
        // After the jump, status is at the top and the title scrolled away above it. Not via isHittable:
        // scrolled-away list cells count as hittable while inside the window.
        let bar = app.navigationBars[title].frame
        XCTAssertLessThan(status.frame.minY - bar.maxY, 60, "Detail sheet doesn't jump to the tapped field")
        // Gone from the tree counts too: on short displays (iPhone Duo) the list drops it.
        XCTAssertTrue(!titleField.exists || titleField.frame.maxY <= bar.maxY + 1, "Title still in view")
        // Scroll a bit further, open a picker list and go back: the sheet stays put and doesn't jump to status again.
        let tags = element(app, "base-field-\(tagsId)")
        let statusTop = status.frame.minY
        dragDetail(app, by: 120)
        XCTAssertTrue(!status.exists || statusTop - status.frame.minY > 60, "Dragging doesn't scroll the detail sheet")
        let before = tags.frame.minY
        tags.tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5), "Tag list doesn't open")
        backButton(app).tap()
        XCTAssertTrue(tags.waitForExistence(timeout: 5), "Detail sheet missing after the tag list")
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertLessThan(abs(tags.frame.minY - before), 40, "Detail sheet jumps back to status after the picker list")
        closeDetailIfOpen(app)
    }

    /// Board: "+" in the column header adds a card at the top; in the context menu (long press) "Move to" moves it to
    /// the end of "In Arbeit" and "Delete Entry" removes it.
    func test27_BaseKanbanCreateMoveDelete() throws {
        let ids = self.ids
        guard let open = ids["status:Offen"], let inProgress = ids["status:In Arbeit"] else {
            throw XCTSkip("DOCMOST_UITEST_BASE_IDS missing")
        }
        // Card drag off (`-base.cardDrag NO`): otherwise iOS keeps the drag armed while the menu is open and XCUITest
        // waits a minute per step for animations to finish. Check the interplay on a device.
        let app = launch(page: environment["DOCMOST_UITEST_BASE_FULL"], arguments: ["-base.cardDrag", "NO"])
        let (openColumn, cardId) = createCard(app, title: "UITest-Karte\(stamp)", in: open)
        snapshot(app, "27-created")

        // Menu: "Move to" → "In Arbeit".
        element(app, cardId).press(forDuration: 1.2)
        let move = button(app, labels: ["Move to", "Verschieben nach"])
        XCTAssertTrue(move.waitForExistence(timeout: 5), "Menu without “Move to”")
        snapshot(app, "27-menu")
        move.tap()
        let target = app.buttons.matching(NSPredicate(format: "label == 'In Arbeit'")).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5), "Column “In Arbeit” missing from the menu")
        target.tap()
        XCTAssertTrue(openColumn.buttons[cardId].waitForNonExistence(timeout: 10), "Card still in “Offen”")
        let moved = findCard(app, cardId, inColumn: inProgress)
        XCTAssertTrue(moved.exists, "Card didn't arrive in “In Arbeit”")
        snapshot(app, "27-moved")

        // Delete via the menu; the confirmation shows at the card.
        let movedFrame = moved.frame
        moved.press(forDuration: 1.2)
        let delete = button(app, labels: ["Delete Entry", "Eintrag löschen"])
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "Menu without “Delete Entry”")
        delete.tap()
        assertPopover(app, at: movedFrame)
        confirmDelete(app)
        XCTAssertTrue(element(app, cardId).waitForNonExistence(timeout: 10), "Card still there after deletion")
        snapshot(app, "27-deleted")
    }

    /// Board: drag below the second card in the column, then onto the next column (end of "In Arbeit"); delete in the
    /// detail sheet. Card menu off (`-base.cardMenu NO`): XCUITest doesn't do the menu-to-drag transition. On a device,
    /// holding shows the menu and moving drags the card.
    func test28_BaseKanbanDragAndDeleteInDetail() throws {
        let ids = self.ids
        guard let open = ids["status:Offen"], let inProgress = ids["status:In Arbeit"] else {
            throw XCTSkip("DOCMOST_UITEST_BASE_IDS missing")
        }
        let app = launch(page: environment["DOCMOST_UITEST_BASE_FULL"], arguments: ["-base.cardMenu", "NO"])
        let (openColumn, cardId) = createCard(app, title: "UITest-Zieh\(stamp)", in: open)
        let cards = openColumn.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'base-card-'"))

        // Within the column: below the second card.
        let second = cards.element(boundBy: 1)
        XCTAssertTrue(second.exists, "Column “Offen” has too few cards")
        element(app, cardId).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.8, thenDragTo: second.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)),
            withVelocity: .slow, thenHoldForDuration: 0.4
        )
        let reordered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "identifier == %@", cardId), object: cards.element(boundBy: 1))
        XCTAssertEqual(XCTWaiter.wait(for: [reordered], timeout: 10), .completed, "Dragging doesn't reorder the card")
        snapshot(app, "28-reordered")

        // Onto the next column (peeking in at the right edge): end of "In Arbeit".
        let progressColumn = element(app, "base-column-\(inProgress)")
        XCTAssertTrue(progressColumn.exists, "Column “In Arbeit” missing")
        element(app, cardId).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.8, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.6)),
            withVelocity: .fast, thenHoldForDuration: 0.2
        )
        XCTAssertTrue(openColumn.buttons[cardId].waitForNonExistence(timeout: 10), "Card still in “Offen” after dragging")
        let moved = findCard(app, cardId, inColumn: inProgress)
        XCTAssertTrue(moved.exists, "Card not in “In Arbeit” after dragging")
        snapshot(app, "28-moved")

        // Delete in the detail sheet via "…".
        moved.tap()
        XCTAssertTrue(element(app, "base-row-detail").waitForExistence(timeout: 10), "Detail sheet doesn't open")
        let menuFrame = element(app, "base-row-menu").frame
        element(app, "base-row-menu").tap()
        let delete = button(app, labels: ["Delete Entry", "Eintrag löschen"])
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "Detail sheet menu without “Delete Entry”")
        delete.tap()
        assertPopover(app, at: menuFrame)
        confirmDelete(app)
        XCTAssertTrue(element(app, "base-row-detail").waitForNonExistence(timeout: 10), "Detail sheet stays open after deletion")
        XCTAssertTrue(element(app, cardId).waitForNonExistence(timeout: 10), "Card still there after deletion")
    }

    /// Kanban as first view of a database under another page (breadcrumbs above the title), as the web's kanban
    /// template makes it: the title keeps its full height in the tight space above the board (regression: breadcrumbs
    /// squeezed it until only the lower half of the letters showed).
    func test29_BaseKanbanHeaderKeepsTitle() throws {
        guard let pageId = environment["DOCMOST_UITEST_BASE_NESTED"] else { throw XCTSkip("DOCMOST_UITEST_BASE_NESTED missing") }
        let app = launch(page: pageId)
        XCTAssertTrue(element(app, "base-kanban").waitForExistence(timeout: 30), "Kanban view missing")
        let title = element(app, "page-title")
        XCTAssertTrue(title.waitForExistence(timeout: 10), "Title missing")
        snapshot(app, "29-kanban-header")
        // One line of the large title is just over 40 points tall; squeezed, about 10.
        XCTAssertGreaterThan(title.frame.height, 34, "Title above the kanban board is squeezed")
    }

    /// Column snapping: first flush left, after a swipe the next centered (both neighbors peek in), last flush right.
    func test30_BaseKanbanColumnsSnap() throws {
        guard let pageId = environment["DOCMOST_UITEST_BASE_NESTED"] else { throw XCTSkip("DOCMOST_UITEST_BASE_NESTED missing") }
        let app = launch(page: pageId)
        let board = element(app, "base-kanban")
        XCTAssertTrue(board.waitForExistence(timeout: 30), "Kanban view missing")
        let columns = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'base-column-[^-]+'"))
        XCTAssertTrue(columns.firstMatch.waitForExistence(timeout: 15), "No column on the board")
        let edge: CGFloat = 16
        let first = visibleColumns(columns, in: board)
        XCTAssertEqual(first.first?.minX ?? 0, board.frame.minX + edge, accuracy: 2, "First column isn't flush left")
        snapshot(app, "30-first")

        board.swipeLeft()
        Thread.sleep(forTimeInterval: 1.0)
        let middle = visibleColumns(columns, in: board)
        XCTAssertEqual(middle.count, 3, "Middle column's neighbors don't both peek in")
        if middle.count == 3 {
            XCTAssertEqual(middle[1].midX, board.frame.midX, accuracy: 2, "Middle column isn't centered")
            XCTAssertLessThan(middle[0].minX, board.frame.minX, "Left neighbor fully visible instead of peeking in")
            XCTAssertGreaterThan(middle[2].maxX, board.frame.maxX, "Right neighbor fully visible instead of peeking in")
        }
        snapshot(app, "30-middle")

        for _ in 0..<6 { board.swipeLeft() }
        Thread.sleep(forTimeInterval: 1.0)
        let last = visibleColumns(columns, in: board)
        XCTAssertEqual(last.last?.maxX ?? 0, board.frame.maxX - edge, accuracy: 2, "Last column isn't flush right")
        snapshot(app, "30-last")
    }

    /// Frames of the columns at least partly visible in the board, left to right.
    private func visibleColumns(_ columns: XCUIElementQuery, in board: XCUIElement) -> [CGRect] {
        columns.allElementsBoundByIndex.map { $0.frame }
            .filter { !$0.isEmpty && $0.maxX > board.frame.minX && $0.minX < board.frame.maxX }
            .sorted { $0.minX < $1.minX }
    }

    /// Opens the board and creates a titled card via "+" in the column header (it lands at the top).
    private func createCard(_ app: XCUIApplication, title: String, in columnId: String) -> (XCUIElement, String) {
        openView(app, "Board")
        let column = element(app, "base-column-\(columnId)")
        XCTAssertTrue(column.waitForExistence(timeout: 15), "Column missing")
        element(app, "base-column-new-\(columnId)").tap()
        let titleField = element(app, "base-row-title")
        XCTAssertTrue(titleField.waitForExistence(timeout: 10), "New card's detail sheet doesn't open")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Title doesn't get the cursor for a new card")
        titleField.typeText(title + "\n")
        closeDetailIfOpen(app)
        let card = column.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'base-card-' AND label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "New card missing from the column")
        let first = column.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'base-card-'")).element(boundBy: 0)
        XCTAssertEqual(first.identifier, card.identifier, "New card isn't at the top of the column")
        return (column, card.identifier)
    }

    /// Finds a card in another column: pages the board, then scrolls the column down (cards load only once in view).
    private func findCard(_ app: XCUIApplication, _ cardId: String, inColumn columnId: String) -> XCUIElement {
        let column = element(app, "base-column-\(columnId)")
        let card = column.buttons[cardId]
        let board = element(app, "base-kanban")
        // Page until the column is fully visible (middle columns snap to the center).
        for _ in 0..<4 where !(column.exists && column.frame.minX >= board.frame.minX - 1 && column.frame.maxX <= board.frame.maxX + 1) {
            board.swipeLeft()
            Thread.sleep(forTimeInterval: 0.8)
        }
        for _ in 0..<8 where !(card.exists && card.isHittable) {
            column.swipeUp()
        }
        return card
    }

    private func confirmDelete(_ app: XCUIApplication) {
        // The menu item has the same label as the dialog's button: wait for the dialog's title first.
        let title = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["Delete entry?", "Eintrag löschen?"])).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Delete confirmation missing")
        let confirm = button(app, labels: ["Delete Entry", "Eintrag löschen"])
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Delete confirmation missing")
        confirm.tap()
    }

    private func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
