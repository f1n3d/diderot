import XCTest

/// Tap tests for in-place editing in the page view against the dev instance (`Tools/run-uitests.sh`). Tests type
/// stamped text (`DOCMOST_STAMP`); the script resets the page first, then checks via the API what reached the server.
@MainActor final class EditorUITests: XCTestCase {
    private let stamp = ProcessInfo.processInfo.environment["DOCMOST_STAMP"] ?? String(Int(Date().timeIntervalSince1970) % 100_000)

    override func setUpWithError() throws {
        try requireEnvironment(["DOCMOST_DEBUG_PAGE"])
    }

    // MARK: - Helpers

    private func launch(openPage: Bool, arguments: [String] = []) -> XCUIApplication {
        let keys = openPage ? ["DOCMOST_DEBUG_PAGE", "DOCMOST_DEBUG_SPACE"] : []
        return launchApp(extraEnvironment: environment.filter { keys.contains($0.key) }, arguments: arguments)
    }

    /// Opens the test page and waits for the engine sync ("Saved").
    private func launchPage(arguments: [String] = []) -> XCUIApplication {
        let app = launch(openPage: true, arguments: arguments)
        waitForSync(app)
        return app
    }

    /// Opens a fixture page (Tools/seed-fixtures.py) through the space's search.
    private func openFixture(_ title: String) -> XCUIApplication {
        let app = launch(openPage: false)
        let slug = environment["DOCMOST_UITEST_SPACE_SLUG"] ?? "demo"
        let space = app.buttons["space-\(slug)"]
        XCTAssertTrue(space.waitForExistence(timeout: 30), "Space card “\(slug)” not on the home screen")
        space.tap()
        let search = app.textFields["space-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 20), "Search field in the space not found")
        search.tap()
        search.typeText(title)
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-result-' AND label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20), "“\(title)” missing (Tools/seed-fixtures.py)")
        result.tap()
        waitForSync(app)
        return app
    }

    private func waitForSync(_ app: XCUIApplication) {
        let pill = element(app, "page-status")
        XCTAssertTrue(pill.waitForExistence(timeout: 40), "Page didn't load")
        let synced = expectation(for: NSPredicate(format: "label IN %@", ["Saved", "Gespeichert"]), evaluatedWith: pill)
        // The dev server sometimes answers after 25 s and more: right after the script reset the page, or when the test
        // before left changes (its collab server stores and unloads the page with a delay first).
        wait(for: [synced], timeout: 60)
    }

    /// Taps a text block at the right end of its last line, which puts the caret at the end, and waits for the editor.
    private func edit(_ app: XCUIApplication, blockContaining text: String) -> XCUIElement {
        let block = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
        let end = CGVector(dx: 1, dy: 0.85)
        XCTAssertTrue(scrollTo(block, in: app, anchor: end), "Block “\(text)” not found")
        block.coordinate(withNormalizedOffset: end).withOffset(CGVector(dx: -2, dy: 0)).tap()
        // A tap while the keyboard folds in or out (`waitForKeyboard`) can miss the block.
        if !app.textViews["active-editor"].firstMatch.waitForExistence(timeout: 3) {
            block.coordinate(withNormalizedOffset: end).withOffset(CGVector(dx: -2, dy: 0)).tap()
        }
        return activeEditor(app, "Editor doesn't appear after tapping “\(text)”")
    }

    private func finishEditing(_ app: XCUIApplication) {
        let editor = app.textViews["active-editor"]
        app.buttons["editor-done"].tap()
        // After hardware key events iOS brings the on-screen keyboard back and the toolbar moves up with it; a tap
        // during that move misses "Done".
        if !editor.waitForNonExistence(timeout: 3) { app.buttons["editor-done"].tap() }
        XCTAssertTrue(editor.waitForNonExistence(timeout: 8), "Editor didn't close")
    }

    /// Waits until the on-screen keyboard is on the screen, or gone. After keys that XCUITest types, iOS can fold it below
    /// the screen and bring it back a moment later: the simulator's keyboard daemon turns on automatic minimization once
    /// it sees a hardware keyboard attach while the keyboard is up (the Simulator app connects the Mac's; XCUITest's typing
    /// counts too). Meanwhile its keys can't be tapped, and the page's free area isn't what it will be.
    private func waitForKeyboard(_ app: XCUIApplication, timeout: TimeInterval = 4) {
        let keyboard = app.keyboards.firstMatch
        let bottom = app.windows.firstMatch.frame.maxY
        let settled = NSPredicate { _, _ in !keyboard.exists || keyboard.frame.minY < bottom }
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: timeout)
    }

    /// Scrolls until the point at `anchor` (unit coordinates of the element) lies in the page's free area: below the
    /// navigation bar, above the keyboard and the floating "+". A block that only peeks in at an edge counts as
    /// hittable for XCUITest, but a tap at a given point of it can miss.
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, anchor: CGVector = CGVector(dx: 0.5, dy: 0.5)) -> Bool {
        waitForKeyboard(app)
        func freeArea() -> ClosedRange<CGFloat> {
            let top = app.navigationBars.firstMatch.frame.maxY + 8
            var bottom = app.windows.firstMatch.frame.maxY - 8
            for blocker in [app.keyboards.firstMatch, app.buttons["page-add-block"], app.buttons["space-new-page"]] where blocker.exists {
                bottom = min(bottom, blocker.frame.minY - 8)
            }
            return top...max(top, bottom)
        }
        for _ in 0..<10 {
            guard element.exists else {
                app.swipeUp()
                continue
            }
            let area = freeArea(), frame = element.frame, y = frame.minY + frame.height * anchor.dy
            if area.contains(y) {
                // Caught between two layouts, `isHittable` fails the test (“Activation point invalid”): asked once the
                // element stays put. It also tells whether something lies over the element (a tree row under the "+").
                Thread.sleep(forTimeInterval: 0.1)
                guard element.frame == frame else { continue }
                if element.isHittable { return true }
            }
            // Move that point to the middle of the free area, without momentum.
            let shift = max(-300, min(300, (area.lowerBound + area.upperBound) / 2 - y))
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: shift)), withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        return false
    }

    // MARK: - Tests

    /// Tap a paragraph, type, toggle bold, keep typing, finish: the reader shows the text at once; the server gets
    /// "Tipp<stamp>" and bold "Fett<stamp>" at the end of the paragraph.
    func test1_TapParagraphTypeAndBold() {
        let app = launchPage()
        snapshot(app, "1-page")
        // The page opens at the very top (title visible), without horizontal offset.
        let title = element(app, "page-title")
        XCTAssertTrue(title.waitForExistence(timeout: 5) && title.isHittable, "Page doesn't open at the very top")
        let heading = app.staticTexts["Überschrift"].firstMatch
        XCTAssertTrue(heading.exists, "Heading missing")
        XCTAssertGreaterThanOrEqual(heading.frame.minX, 8, "Content is shifted horizontally")
        let editor = edit(app, blockContaining: "Erster Absatz")
        let bold = app.buttons["format-bold"]
        let toolbarVisible = bold.waitForExistence(timeout: 8)
        snapshot(app, "1-editing")
        XCTAssertTrue(toolbarVisible, "Format toolbar doesn't appear")
        editor.typeText(" Tipp\(stamp)")
        XCTAssertFalse(bold.isSelected, "Bold is marked active before toggling")
        bold.tap()
        XCTAssertTrue(bold.wait(for: \.isSelected, toEqual: true, timeout: 3), "Bold isn't marked active after toggling")
        editor.typeText(" Fett\(stamp)")
        snapshot(app, "1-typed")
        finishEditing(app)
        let shown = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Fett\(stamp)")).firstMatch
        XCTAssertTrue(shown.waitForExistence(timeout: 5), "Reader doesn't show the typed text after editing ends")
        snapshot(app, "1-after")
    }

    /// New paragraph via "+", type, bold: expects "Neu<stamp>", bold "NeuFett<stamp>" and bold "Taste<stamp>" from ⌘B
    /// on the selected word (system formatting sets only the font).
    func test2_AddParagraphTypeAndBold() {
        let app = launchPage()
        let editor = appendBlock(app, editable: "New paragraph doesn't become editable")
        let bold = app.buttons["format-bold"]
        XCTAssertTrue(bold.waitForExistence(timeout: 8), "Format toolbar doesn't appear in the new paragraph")
        editor.typeText("Neu\(stamp)")
        bold.tap()
        editor.typeText(" NeuFett\(stamp)")
        bold.tap()
        editor.typeText(" Taste\(stamp)")
        editor.typeKey(.leftArrow, modifierFlags: [.shift, .option])
        // A person pauses between selecting, ⌘B and "Done"; back to back, ⌘B was often lost.
        Thread.sleep(forTimeInterval: 0.6)
        editor.typeKey("b", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.6)
        // While iOS hides and brings back the on-screen keyboard after a hardware key, a synthesized one can get lost
        // on its way: the editor keeps the keyboard focus but never sees ⌘ or B (logged in the app, 1 of 8 runs under
        // load). Only if nothing changed, ⌘B goes again.
        if !bold.wait(for: \.isSelected, toEqual: true, timeout: 3) {
            editor.typeKey("b", modifierFlags: .command)
        }
        XCTAssertTrue(bold.wait(for: \.isSelected, toEqual: true, timeout: 3), "The Bold button doesn't show the bold from ⌘B")
        snapshot(app, "2-typed")
        finishEditing(app)
    }

    /// Tap a list item and type: expects "Liste<stamp>" in it.
    func test3_TapListItemAndType() {
        let app = launchPage()
        let editor = edit(app, blockContaining: "Punkt eins")
        XCTAssertTrue(app.buttons["format-bold"].waitForExistence(timeout: 8), "Format toolbar doesn't appear in the list item")
        editor.typeText(" Liste\(stamp)")
        snapshot(app, "3-typed")
        finishEditing(app)
    }

    /// The real path: Home → space → page (via the space search) → tap paragraph → type → done.
    func test4_NavigateAndEdit() {
        let app = launch(openPage: false)
        let slug = environment["DOCMOST_UITEST_SPACE_SLUG"] ?? "demo"
        let space = app.buttons["space-\(slug)"]
        XCTAssertTrue(space.waitForExistence(timeout: 30), "Space card “\(slug)” not on the home screen")
        space.tap()
        // The search runs in the space view; results replace the page tree.
        let search = app.textFields["space-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 20), "Search field in the space not found")
        search.tap()
        let title = environment["DOCMOST_UITEST_PAGE_TITLE"] ?? "Editor-Test"
        search.typeText(title)
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-result-' AND label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20), "Search result “\(title)” missing")
        snapshot(app, "4-search")
        result.tap()
        waitForSync(app)
        snapshot(app, "4-page")
        let editor = edit(app, blockContaining: "Letzter Absatz")
        editor.typeText(" Weg\(stamp)")
        finishEditing(app)
        let shown = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Weg\(stamp)")).firstMatch
        XCTAssertTrue(shown.waitForExistence(timeout: 5), "Reader doesn't show the typed text")
        snapshot(app, "4-after")
    }

    /// Return creates a new paragraph; Backspace at the start of an empty paragraph merges it back.
    func test5_ReturnAndBackspace() {
        let app = launchPage()
        var editor = edit(app, blockContaining: "Letzter Absatz")
        editor.typeText("\n")
        // The new paragraph gets a new editor.
        editor = activeEditor(app, "No editor after Return")
        Thread.sleep(forTimeInterval: 0.6)
        editor.typeText("Return\(stamp)")
        snapshot(app, "5-return")
        finishEditing(app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "Return\(stamp)")).firstMatch.waitForExistence(timeout: 5), "New paragraph missing in the reader")

        editor = edit(app, blockContaining: "Letzter Absatz")
        editor.typeText("\n")
        editor = activeEditor(app, "No editor after the second Return")
        Thread.sleep(forTimeInterval: 0.6)
        editor.typeText(XCUIKeyboardKey.delete.rawValue)
        editor = activeEditor(app, "No editor after Backspace")
        Thread.sleep(forTimeInterval: 0.6)
        editor.typeText(" Merge\(stamp)")
        snapshot(app, "5-merge")
        finishEditing(app)
    }

    /// New page via the space's FAB: opens in the editor, title focused; then types into its first block, sets the
    /// icon via the emoji keyboard and moves the page to the trash.
    func test6_CreatePageFromSpace() {
        let app = launch(openPage: false)
        let slug = environment["DOCMOST_UITEST_SPACE_SLUG"] ?? "demo"
        let space = app.buttons["space-\(slug)"]
        XCTAssertTrue(space.waitForExistence(timeout: 30), "Space card missing")
        space.tap()
        let fab = app.buttons["space-new-page"]
        XCTAssertTrue(fab.waitForExistence(timeout: 20), "FAB missing")
        fab.tap()
        let title = element(app, "page-title")
        XCTAssertTrue(title.waitForExistence(timeout: 20), "New page doesn't open in the editor")
        snapshot(app, "6-new-page")
        Thread.sleep(forTimeInterval: 0.8)
        let pageTitle = "Neue Seite \(stamp)"
        app.typeText(pageTitle + "\n")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", pageTitle)).firstMatch.waitForExistence(timeout: 10)
            || app.navigationBars[pageTitle].waitForExistence(timeout: 5), "Title wasn't applied")
        snapshot(app, "6-titled")
        // Type into the empty page's first block (its id comes from the engine) and keep typing past the sync.
        waitForSync(app)
        app.buttons["page-space"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: 50)).tap()
        let editor = activeEditor(app)
        Thread.sleep(forTimeInterval: 0.6)
        editor.typeText("Text\(stamp)")
        // Past the commit (400 ms) and the engine's document update.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(editor.exists, "Editor closes after the sync")
        editor.typeText(" weiter")
        snapshot(app, "6-body")
        finishEditing(app)
        Thread.sleep(forTimeInterval: 1.5)
        let icon = app.buttons["page-icon"]
        XCTAssertTrue(icon.waitForExistence(timeout: 10), "Icon button missing")
        icon.tap()
        let emojiField = app.textFields["emoji-field"].firstMatch
        XCTAssertTrue(emojiField.waitForExistence(timeout: 5), "Emoji field missing")
        Thread.sleep(forTimeInterval: 1.0)
        emojiField.typeText("🚀")
        let iconSet = expectation(for: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "🚀", "🚀"), evaluatedWith: app.buttons["page-icon"])
        wait(for: [iconSet], timeout: 15)
        snapshot(app, "6-icon")
        // Saving reloads the page: open the menu only afterwards, retrying once if needed.
        Thread.sleep(forTimeInterval: 1.5)
        let trash = button(app, labels: ["Move to Trash", "In den Papierkorb", "In den Papierkorb verschieben"])
        let moreFrame = app.buttons["page-more"].frame
        app.buttons["page-more"].tap()
        if !trash.waitForExistence(timeout: 4) {
            app.buttons["page-more"].tap()
        }
        XCTAssertTrue(trash.waitForExistence(timeout: 5), "Trash menu item missing")
        trash.tap()
        assertPopover(app, at: moreFrame)
        let confirm = button(app, labels: ["Move to Trash", "In den Papierkorb", "In den Papierkorb verschieben"])
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Confirmation missing")
        confirm.tap()
        // The banner's own text: the "Moved to trash" toast would satisfy a looser match.
        let banner = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["This page is in the trash.", "Diese Seite liegt im Papierkorb."])).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "Trash banner missing")

        // Delete it permanently from the space's trash, so runs leave no pages behind; that confirmation shows at the
        // swiped row.
        backButton(app).tap()
        let spaceTrash = app.buttons["space-trash"]
        XCTAssertTrue(spaceTrash.waitForExistence(timeout: 10), "Space trash button missing")
        spaceTrash.tap()
        let row = app.cells.containing(NSPredicate(format: "label == %@", pageTitle)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Page missing from the space's trash")
        let rowFrame = row.frame
        row.swipeLeft()
        let deleteLabels = ["Delete Permanently", "Endgültig löschen"]
        let delete = button(app, labels: deleteLabels)
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "Swipe shows no “Delete Permanently”")
        delete.tap()
        assertPopover(app, at: rowFrame)
        app.popovers.firstMatch.buttons.matching(NSPredicate(format: "label IN %@", deleteLabels)).firstMatch.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "Page still in the trash after deleting it permanently")
    }

    /// Templates (Enterprise feature `templates`), as on the web; the script makes "Vorlage<stamp> Bereich" for the
    /// test space and "Vorlage<stamp> Global". Holding the space's "+" offers a template: "This Space" lists the space's
    /// own, its preview shows the content, "Use Template" makes the page. A new, empty page offers "Get started with"
    /// databases and a template: "Use" on the global one fills the page and gives it the template's title. The server
    /// check expects both pages with the template's content, then deletes them and the templates.
    func test78_Templates() throws {
        try XCTSkipIf((environment["DOCMOST_UITEST_TEMPLATES"] ?? "").isEmpty, "No templates on this server (license)")
        let app = launch(openPage: false)
        let space = app.buttons["space-\(environment["DOCMOST_UITEST_SPACE_SLUG"] ?? "demo")"]
        XCTAssertTrue(space.waitForExistence(timeout: 30), "Space card missing")
        space.tap()
        let fab = app.buttons["space-new-page"]
        XCTAssertTrue(fab.waitForExistence(timeout: 20), "“+” missing")
        fab.press(forDuration: 1.2)
        let fromTemplate = button(app, labels: ["New Page from Template", "Neue Seite aus Vorlage"])
        XCTAssertTrue(fromTemplate.waitForExistence(timeout: 5), "Holding “+” offers no template")
        fromTemplate.tap()
        let spaceTemplate = app.staticTexts["Vorlage\(stamp) Bereich"]
        XCTAssertTrue(spaceTemplate.waitForExistence(timeout: 10), "“This Space” doesn't list the space's template")
        XCTAssertFalse(app.staticTexts["Vorlage\(stamp) Global"].exists, "“This Space” lists the global template")
        snapshot(app, "78-picker")
        spaceTemplate.tap()
        XCTAssertTrue(app.staticTexts["Agenda\(stamp)"].waitForExistence(timeout: 10), "The preview doesn't show the content")
        app.buttons["template-use"].tap()
        let title = element(app, "page-title")
        XCTAssertTrue(title.waitForExistence(timeout: 20), "The page from the template doesn't open")
        XCTAssertTrue(app.staticTexts["Agenda\(stamp)"].waitForExistence(timeout: 20), "The new page lacks the template's content")
        XCTAssertEqual(title.value as? String, "Vorlage\(stamp) Bereich", "The new page lacks the template's title")
        snapshot(app, "78-from-template")

        backButton(app).tap()
        XCTAssertTrue(fab.waitForExistence(timeout: 10), "Back in the space, “+” is missing")
        fab.tap()
        XCTAssertTrue(element(app, "page-title").waitForExistence(timeout: 20), "The new page doesn't open")
        waitForSync(app)
        let chip = app.buttons["get-started-template"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "The empty page offers no template")
        XCTAssertTrue(app.buttons["get-started-database"].exists && app.buttons["get-started-kanban"].exists,
                      "The empty page offers no databases")
        snapshot(app, "78-get-started")
        chip.tap()
        let all = button(app, labels: ["All Templates", "Alle Vorlagen"])
        XCTAssertTrue(all.waitForExistence(timeout: 10), "The picker offers no “All Templates”")
        all.tap()
        let use = app.buttons["template-use-Vorlage\(stamp) Global"]
        XCTAssertTrue(use.waitForExistence(timeout: 10), "“All Templates” lacks the global template")
        use.tap()
        XCTAssertTrue(app.staticTexts["Agenda\(stamp)"].waitForExistence(timeout: 20), "The template doesn't fill the page")
        let filledTitle = element(app, "page-title"), globalTitle = "Vorlage\(stamp) Global"
        let titled = NSPredicate { _, _ in filledTitle.value as? String == globalTitle }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: titled, object: nil)], timeout: 10), .completed,
                       "The filled page doesn't take the template's title: “\(filledTitle.value ?? "")”")
        snapshot(app, "78-filled")
    }

    /// Long-press a block and drag it onto the heading: "Letzter Absatz" lands before "Überschrift".
    func test7_DragBlock() {
        let app = launchPage()
        let source = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Letzter Absatz")).firstMatch
        let heading = app.staticTexts["Überschrift"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10) && heading.exists, "Blocks not found")
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.2, thenDragTo: heading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
        snapshot(app, "7-dragged")
        let moved = expectation(for: NSPredicate { _, _ in
            let s = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Letzter Absatz")).firstMatch
            let h = app.staticTexts["Überschrift"].firstMatch
            return s.exists && h.exists && s.frame.minY < h.frame.minY
        }, evaluatedWith: nil)
        wait(for: [moved], timeout: 10)
    }

    /// "/zit" in a new paragraph → quote; the text lands in the quote.
    func test9_SlashCommandQuote() {
        let app = launchPage()
        var editor = edit(app, blockContaining: "Letzter Absatz")
        editor.typeText("\n")
        editor = activeEditor(app, "No editor after Return")
        Thread.sleep(forTimeInterval: 0.6)
        editor.typeText("/zit")
        let quote = app.buttons["slash-block-quote"]
        XCTAssertTrue(quote.waitForExistence(timeout: 8), "Slash menu shows no quote")
        snapshot(app, "9-slash")
        quote.tap()
        editor = activeEditor(app, "Quote doesn't become editable")
        Thread.sleep(forTimeInterval: 0.6)
        editor.typeText("Zitat\(stamp)")
        snapshot(app, "9-quote")
        finishEditing(app)
    }

    /// "@Editor" in a list item → suggestion "Editor-Test" → mention. Bold on part of it ("Test") keeps the mention,
    /// as on the web, where a selection covers it whole or not at all.
    func test10_MentionPage() {
        let app = launchPage()
        let editor = edit(app, blockContaining: "Punkt zwei")
        editor.typeText(" @Editor")
        let suggestion = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "mention-page-", "Editor-Test")).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10), "No page suggestion for the mention")
        snapshot(app, "10-mention")
        suggestion.tap()
        Thread.sleep(forTimeInterval: 0.8)
        editor.typeText("danach\(stamp)")
        snapshot(app, "10-inserted")
        // Back over the typed word and the space after the mention, then select the mention's last 4 characters.
        for _ in " danach\(stamp)" { editor.typeKey(.leftArrow, modifierFlags: []) }
        for _ in "Test" { editor.typeKey(.leftArrow, modifierFlags: .shift) }
        let bold = app.buttons["format-bold"]
        bold.tap()
        XCTAssertTrue(bold.wait(for: \.isSelected, toEqual: true, timeout: 3), "Bold isn't marked active on part of the mention")
        snapshot(app, "10-part-bold")
        finishEditing(app)
    }

    /// Page tree: long-press "Editor-Test" and drag it to the top; the page becomes the first root page.
    func test11_TreeDragToTop() {
        let app = launch(openPage: false)
        let slug = environment["DOCMOST_UITEST_SPACE_SLUG"] ?? "demo"
        let space = app.buttons["space-\(slug)"]
        XCTAssertTrue(space.waitForExistence(timeout: 30), "Space card missing")
        space.tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "page-"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), "Page tree empty")
        let first = rows.element(boundBy: 0)
        let firstId = first.identifier
        let pageId = environment["DOCMOST_DEBUG_PAGE"]!
        let source = app.buttons["page-\(pageId)"]
        XCTAssertTrue(scrollTo(source, in: app), "Test page not in the tree")
        XCTAssertNotEqual(firstId, "page-\(pageId)", "Test page is already at the top – reset the test data")
        // Scrolling may have hidden the first row: scroll back up until it is hittable.
        for _ in 0..<8 where !first.isHittable { app.swipeDown() }
        XCTAssertTrue(first.isHittable && source.exists, "Rows not visible at the same time")
        snapshot(app, "11-before")
        // The row's top quarter (the title's top would be its middle half already).
        let firstRow = element(app, "tree-row-" + firstId.dropFirst("page-".count))
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 1.2, thenDragTo: firstRow.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.1)))
        let moved = expectation(for: NSPredicate { _, _ in
            let s = app.buttons["page-\(pageId)"]
            let f = app.buttons[firstId]
            return s.exists && f.exists && s.frame.minY < f.frame.minY
        }, evaluatedWith: nil)
        wait(for: [moved], timeout: 15)
        snapshot(app, "11-after")
    }

    /// Page tree drop zones, as on the web (`TreeDropZone`). Below the test page the script makes "Baum-Ziel<stamp>"
    /// with the subpage "Baum-Kind<stamp>", then "Baum-Quelle<stamp>", which is dragged:
    /// 1. onto the middle of the collapsed "Baum-Ziel": into it, which opens it;
    /// 2. onto its top quarter: before it, at its level;
    /// 3. onto the bottom quarter of the open "Baum-Ziel": into it, below "Baum-Kind" (thirds put it after the subpages);
    /// 4. before it again, then held over the bottom quarter of the collapsed "Baum-Ziel": that opens it, so the page
    ///    goes into it rather than after it.
    func test79_TreeDropZones() {
        let app = launch(openPage: false)
        let slug = environment["DOCMOST_UITEST_SPACE_SLUG"] ?? "demo"
        let space = app.buttons["space-\(slug)"]
        XCTAssertTrue(space.waitForExistence(timeout: 30), "Space card missing")
        space.tap()
        let testPage = element(app, "tree-row-\(environment["DOCMOST_DEBUG_PAGE"]!)")
        XCTAssertTrue(scrollTo(testPage, in: app), "Test page not in the tree")
        let expand = testPage.buttons.matching(NSPredicate(format: "label IN %@", ["Expand", "Ausklappen"])).firstMatch
        if expand.exists { expand.tap() }
        // While its subpages load, the row shows a spinner instead of the chevron.
        let collapse = testPage.buttons.matching(NSPredicate(format: "label IN %@", ["Collapse", "Einklappen"])).firstMatch
        XCTAssertTrue(collapse.waitForExistence(timeout: 20), "The test page's subpages don't load")
        func page(_ name: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'page-' AND label CONTAINS %@", name + stamp)).firstMatch
        }
        let target = page("Baum-Ziel"), child = page("Baum-Kind"), source = page("Baum-Quelle")
        // The tree shows only the rows on screen: scroll to them.
        XCTAssertTrue(scrollTo(target, in: app), "“Baum-Ziel” missing below the test page")
        XCTAssertTrue(source.waitForExistence(timeout: 5), "“Baum-Quelle” missing below “Baum-Ziel”")
        let targetRow = element(app, "tree-row-" + target.identifier.dropFirst("page-".count))

        /// Drags "Baum-Quelle" to `dy` of the "Baum-Ziel" row (0 its top, 1 its bottom), held there for `hold` seconds.
        /// Let go at once, a busy simulator could end the touch before the drag took over: the row lifted and dropped
        /// back in its place.
        func drag(to dy: CGFloat, hold: TimeInterval = 0.5) {
            // Both rows clear of the list's bottom: a row cut off there still counts as hittable, and the drag began
            // on nothing.
            XCTAssertTrue(scrollTo(source, in: app), "“Baum-Quelle” not visible next to “Baum-Ziel”")
            XCTAssertTrue(scrollTo(targetRow, in: app), "“Baum-Ziel” not in the tree")
            let start = source.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            let end = targetRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: dy))
            start.press(forDuration: 1.2, thenDragTo: end, withVelocity: .default, thenHoldForDuration: hold)
        }
        /// Waits until the tree shows the move (it reloads once the server has it).
        func expect(_ description: String, _ shown: @escaping () -> Bool) {
            let moved = expectation(for: NSPredicate { _, _ in shown() }, evaluatedWith: nil)
            moved.expectationDescription = description
            wait(for: [moved], timeout: 15)
        }
        // A subpage's title starts one level (24 points) further right.
        func isSubpageOfTarget() -> Bool {
            source.exists && child.exists && abs(source.frame.minX - child.frame.minX) < 2
                && child.frame.minX > target.frame.minX + 10 && source.frame.minY > child.frame.minY
        }
        func isBeforeTarget() -> Bool {
            source.exists && abs(source.frame.minX - target.frame.minX) < 2 && source.frame.maxY <= target.frame.minY + 1
        }

        drag(to: 0.5)
        expect("“Baum-Quelle” goes into the collapsed “Baum-Ziel”, below “Baum-Kind”", isSubpageOfTarget)
        snapshot(app, "79-1-into")
        drag(to: 0.1)
        expect("“Baum-Quelle” goes before “Baum-Ziel”", isBeforeTarget)
        drag(to: 0.9)
        expect("“Baum-Quelle” goes into the open “Baum-Ziel”, not after its subpages", isSubpageOfTarget)
        snapshot(app, "79-3-into-open")
        drag(to: 0.1)
        expect("“Baum-Quelle” goes before “Baum-Ziel” again", isBeforeTarget)
        targetRow.buttons.matching(NSPredicate(format: "label IN %@", ["Collapse", "Einklappen"])).firstMatch.tap()
        XCTAssertTrue(child.waitForNonExistence(timeout: 5), "“Baum-Ziel” doesn't collapse")
        drag(to: 0.9, hold: 1.5)
        expect("Held over the collapsed “Baum-Ziel”, “Baum-Quelle” opens it and goes into it", isSubpageOfTarget)
        snapshot(app, "79-4-opened")
    }

    /// Insert a table and add a row below with "Table" in the keyboard toolbar.
    func test8_TableInsertRow() {
        let app = launchPage()
        appendBlock(app, labels: ["Table", "Tabelle"], missing: "Table menu item missing", editable: "First cell doesn't become editable")
        app.typeText("Zelle\(stamp)")
        Thread.sleep(forTimeInterval: 0.6)
        tapToolbarButton(app, "editor-table")
        tapToolbarButton(app, "table-insert-row-below")
        activeEditor(app, timeout: 10, "New row doesn't become editable")
        snapshot(app, "8-table")
        finishEditing(app)
    }

    /// The table's actions in the keyboard toolbar stay while the cursor moves with them: merge the first header cell
    /// with the next one, color it, add a row below and type there. The script checks the server state ("Table toolbar").
    func test80_TableToolbar() {
        let app = launchPage()
        appendBlock(app, labels: ["Table", "Tabelle"], missing: "Table menu item missing", editable: "First cell doesn't become editable")
        app.typeText("Kopf\(stamp)")
        Thread.sleep(forTimeInterval: 0.6)
        tapToolbarButton(app, "editor-table")
        let split = app.buttons["table-split"]
        XCTAssertTrue(split.waitForExistence(timeout: 5) && !split.isEnabled, "A single cell offers splitting")
        tapToolbarButton(app, "table-merge-right")
        let splits = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: split)
        wait(for: [splits], timeout: 8)
        snapshot(app, "80-1-merged")
        tapToolbarButton(app, "table-format")
        tapToolbarButton(app, "table-color-blue")
        snapshot(app, "80-2-format")
        tapToolbarButton(app, "editor-back")
        tapToolbarButton(app, "table-insert-row-below")
        Thread.sleep(forTimeInterval: 0.6)
        activeEditor(app, timeout: 10, "New row doesn't become editable").typeText("Neu\(stamp)")
        XCTAssertTrue(app.buttons["table-insert-row-below"].exists, "The table row left the toolbar when the cursor moved to the new row")
        snapshot(app, "80-3-new-row")
        finishEditing(app)
    }

    /// Tap cells in different table rows: each time the editor is centered between navigation bar and keyboard
    /// (measurable only while the software keyboard is visible).
    func test13_TableRowsCentered() {
        let app = launchPage()
        for (index, cell) in ["ZeileEins", "ZeileDrei", "ZeileVier"].enumerated() {
            let editor = edit(app, blockContaining: cell)
            Thread.sleep(forTimeInterval: 1.5)
            snapshot(app, "13-row-\(index)")
            // Visible area: navigation bar bottom to keyboard toolbar top.
            let done = app.buttons["editor-done"]
            XCTAssertTrue(done.waitForExistence(timeout: 5), "Toolbar missing")
            let center = (app.navigationBars.firstMatch.frame.maxY + done.frame.minY) / 2
            let offset = editor.frame.midY - center
            XCTAssertLessThan(abs(offset), 60, "“\(cell)” not centered: editor center is \(Int(offset)) pt off center")
            finishEditing(app)
        }
    }

    /// Keyboard toolbar buttons except bold (test1) and comment, in a separate paragraph at the page end: formats as
    /// typing attributes, line break, link, undo/redo of text and block type, insert, code block, duplicate, delete.
    /// The script checks the server state ("Toolbar: …").
    func test15_ToolbarActions() {
        let app = launchPage()
        var editor = appendBlock(app, editable: "New paragraph doesn't become editable")
        XCTAssertTrue(app.buttons["format-italic"].waitForExistence(timeout: 8), "Toolbar missing")
        editor.typeText("Leiste\(stamp)")
        // Typing attributes: toggle on, type a word, toggle off.
        for (id, word) in [("format-italic", "Kursiv"), ("format-underline", "Unter"), ("format-strike", "Durch"),
                           ("format-highlight", "Mark")] {
            editor.typeText(" ")
            tapToolbarButton(app, id)
            editor.typeText("\(word)\(stamp)")
            tapToolbarButton(app, id)
        }
        // As on the web, inline code ("</>") sits with the formats; the code block has its own button.
        editor.typeText(" ")
        tapToolbarButton(app, "format-code")
        editor.typeText("Kode\(stamp)")
        tapToolbarButton(app, "format-code")
        tapToolbarButton(app, "format-linebreak")
        editor.typeText("Umbruch\(stamp)")
        snapshot(app, "15-formats")

        // Link without a selection: the address is appended as linked text and editing continues.
        tapToolbarButton(app, "format-link")
        let address = app.textFields["link-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5), "Link sheet missing")
        address.tap()
        address.typeText("https://example.com/\(stamp)")
        snapshot(app, "15-link-sheet")
        app.buttons.matching(NSPredicate(format: "identifier == 'link-apply' OR label IN %@", ["Apply", "Übernehmen"])).firstMatch.tap()
        editor = activeEditor(app, timeout: 5, "Paragraph is no longer being edited after the link")
        XCTAssertTrue(waitForText(editor, contains: "example.com/\(stamp)"), "Link address missing in the paragraph")
        snapshot(app, "15-link")
        // Typing right after the link continues outside it, as on the web. Short, no stamp: if the line wrapped, the
        // block center that "Duplicate" taps below would land on the link.
        editor = editorAfterSheet(app, closing: address)
        editor.typeText(" Danach")

        // Link to a page: as on the web, the whole result row takes the tap, even the empty middle between the short
        // title and the space. Cancel leaves the paragraph unchanged.
        tapToolbarButton(app, "format-link")
        XCTAssertTrue(address.waitForExistence(timeout: 5), "Link sheet missing")
        let pageSearch = app.textFields.matching(NSPredicate(format: "placeholderValue IN %@", ["Search pages", "Seiten suchen"])).firstMatch
        pageSearch.tap()
        // The test page itself: always there with this title, unlike the sample pages a person may rename.
        let target = environment["DOCMOST_UITEST_PAGE_TITLE"] ?? "Editor-Test"
        pageSearch.typeText(target)
        let pageResult = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", target + ",")).firstMatch
        XCTAssertTrue(pageResult.waitForExistence(timeout: 10), "Page search doesn't find “\(target)”")
        pageResult.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(waitForText(address, contains: "/p/"), "Tap in the middle of the page row doesn't take its link")
        snapshot(app, "15-link-page")
        button(app, labels: ["Cancel", "Abbrechen"]).tap()
        editor = editorAfterSheet(app, closing: pageSearch)

        Thread.sleep(forTimeInterval: 1.2)
        editor.typeText(" Rueck\(stamp)")
        Thread.sleep(forTimeInterval: 1.2)
        tapToolbarButton(app, "editor-undo")
        XCTAssertTrue(waitForText(editor, contains: "Rueck\(stamp)", expected: false), "Undo doesn't remove the typed word")
        tapToolbarButton(app, "editor-redo")
        XCTAssertTrue(waitForText(editor, contains: "Rueck\(stamp)"), "Redo doesn't restore the word")
        tapToolbarButton(app, "editor-undo")
        XCTAssertTrue(waitForText(editor, contains: "Rueck\(stamp)", expected: false), "Second undo doesn't remove the word")

        // Block type: heading 2, undo, redo (result: heading 2).
        tapToolbarButton(app, "editor-block-type")
        app.buttons["type-heading2"].tap()
        activeEditor(app, "No editor after the conversion")
        Thread.sleep(forTimeInterval: 1.2)
        tapToolbarButton(app, "editor-undo")
        Thread.sleep(forTimeInterval: 1.0)
        snapshot(app, "15-heading-undone")
        tapToolbarButton(app, "editor-redo")
        Thread.sleep(forTimeInterval: 1.0)
        snapshot(app, "15-heading")

        // Insert via "+": insert menu below the block, new paragraph after it.
        tapToolbarButton(app, "editor-insert")
        let insertParagraph = app.buttons["slash-block-paragraph"]
        XCTAssertTrue(insertParagraph.waitForExistence(timeout: 5), "“+” doesn't show the insert list")
        insertParagraph.tap()
        editor = activeEditor(app, "Inserted paragraph doesn't become editable")
        Thread.sleep(forTimeInterval: 0.6)
        editor.typeText("Eingefuegt\(stamp)")
        snapshot(app, "15-inserted")
        // The toolbar's code block button (main row) turns the paragraph into a code block, like "/code".
        Thread.sleep(forTimeInterval: 0.6)
        tapToolbarButton(app, "editor-code-block")
        Thread.sleep(forTimeInterval: 1.5)
        snapshot(app, "15-codeblock")

        let marker = "Leiste\(stamp)"
        _ = edit(app, blockContaining: marker)
        tapToolbarButton(app, "editor-duplicate")
        XCTAssertTrue(waitForCount(app, of: marker, equals: 2), "Duplicate doesn't create a copy")
        snapshot(app, "15-duplicated")
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).element(boundBy: 1).tap()
        activeEditor(app, "Copy doesn't become editable")
        tapToolbarButton(app, "editor-delete")
        let confirm = button(app, labels: ["Delete", "Löschen"])
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Delete confirmation missing")
        confirm.tap()
        XCTAssertTrue(waitForCount(app, of: marker, equals: 1), "Delete doesn't remove the copy")
        snapshot(app, "15-deleted")
    }

    /// Taps a toolbar button left of "Done". On a wide iPhone a button can stick out of its scrolling row, and a tap on
    /// its center then lands on "Done" and closes the editor; a button hidden further right is left to XCUITest.
    private func tapToolbarButton(_ app: XCUIApplication, _ id: String) {
        let button = app.buttons[id], done = app.buttons["editor-done"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Toolbar button “\(id)” missing")
        let frame = button.frame, edge = done.exists ? done.frame.minX - 6 : .infinity
        guard frame.maxX > edge, edge - frame.minX >= 12 else { return button.tap() }
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: (frame.minX + edge) / 2, dy: frame.midY)).tap()
    }

    /// Waits until exactly `count` text blocks contain the fragment.
    private func waitForCount(_ app: XCUIApplication, of fragment: String, equals count: Int, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fragment)).count == count { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    /// Waits until the editor's text contains the fragment, or with `expected: false` no longer does.
    private func waitForText(_ editor: XCUIElement, contains fragment: String, expected: Bool = true, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ((editor.value as? String) ?? "").contains(fragment) == expected { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return ((editor.value as? String) ?? "").contains(fragment) == expected
    }

    /// A tap at the start of a paragraph puts the caret there, as on the web; it used to go to the end. The script
    /// checks that "Anfang<stamp>" starts the paragraph after the table.
    /// A server newer than the app's editor (Docmost 0.98 via the debug override): the page opens read-only with a
    /// notice, and tapping its text starts no editing.
    func test58_NewerServerOpensPagesReadOnly() {
        var extra = environment.filter { ["DOCMOST_DEBUG_PAGE", "DOCMOST_DEBUG_SPACE"].contains($0.key) }
        extra["DOCMOST_DEBUG_SERVER_VERSION"] = "0.98.0"
        let app = launchApp(extraEnvironment: extra)
        let pill = element(app, "page-status")
        XCTAssertTrue(pill.waitForExistence(timeout: 40), "Page didn't load")
        XCTAssertTrue(["Read only", "Nur lesen"].contains(pill.label), "Status is “\(pill.label)”")
        let notice = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Docmost 0.98.0")).firstMatch
        XCTAssertTrue(notice.exists, "No notice about the server version")
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Erster Absatz")).firstMatch.tap()
        XCTAssertFalse(app.buttons["format-bold"].waitForExistence(timeout: 3), "Editing started on a newer server")
        snapshot(app, "58-newer-server")
    }

    /// A page opened offline is read-only ("Offline"); once the network is back it becomes editable by itself. The app
    /// pretends to be offline for its first seconds (`DOCMOST_DEBUG_OFFLINE_SECONDS`).
    func test62_PageEditableWhenBackOnline() {
        var environment = environment.filter { ["DOCMOST_DEBUG_PAGE", "DOCMOST_DEBUG_SPACE"].contains($0.key) }
        environment["DOCMOST_DEBUG_OFFLINE_SECONDS"] = "15"
        let app = launchApp(extraEnvironment: environment)
        let pill = element(app, "page-status")
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "Page didn't load")
        XCTAssertEqual(pill.label, "Offline", "The page didn't open read-only while offline")
        waitForSync(app)
        _ = edit(app, blockContaining: "Punkt eins")
        finishEditing(app)
    }

    func test52_TapPlacesCaret() {
        let app = launchPage()
        let block = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Nach der Tabelle")).firstMatch
        XCTAssertTrue(scrollTo(block, in: app, anchor: CGVector(dx: 0, dy: 0)), "Paragraph after the table not found")
        // Left end of the first line, before the middle of the first letter.
        block.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1, dy: 10)).tap()
        let editor = activeEditor(app, "Tap doesn't open the editor")
        Thread.sleep(forTimeInterval: 0.6)
        editor.typeText("Anfang\(stamp)")
        snapshot(app, "52-typed")
        finishEditing(app)
    }

    /// A table cell grows with its content: Return in a cell adds a paragraph there, and the next row starts below it
    /// instead of covering it (rows used to share one height). The script checks both paragraphs in the cell.
    func test53_TableCellGrows() {
        let app = launchPage()
        var editor = edit(app, blockContaining: "b1")
        editor.typeText("\n")
        editor = activeEditor(app, "No editor in the cell's new paragraph")
        Thread.sleep(forTimeInterval: 0.6)
        editor.typeText("Zweite\(stamp)")
        snapshot(app, "53-editing")
        finishEditing(app)
        let second = app.staticTexts["Zweite\(stamp)"]
        let nextRow = app.staticTexts["ZeileZwei"]
        XCTAssertTrue(second.waitForExistence(timeout: 5) && nextRow.exists, "Cell texts missing")
        snapshot(app, "53-grown")
        XCTAssertLessThanOrEqual(second.frame.maxY, nextRow.frame.minY, "The next row covers the cell's second paragraph")
    }

    /// Return on an empty item in the middle of a list splits the list, as on the web: the new paragraph sits between
    /// "Punkt eins" and "Punkt zwei". The script checks the order on the server.
    func test54_EmptyItemSplitsList() {
        let app = launchPage()
        var editor = edit(app, blockContaining: "Punkt eins")
        editor.typeText("\n")
        editor = activeEditor(app, "No editor in the new item")
        Thread.sleep(forTimeInterval: 0.6)
        editor.typeText("\n")
        editor = activeEditor(app, "No editor after leaving the empty item")
        Thread.sleep(forTimeInterval: 0.6)
        editor.typeText("Mitte\(stamp)")
        snapshot(app, "54-split")
        finishEditing(app)
    }

    /// "/Überschrift" in a list item's only line takes the line out of the list as the heading, as on the web. Its own
    /// list at the page end, so the other tests' lists stay. The script checks the heading and that no list holds it.
    func test55_HeadingLeavesList() {
        let app = launchPage()
        _ = appendBlock(app, editable: "New paragraph doesn't become editable")
        slash(app, "aufz", pick: "block-bulletList")
        let editor = activeEditor(app, "No editor in the new list")
        Thread.sleep(forTimeInterval: 0.6)
        // "/" opens the menu only after a space, as on the web.
        editor.typeText("Kopf\(stamp) ")
        slash(app, "über", pick: "block-heading2")
        activeEditor(app, "No editor in the heading")
        snapshot(app, "55-heading")
        finishEditing(app)
    }

    /// Return on an empty line in a quote leaves the quote, as on the web; it used to add lines to it forever. The
    /// script checks that the quote holds only its line and "Draussen<stamp>" follows it.
    func test56_EmptyLineLeavesQuote() {
        let app = launchPage()
        _ = appendBlock(app, editable: "New paragraph doesn't become editable")
        slash(app, "zit", pick: "block-quote")
        var editor = activeEditor(app, "No editor in the quote")
        Thread.sleep(forTimeInterval: 0.6)
        editor.typeText("Innen\(stamp)\n")
        editor = activeEditor(app, "No editor on the quote's second line")
        Thread.sleep(forTimeInterval: 0.6)
        editor.typeText("\n")
        editor = activeEditor(app, "No editor after leaving the quote")
        Thread.sleep(forTimeInterval: 0.6)
        editor.typeText("Draussen\(stamp)")
        snapshot(app, "56-left-quote")
        finishEditing(app)
    }

    /// Long text in the last paragraph: while typing, the caret line stays visible above the keyboard.
    func test14_LongTypingKeepsCaretVisible() {
        let app = launchPage()
        let editor = edit(app, blockContaining: "Nach der Tabelle")
        let done = app.buttons["editor-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Toolbar missing")
        assertOnScreenKeyboard(app)
        Thread.sleep(forTimeInterval: 1.0)
        editor.typeText(String(repeating: " Lange Zeile zum Testen des Cursors.", count: 14))
        Thread.sleep(forTimeInterval: 1.0)
        snapshot(app, "14-long")
        // The caret is at the editor's end, so the editor's bottom edge must lie between navigation bar and toolbar.
        XCTAssertLessThanOrEqual(editor.frame.maxY, done.frame.minY + 4, "Caret line disappears behind the keyboard")
        XCTAssertGreaterThan(editor.frame.maxY, app.navigationBars.firstMatch.frame.maxY + 20, "Caret line is hidden under the navigation bar")
        finishEditing(app)
    }

    /// The on-screen keyboard is up. After hardware key events (`typeKey`) earlier in the same run the simulator
    /// treats a hardware keyboard as connected and hides it; the keyboard checks would then check nothing.
    private func assertOnScreenKeyboard(_ app: XCUIApplication) {
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "No on-screen keyboard: an earlier test in this run sent hardware key events (typeKey)")
    }

    /// How often the keyboard has fully hidden so far (debug counter of the page view).
    private func keyboardHides(_ app: XCUIApplication) -> Int {
        assertOnScreenKeyboard(app)
        let counter = app.staticTexts["debug-keyboard-hides"]
        XCTAssertTrue(counter.waitForExistence(timeout: 5), "Keyboard counter missing")
        return Int(counter.label) ?? -1
    }

    /// Return on an empty task item leaves the list: the item disappears and a paragraph after the list takes the
    /// cursor, without the keyboard hiding.
    func test16_ExitListKeepsKeyboard() {
        let app = launchPage()
        var editor = edit(app, blockContaining: "Aufgabe erledigt")
        Thread.sleep(forTimeInterval: 1.0)
        let hides = keyboardHides(app)
        editor.typeText("\n")
        editor = activeEditor(app, "No editor in the new task item")
        Thread.sleep(forTimeInterval: 0.8)
        editor.typeText("\n")
        Thread.sleep(forTimeInterval: 1.2)
        editor = activeEditor(app, "No editor after leaving the list")
        editor.typeText("Ausstieg\(stamp)")
        snapshot(app, "16-exit-list")
        XCTAssertEqual(keyboardHides(app), hides, "Keyboard hid when leaving the list")
        finishEditing(app)
    }

    /// Return and Backspace in a list item well above the keyboard don't move the page: only a tap centers its block.
    /// Backspace merges the new item back, so the page keeps its content.
    func test59_ReturnKeepsPagePosition() {
        let app = launchPage()
        var editor = edit(app, blockContaining: "Punkt eins")
        Thread.sleep(forTimeInterval: 1.5)
        let heading = app.staticTexts["Überschrift"].firstMatch
        let before = heading.frame.minY
        editor.typeText("\n")
        editor = activeEditor(app, "No editor in the new item")
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(heading.frame.minY, before, accuracy: 1, "Return moved the page")
        editor.typeText(XCUIKeyboardKey.delete.rawValue)
        editor = activeEditor(app, "No editor after Backspace")
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(heading.frame.minY, before, accuracy: 1, "Backspace moved the page")
        finishEditing(app)
    }

    /// A new item starts with a capital, and the keyboard drops the shift after the first letter: typed by tapping
    /// keys, as a person does (`typeText` bypasses the keyboard's own state). Backspace twice leaves the page as it was.
    func test60_NewItemStartsWithCapital() {
        let app = launchPage()
        var editor = edit(app, blockContaining: "Punkt eins")
        Thread.sleep(forTimeInterval: 1.0)
        editor.typeText("\n")
        editor = activeEditor(app, "No editor in the new item")
        Thread.sleep(forTimeInterval: 1.0)
        waitForKeyboard(app)
        XCTAssertTrue(app.keyboards.keys["A"].exists, "The new item doesn't start with a capital")
        app.keyboards.keys["A"].tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(app.keyboards.keys["l"].exists, "The keyboard kept the shift after the first letter")
        editor.typeText(XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue)
        Thread.sleep(forTimeInterval: 1.0)
        finishEditing(app)
    }

    /// With VoiceOver the text is edited in its block, so VoiceOver meets the editor in reading order: after the heading,
    /// before the next block (`DOCMOST_DEBUG_IN_BLOCK` stands in, VoiceOver doesn't run in the simulator). Return and
    /// Backspace work there too; Backspace joins the new item back, so the page keeps its content.
    func test61_VoiceOverEditsInTheBlock() {
        var environment = environment.filter { ["DOCMOST_DEBUG_PAGE", "DOCMOST_DEBUG_SPACE"].contains($0.key) }
        environment["DOCMOST_DEBUG_IN_BLOCK"] = "1"
        let app = launchApp(extraEnvironment: environment)
        waitForSync(app)
        var editor = edit(app, blockContaining: "Punkt eins")
        Thread.sleep(forTimeInterval: 1.0)
        // Earlier tests in the run add to this item. Its editor in the block can still be empty a moment after the tap.
        XCTAssertTrue(waitForText(editor, contains: "Punkt eins"), "The editor doesn't show the item's text")
        let original = editor.value as? String
        let tree = app.debugDescription
        let editorAt = tree.range(of: "'active-editor'")?.lowerBound
        let headingAt = tree.range(of: "label: 'Überschrift'")?.lowerBound
        let nextAt = tree.range(of: "label: 'Checkliste'")?.lowerBound
        XCTAssertTrue(editorAt != nil && headingAt != nil && nextAt != nil, "Editor, heading or checklist missing")
        if let editorAt, let headingAt, let nextAt {
            XCTAssertTrue(headingAt < editorAt && editorAt < nextAt, "The editor isn't in reading order")
        }

        editor.typeText("\n")
        editor = activeEditor(app, "No editor in the new item")
        Thread.sleep(forTimeInterval: 0.8)
        let word = "Block\(stamp)"
        editor.typeText(word)
        XCTAssertEqual(editor.value as? String, word)
        editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: word.count + 1))
        Thread.sleep(forTimeInterval: 1.0)
        editor = activeEditor(app, "No editor after joining the item back")
        XCTAssertEqual(editor.value as? String, original)
        // A code block has its own editor in the block then, too.
        let code = app.staticTexts["let x = 1"].firstMatch
        XCTAssertTrue(scrollTo(code, in: app), "Code block not found")
        code.tap()
        Thread.sleep(forTimeInterval: 1.0)
        editor = activeEditor(app, "No editor in the code block")
        XCTAssertEqual(editor.value as? String, "let x = 1")
        finishEditing(app)
    }

    /// Backspace in an empty paragraph right after a table: the paragraph disappears and the cursor jumps to the end
    /// of the last cell, without the keyboard hiding.
    func test17_BackspaceAfterTableKeepsKeyboard() {
        let app = launchPage()
        _ = edit(app, blockContaining: "b4")
        app.buttons["editor-insert"].tap()
        let paragraph = app.buttons["slash-block-paragraph"]
        XCTAssertTrue(paragraph.waitForExistence(timeout: 5), "“Insert paragraph” missing")
        paragraph.tap()
        var editor = activeEditor(app, "No editor in the new paragraph after the table")
        Thread.sleep(forTimeInterval: 1.2)
        let hides = keyboardHides(app)
        editor.typeText(XCUIKeyboardKey.delete.rawValue)
        Thread.sleep(forTimeInterval: 1.2)
        editor = activeEditor(app, "No editor in the last cell")
        editor.typeText("Zellende\(stamp)")
        snapshot(app, "17-backspace-table")
        XCTAssertEqual(keyboardHides(app), hides, "Keyboard hid on Backspace after the table")
        finishEditing(app)
    }

    /// Find on page via the "…" menu: bottom bar with "n of m", up/down, "Aa" for match case, matches in table cells
    /// and code too. On iPhone the page hides the app's tab bar.
    func test32_FindOnPage() {
        let app = launchPage()
        if UIDevice.current.userInterfaceIdiom == .phone {
            let spacesTab = app.buttons.matching(NSPredicate(format: "label == 'Spaces'")).firstMatch
            XCTAssertFalse(spacesTab.exists && spacesTab.isHittable, "Bottom bar is still visible on the page")
        }
        app.buttons["page-more"].tap()
        let item = button(app, labels: ["Find on Page", "Auf der Seite suchen"])
        XCTAssertTrue(item.waitForExistence(timeout: 5), "“Find on Page” missing from the menu")
        item.tap()
        let field = app.textFields["page-find-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Find bar doesn't appear")
        let matchCase = app.buttons["page-find-case"]
        if matchCase.isSelected { matchCase.tap() }
        let count = app.staticTexts["page-find-count"]

        // Lowercase "absatz" finds "Absatz", at least in "Erster Absatz" and "Letzter Absatz".
        field.typeText("absatz")
        XCTAssertTrue(waitForLabel(count, matching: "^1 (von|of) \\d+$"), "No first match for “absatz”: \(count.label)")
        let total = Int(count.label.split(separator: " ").last ?? "") ?? 0
        XCTAssertGreaterThanOrEqual(total, 2, "Too few matches for “absatz”")
        snapshot(app, "32-find-first")
        app.buttons["page-find-next"].tap()
        XCTAssertTrue(waitForLabel(count, matching: "^2 (von|of) \(total)$"), "“Next” doesn't go to the second match: \(count.label)")
        app.buttons["page-find-previous"].tap()
        XCTAssertTrue(waitForLabel(count, matching: "^1 (von|of) \(total)$"), "“Previous” doesn't go to the first match: \(count.label)")

        matchCase.tap()
        XCTAssertTrue(waitForLabel(count, matching: "^(Keine Treffer|No matches)$"), "“Aa” doesn't match case: \(count.label)")
        matchCase.tap()
        XCTAssertTrue(waitForLabel(count, matching: "^1 (von|of) \(total)$"), "Matches don't come back without “Aa”")

        // A table cell match scrolls into view between the navigation bar and the find bar.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10) + "ZeileVier")
        XCTAssertTrue(waitForLabel(count, matching: "^1 (von|of) 1$"), "“ZeileVier” not found in the table: \(count.label)")
        Thread.sleep(forTimeInterval: 1.0)
        let cell = app.staticTexts.matching(NSPredicate(format: "label == 'ZeileVier'")).firstMatch
        XCTAssertTrue(cell.exists, "Table cell missing")
        XCTAssertGreaterThanOrEqual(cell.frame.minY, app.navigationBars.firstMatch.frame.maxY - 1, "Match is under the navigation bar")
        XCTAssertLessThanOrEqual(cell.frame.maxY, field.frame.minY, "Match is behind the find bar")
        snapshot(app, "32-find-table")

        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12) + "let x")
        XCTAssertTrue(waitForLabel(count, matching: "^1 (von|of) 1$"), "“let x” not found in the code: \(count.label)")

        app.buttons["page-find-done"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Find bar stays open after “Done”")
    }

    /// Comments button at the top: write, edit, resolve, reopen and delete a page comment. Then comment on a selected
    /// word via the selection menu (the script checks it and its mark); tapping the marked text opens the comment.
    func test33_Comments() {
        let app = launchPage()
        let commentsButton = app.buttons["page-comments"]
        XCTAssertTrue(commentsButton.waitForExistence(timeout: 10), "Comments button missing")
        commentsButton.tap()
        let composer = element(app, "comments-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Comments sheet doesn't open")

        // Test-Kollegin's reply (seed-notifications.py): as a space admin the admin may delete it, as on the web, but
        // not edit it. The menu is only looked at, then closed.
        let reply = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'comment-'"))
            .containing(NSPredicate(format: "label == 'Nachtrag der Kollegin'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "Test-Kollegin's reply missing")
        let replyMenu = app.buttons["comment-menu-\(reply.identifier.dropFirst("comment-".count))"]
        XCTAssertTrue(replyMenu.waitForExistence(timeout: 5), "A space admin gets no “…” on someone else's reply")
        replyMenu.tap()
        XCTAssertTrue(button(app, labels: ["Delete", "Löschen"]).waitForExistence(timeout: 5), "No “Delete” for a space admin")
        XCTAssertFalse(button(app, labels: ["Edit", "Bearbeiten"]).exists, "Someone else's reply offers “Edit”")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(button(app, labels: ["Delete", "Löschen"]).waitForNonExistence(timeout: 5), "The menu doesn't close")

        let text = "Seitenkommentar\(stamp)"
        composer.tap()
        composer.typeText(text)
        app.buttons["comments-send"].tap()
        let written = app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
        XCTAssertTrue(written.waitForExistence(timeout: 10), "New comment doesn't appear")
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'comment-'"))
            .containing(NSPredicate(format: "label == %@", text)).firstMatch
        let commentId = String(row.identifier.dropFirst("comment-".count))
        let menu = app.buttons["comment-menu-\(commentId)"]
        func choose(_ labels: [String]) {
            XCTAssertTrue(menu.waitForExistence(timeout: 5), "Comment menu missing")
            menu.tap()
            let item = button(app, labels: labels)
            XCTAssertTrue(item.waitForExistence(timeout: 5), "“\(labels.last ?? "")” missing from the comment menu")
            item.tap()
        }

        choose(["Edit", "Bearbeiten"])
        composer.typeText(" geändert")
        app.buttons["comments-send"].tap()
        let edited = app.staticTexts.matching(NSPredicate(format: "label == %@", text + " geändert")).firstMatch
        XCTAssertTrue(edited.waitForExistence(timeout: 10), "Edited comment doesn't appear")
        snapshot(app, "33-comment-edited")

        choose(["Resolve", "Als erledigt markieren"])
        XCTAssertTrue(edited.waitForNonExistence(timeout: 10), "Resolved comment stays under “Open”")
        let resolvedTab = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Erledigt' OR label BEGINSWITH 'Resolved'")).firstMatch
        resolvedTab.tap()
        XCTAssertTrue(edited.waitForExistence(timeout: 5), "Comment missing under “Resolved”")
        snapshot(app, "33-comment-resolved")
        choose(["Reopen", "Wieder öffnen"])
        let openTab = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Offen' OR label BEGINSWITH 'Open'")).firstMatch
        openTab.tap()
        XCTAssertTrue(edited.waitForExistence(timeout: 10), "Reopened comment missing under “Open”")

        let menuFrame = menu.frame
        choose(["Delete", "Löschen"])
        assertPopover(app, at: menuFrame)
        let confirm = button(app, labels: ["Delete", "Löschen"])
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Delete confirmation missing")
        confirm.tap()
        XCTAssertTrue(edited.waitForNonExistence(timeout: 10), "Deleted comment remains")
        tapSheetBarButton(app.buttons["comments-done"], in: element(app, "comments-sheet"))

        // Inline comment: double-tap the first word on the first line (earlier tests make the paragraph wrap).
        let editor = edit(app, blockContaining: "Erster Absatz")
        editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 14, dy: 12)).doubleTap()
        let commentItem = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Comment", "Kommentieren"])).firstMatch
        XCTAssertTrue(commentItem.waitForExistence(timeout: 5), "“Comment” missing from the selection menu")
        snapshot(app, "33-selection-menu")
        commentItem.tap()
        let inlineText = element(app, "inline-comment-text")
        XCTAssertTrue(inlineText.waitForExistence(timeout: 5), "Sheet for the inline comment doesn't open")
        let quote = app.staticTexts["inline-comment-quote"].label
        XCTAssertFalse(quote.isEmpty, "Sheet doesn't show the selected passage")
        inlineText.typeText("Inline\(stamp)")
        app.buttons["inline-comment-send"].tap()
        XCTAssertTrue(inlineText.waitForNonExistence(timeout: 10), "Sheet doesn't close after sending")
        finishEditing(app)

        let marked = app.links.matching(NSPredicate(format: "label == %@", quote)).firstMatch
        XCTAssertTrue(marked.waitForExistence(timeout: 10), "Marked passage isn't tappable")
        marked.tap()
        let inlineComment = app.staticTexts.matching(NSPredicate(format: "label == %@", "Inline\(stamp)")).firstMatch
        XCTAssertTrue(inlineComment.waitForExistence(timeout: 10), "Tapping the passage doesn't open its comment")
        snapshot(app, "33-inline-comment")
        tapSheetBarButton(app.buttons["comments-done"], in: element(app, "comments-sheet"))
    }

    /// Links leave the app as from the web client in a browser (the last paragraph of Tools/editor-test-page.json): a
    /// web page in the in-app browser, another app only after asking (none opens this one, which the app says), a
    /// script never. "Open in Browser" from the page menu and a link in Test-Kollegin's reply (seed-notifications.py)
    /// open in the in-app browser too, the latter over the comments.
    func test64_LinksLeaveTheAppAsInABrowser() {
        let app = launchPage()
        let close = browserCloseButton(app)
        app.buttons["page-more"].tap()
        let openInBrowser = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", ["Open in Browser", "Im Browser öffnen"])).firstMatch
        XCTAssertTrue(openInBrowser.waitForExistence(timeout: 5), "“Open in Browser” missing from the page menu")
        openInBrowser.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 10), "“Open in Browser” doesn't open the in-app browser")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5), "The in-app browser doesn't close")

        let web = app.links["Beispielseite"]
        XCTAssertTrue(scrollTo(web, in: app), "Web link missing")
        web.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 10), "The web link doesn't open the in-app browser")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5), "The in-app browser doesn't close")

        app.links["Fremde App"].tap()
        let question = app.alerts.firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 5), "A link to another app opens without asking")
        XCTAssertTrue(question.staticTexts["diderot-uitest://open"].exists, "The question doesn't show the address")
        snapshot(app, "64-other-app")
        question.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "Öffnen"])).firstMatch.tap()
        let notice = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["No app can open this link.", "Keine App kann diesen Link öffnen."])).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "Nothing says that no app could open the link")

        app.links["Skript"].tap()
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2), "A script link offers to open")
        XCTAssertFalse(close.exists, "A script link opens the in-app browser")

        app.buttons["page-comments"].tap()
        let source = app.links["Quelle"]
        XCTAssertTrue(source.waitForExistence(timeout: 10), "Link in Test-Kollegin's reply missing")
        source.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 10), "A web link in a comment doesn't open the in-app browser")
        snapshot(app, "64-comment-link")
        close.tap()
        XCTAssertTrue(element(app, "comments-composer").waitForExistence(timeout: 5), "The comments close with the browser")
        tapSheetBarButton(app.buttons["comments-done"], in: element(app, "comments-sheet"))
    }

    /// The web layout shows the page's HTML and stays on it: a link there opens as on the page (a web page in the
    /// in-app browser), not inside the web view.
    func test66_WebLayoutStaysOnThePage() {
        let app = launchPage()
        func toggleWebLayout() {
            app.buttons["page-more"].tap()
            let toggle = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Web Layout", "Web-Layout"])).firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), "“Web Layout” missing from the page menu")
            toggle.tap()
        }
        toggleWebLayout()
        let link = app.webViews.links["Beispielseite"]
        XCTAssertTrue(link.waitForExistence(timeout: 20), "The web layout doesn't show the page's links")
        for _ in 0..<6 where !link.isHittable { app.webViews.firstMatch.swipeUp() }
        snapshot(app, "66-web-layout")
        link.tap()
        let close = browserCloseButton(app)
        XCTAssertTrue(close.waitForExistence(timeout: 10), "A link in the web layout doesn't open the in-app browser")
        close.tap()
        XCTAssertTrue(link.waitForExistence(timeout: 5), "The web layout left the page")
        toggleWebLayout()
    }

    /// The web editor loads Docmost's editor from the server and stays there: opening a link from its popover goes
    /// to the in-app browser over the editor, not into it.
    func test67_WebEditorStaysOnTheServer() {
        let app = launchPage()
        app.buttons["page-more"].tap()
        let edit = button(app, labels: ["Edit in Web Editor", "Im Web-Editor bearbeiten"])
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "“Edit in Web Editor” missing from the page menu")
        edit.tap()
        let link = app.webViews.links["Beispielseite"]
        XCTAssertTrue(link.waitForExistence(timeout: 40), "The web editor doesn't show the page")
        // By its frame: for a link below the screen, `isHittable` can fail the test instead of answering (“Activation
        // point invalid”).
        func onScreen() -> Bool {
            let frame = link.frame
            return !frame.isEmpty && app.windows.firstMatch.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        for _ in 0..<8 where !onScreen() { app.webViews.firstMatch.swipeUp() }
        // Its popover opens below it: lift it into the upper half, clear of WebKit's bar above the keyboard. The keyboard
        // folding in or out (`waitForKeyboard`) moves the page again, so until it stays there.
        let middle = app.windows.firstMatch.frame.midY
        for _ in 0..<4 {
            let frame = link.frame
            Thread.sleep(forTimeInterval: 0.3)
            if link.frame == frame, frame.midY <= middle { break }
            guard link.frame.midY > middle else { continue }
            let start = app.webViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let shift = max(-300, middle * 0.6 - link.frame.midY)
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: shift)), withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        link.tap()
        // The popover's link shows its address (twice in the tree: the link and its text).
        let open = app.webViews.links["https://example.com/diderot-uitest"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5), "The link's popover doesn't open in the web editor")
        snapshot(app, "67-web-editor-link")
        open.tap()
        let close = browserCloseButton(app)
        // A tap while the page moves misses the popover's link.
        if !close.waitForExistence(timeout: 3), open.exists { open.tap() }
        XCTAssertTrue(close.waitForExistence(timeout: 10), "A link opened in the web editor doesn't use the in-app browser")
        close.tap()
        XCTAssertTrue(link.waitForExistence(timeout: 5), "The web editor left the page")
        tapSheetBarButton(button(app, labels: ["Done", "Fertig"]), in: app.webViews.firstMatch)
    }

    /// A callout grows with its text while editing. The block's hidden copy of the text hyphenated long German words
    /// and broke lines earlier than the editor, so the typed text hung out of the box.
    func test68_CalloutGrowsWithItsText() {
        let app = launchPage()
        _ = appendParagraph(app)
        slash(app, "hinweis", pick: "block-callout")
        let editor = activeEditor(app)
        Thread.sleep(forTimeInterval: 0.8)
        editor.typeText("Hinweis\(stamp): Donaudampfschifffahrtsgesellschaftskapitän und Rechtsschutzversicherungsgesellschaften "
            + "sind lange Wörter, die anders umbrechen als kurze. Noch ein Satz, damit die Box mehrere Zeilen hoch wird.")
        Thread.sleep(forTimeInterval: 1.0)
        let box = app.otherElements.matching(NSPredicate(format: "label ENDSWITH[c] 'callout' OR label ENDSWITH 'Hinweis'")).firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 5), "Callout missing")
        snapshot(app, "68-callout-long-text")
        XCTAssertLessThanOrEqual(editor.frame.maxY, box.frame.maxY + 1, "Text hangs out of the callout: editor \(editor.frame), box \(box.frame)")
        finishEditing(app)
    }

    /// A version opened from "Page History" loads its media like the page itself: the image of "Fixture: Media"
    /// (Tools/seed-fixtures.py, which leaves a version with the image) appears instead of a spinner.
    func test49_HistoryVersionShowsImage() throws {
        let app = openFixture("Fixture: Media")
        app.buttons["page-more"].tap()
        let history = button(app, labels: ["Page History", "Seitenverlauf"])
        XCTAssertTrue(history.waitForExistence(timeout: 5), "Page menu shows no “Page History”")
        history.tap()
        // The page behind the sheet has no list rows.
        let version = app.cells.firstMatch
        // A fresh dev instance: the server saves the first version about 5 minutes after Tools/seed-fixtures.py.
        guard version.waitForExistence(timeout: 20) else {
            throw XCTSkip("“Fixture: Media” has no version yet; the server saves one about 5 minutes after seeding")
        }
        version.tap()
        // Only inside the version: the page behind the sheet shows the same image.
        let header = NSPredicate(format: "label BEGINSWITH 'Version from' OR label BEGINSWITH 'Version vom'")
        let image = app.scrollViews.containing(header).buttons["Gradient test image"]
        let loaded = image.waitForExistence(timeout: 20)
        snapshot(app, "49-version")
        XCTAssertTrue(loaded, "Image in the version doesn't load")
    }

    /// A tap on an image opens it full screen with the page's other images and diagrams, as the web's lightbox: it
    /// offers sharing once loaded, swipes to the next and closes when pulled down.
    func test81_ImageViewer() {
        let app = openFixture("Fixture: Media")
        let image = app.buttons["Gradient test image"]
        XCTAssertTrue(image.waitForExistence(timeout: 20), "Image on the page doesn't load")
        image.tap()
        let counter = app.staticTexts["media-viewer-counter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 5), "The image doesn't open full screen")
        // "1 of 6", "1 von 6".
        func shown() -> (number: Int, total: Int) {
            let numbers = counter.label.split(separator: " ").compactMap { Int($0) }
            return numbers.count == 2 ? (numbers[0], numbers[1]) : (0, 0)
        }
        XCTAssertEqual(shown().number, 1, "The viewer doesn't begin with the tapped image: \(counter.label)")
        XCTAssertGreaterThanOrEqual(shown().total, 2, "The viewer doesn't hold the page's other images: \(counter.label)")
        let share = app.buttons["media-viewer-share"]
        XCTAssertTrue(share.waitForExistence(timeout: 20), "The image doesn't load full screen")
        snapshot(app, "81-viewer")

        app.swipeLeft()
        let second = NSPredicate { _, _ in shown().number == 2 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: second, object: nil)], timeout: 5), .completed,
                       "Swiping doesn't show the next image: \(counter.label)")
        // The fixture's second image is the same file: it shows once loaded, then a pull closes the viewer.
        XCTAssertTrue(share.waitForExistence(timeout: 20), "The second image doesn't load")
        app.swipeDown()
        XCTAssertTrue(counter.waitForNonExistence(timeout: 5), "Pulling down doesn't close the viewer")
        XCTAssertTrue(image.waitForExistence(timeout: 5), "The page doesn't show again")
    }

    // MARK: - Insert ("/" and "+")

    /// New block at the page end via the floating "+", where it doesn't disturb the other tests.
    @discardableResult
    private func appendBlock(_ app: XCUIApplication, labels: [String] = ["Paragraph", "Absatz"],
                             missing: String = "Menu item “Paragraph” missing", editable: String = "No active editor") -> XCUIElement {
        let add = app.buttons["page-add-block"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "“+” button missing")
        add.tap()
        let item = button(app, labels: labels)
        XCTAssertTrue(item.waitForExistence(timeout: 5), missing)
        item.tap()
        return activeEditor(app, timeout: 10, editable)
    }

    /// Empty paragraph at the page end via the floating "+".
    private func appendParagraph(_ app: XCUIApplication) -> XCUIElement {
        let editor = appendBlock(app)
        Thread.sleep(forTimeInterval: 0.6)
        return editor
    }

    @discardableResult
    private func activeEditor(_ app: XCUIApplication, timeout: TimeInterval = 8, _ message: String = "No active editor") -> XCUIElement {
        let editor = app.textViews["active-editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: timeout), message)
        return editor
    }

    /// Types "/<query>" in the active paragraph and picks the entry.
    private func slash(_ app: XCUIApplication, _ query: String, pick id: String) {
        activeEditor(app).typeText("/" + query)
        let item = app.buttons["slash-\(id)"]
        XCTAssertTrue(item.waitForExistence(timeout: 8), "Slash menu doesn't show “\(id)” for “/\(query)”")
        item.tap()
    }

    /// Waits until the sheet closes and the editor has the keyboard again (slow on a real device).
    private func editorAfterSheet(_ app: XCUIApplication, closing field: XCUIElement) -> XCUIElement {
        XCTAssertTrue(field.waitForNonExistence(timeout: 8), "Sheet doesn't close")
        return focusedEditor(app)
    }

    /// The active editor, once it has keyboard focus.
    private func focusedEditor(_ app: XCUIApplication) -> XCUIElement {
        let editor = activeEditor(app)
        let focused = NSPredicate { _, _ in (editor.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: nil)], timeout: 5), .completed,
                       "Editor doesn't get the keyboard back")
        return editor
    }

    /// Element with one of the labels (German or English UI).
    private func labeled(_ app: XCUIApplication, _ labels: [String]) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    /// "/" lists every web editor entry (scrollable, including diagrams and embeds) and filters while typing; Return
    /// picks the first match: "/trenn" + Return inserts a divider, then typing continues in a new paragraph.
    func test34_InsertMenuListsWebCommands() {
        let app = launchPage()
        let editor = appendParagraph(app)
        editor.typeText("/")
        let first = app.buttons["slash-block-paragraph"]
        XCTAssertTrue(first.waitForExistence(timeout: 8), "Slash menu doesn't appear")
        for id in ["block-divider", "page-break", "subpages", "footnote", "synced-block", "columns-5", "math-block", "mermaid",
                   "drawio", "excalidraw", "status", "emoji", "date", "embed-youtube", "embed-gsheets"] {
            XCTAssertTrue(app.buttons["slash-\(id)"].exists, "Slash menu doesn't contain “\(id)”")
        }
        snapshot(app, "34-menu")
        // The list scrolls to its last entry (Google Sheets).
        let last = app.buttons["slash-embed-gsheets"]
        // Drag up inside the list along a fixed path just below where the first row started.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: first.frame.midX, dy: first.frame.maxY + 120))
        let end = origin.withOffset(CGVector(dx: first.frame.midX, dy: first.frame.maxY + 10))
        for _ in 0..<15 where !last.isHittable {
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(last.isHittable, "End of the list isn't reachable")
        snapshot(app, "34-menu-end")

        editor.typeText("trenn")
        XCTAssertTrue(app.buttons["slash-block-divider"].waitForExistence(timeout: 5), "“/trenn” doesn't find the divider")
        XCTAssertFalse(app.buttons["slash-block-paragraph"].exists, "Filter keeps “Paragraph”")
        editor.typeText("\n")
        let next = activeEditor(app)
        Thread.sleep(forTimeInterval: 0.8)
        next.typeText("NachTrenn\(stamp)")
        snapshot(app, "34-divider")
        finishEditing(app)
    }

    /// Inline entries mid-text: date, time, status (sheet), inline math (sheet), emoji (emoji keyboard) and footnote;
    /// then edit the footnote text via its number and the status color by tapping the status.
    func test35_InlineCommands() {
        let app = launchPage()
        var editor = appendParagraph(app)
        editor.typeText("Inline\(stamp) ")
        slash(app, "datum", pick: "date")
        activeEditor(app).typeText(" ")
        slash(app, "uhrzeit", pick: "time")
        activeEditor(app).typeText(" ")

        slash(app, "status", pick: "status")
        let statusText = app.textFields["status-text"]
        XCTAssertTrue(statusText.waitForExistence(timeout: 5), "Status sheet doesn't open")
        statusText.typeText("Offen\(stamp)")
        app.buttons["status-color-green"].tap()
        snapshot(app, "35-status-sheet")
        app.buttons["status-apply"].tap()
        editor = editorAfterSheet(app, closing: statusText)
        editor.typeText(" ")

        slash(app, "mathi", pick: "math-inline")
        let latex = element(app, "math-latex")
        XCTAssertTrue(latex.waitForExistence(timeout: 5), "Math sheet doesn't open")
        latex.typeText("x^2")
        app.buttons["math-apply"].tap()
        editor = editorAfterSheet(app, closing: latex)
        editor.typeText(" ")

        slash(app, "emoji", pick: "emoji")
        let emojiField = app.textFields["insert-emoji-field"]
        XCTAssertTrue(emojiField.waitForExistence(timeout: 5), "Emoji keyboard doesn't open")
        Thread.sleep(forTimeInterval: 1.0)
        emojiField.typeText("🎉")
        editor = focusedEditor(app)
        editor.typeText("Fest\(stamp) ")

        slash(app, "fussn", pick: "footnote")
        Thread.sleep(forTimeInterval: 0.6)
        activeEditor(app).typeText(" Ende\(stamp)")
        snapshot(app, "35-inline")
        finishEditing(app)

        // Tapping the footnote number jumps to its text at the page end.
        let reference = app.links.matching(NSPredicate(format: "label CONTAINS '[1]'")).firstMatch
        XCTAssertTrue(reference.waitForExistence(timeout: 10), "Footnote reference missing")
        reference.tap()
        editor = activeEditor(app)
        Thread.sleep(forTimeInterval: 0.8)
        editor.typeText("Quelle\(stamp)")
        XCTAssertTrue(app.buttons["editor-delete"].exists, "Toolbar missing")
        XCTAssertFalse(app.buttons["editor-code-block"].exists, "Footnote text offers a code block")
        snapshot(app, "35-footnote")
        finishEditing(app)

        let status = app.links.matching(NSPredicate(format: "label CONTAINS %@", "Offen\(stamp)")).firstMatch
        XCTAssertTrue(scrollTo(status, in: app), "Status isn't tappable")
        status.tap()
        XCTAssertTrue(app.textFields["status-text"].waitForExistence(timeout: 5), "Tapping the status doesn't open a sheet")
        app.buttons["status-color-red"].tap()
        app.buttons["status-apply"].tap()
        Thread.sleep(forTimeInterval: 1.0)
    }

    /// Blocks via "/": subpages, page break, math block (sheet), Draw.io placeholder, YouTube embed (an invalid link is
    /// rejected as on the web) and Mermaid as a code block.
    func test36_BlockCommands() {
        let app = launchPage()
        _ = appendParagraph(app)
        slash(app, "unterseit", pick: "subpages")
        _ = activeEditor(app)
        Thread.sleep(forTimeInterval: 0.8)
        slash(app, "seitenum", pick: "page-break")
        _ = activeEditor(app)
        Thread.sleep(forTimeInterval: 0.8)

        slash(app, "matheb", pick: "math-block")
        let latex = element(app, "math-latex")
        XCTAssertTrue(latex.waitForExistence(timeout: 5), "Math sheet doesn't open")
        latex.typeText("a^2+b^2=c^2")
        app.buttons["math-apply"].tap()
        _ = editorAfterSheet(app, closing: latex)

        slash(app, "drawio", pick: "drawio")
        XCTAssertTrue(app.buttons["diagram-placeholder"].waitForExistence(timeout: 8), "Draw.io placeholder missing")
        _ = activeEditor(app)
        Thread.sleep(forTimeInterval: 0.8)

        slash(app, "youtube", pick: "embed-youtube")
        let link = app.textFields["embed-link"]
        XCTAssertTrue(link.waitForExistence(timeout: 5), "Embed link sheet doesn't open")
        link.typeText("https://example.com/video")
        app.buttons["embed-apply"].tap()
        let invalid = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'YouTube' AND (label CONTAINS 'Ungültig' OR label CONTAINS 'Invalid')")).firstMatch
        XCTAssertTrue(invalid.waitForExistence(timeout: 5), "Invalid YouTube link isn't rejected")
        snapshot(app, "36-embed-invalid")
        link.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30) + "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        app.buttons["embed-apply"].tap()
        _ = editorAfterSheet(app, closing: link)

        slash(app, "mermaid", pick: "mermaid")
        Thread.sleep(forTimeInterval: 1.0)
        snapshot(app, "36-mermaid")
        app.buttons["editor-done"].tap()
        Thread.sleep(forTimeInterval: 1.0)

        let editor = appendParagraph(app)
        editor.typeText("NachBloecken\(stamp)")
        snapshot(app, "36-blocks")
        finishEditing(app)
    }

    /// "/spalten": two columns, cursor in the first; the column bar switches to three; tap and type in the second.
    func test37_Columns() {
        let app = launchPage()
        _ = appendParagraph(app)
        slash(app, "spalten", pick: "columns-2")
        var editor = activeEditor(app)
        Thread.sleep(forTimeInterval: 0.8)
        editor.typeText("Links\(stamp)")
        let three = app.buttons["columns-count-3"]
        XCTAssertTrue(three.waitForExistence(timeout: 5), "Column bar missing")
        snapshot(app, "37-two-columns")
        three.tap()
        let legend = labeled(app, ["Spalte 2 von 3", "Column 2 of 3"])
        XCTAssertTrue(legend.waitForExistence(timeout: 8), "Third column isn't added")
        snapshot(app, "37-three-columns")
        legend.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: 24)).tap()
        editor = activeEditor(app)
        Thread.sleep(forTimeInterval: 0.8)
        editor.typeText("Mitte\(stamp)")
        snapshot(app, "37-second-column")
        finishEditing(app)
    }

    /// Synced block: create and fill it, copy it, embed it in another paragraph via "Paste" and via "/"; also turn a
    /// paragraph into a synced block via "Text ▾".
    func test38_SyncedBlocks() {
        let app = launchPage()
        _ = appendParagraph(app)
        slash(app, "synchron", pick: "synced-block")
        var editor = activeEditor(app)
        Thread.sleep(forTimeInterval: 0.8)
        editor.typeText("Sync\(stamp)")
        finishEditing(app)
        Thread.sleep(forTimeInterval: 1.0)

        let menu = app.buttons["synced-block-menu"].firstMatch
        XCTAssertTrue(scrollTo(menu, in: app), "Synced block menu missing")
        menu.tap()
        let copy = labeled(app, ["Copy Synced Block", "Synchronisierten Block kopieren"])
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "“Copy” missing from the menu")
        copy.tap()
        Thread.sleep(forTimeInterval: 1.0)

        editor = appendParagraph(app)
        // Tapping the cursor shows the edit menu; otherwise ⌘V (both trigger the same paste).
        editor.tap()
        let paste = labeled(app, ["Paste", "Einsetzen"])
        if paste.waitForExistence(timeout: 3) {
            paste.tap()
        } else {
            editor.typeKey("v", modifierFlags: .command)
        }
        let reference = app.buttons["synced-reference-menu"].firstMatch
        XCTAssertTrue(reference.waitForExistence(timeout: 10), "Pasted synced block doesn't appear")
        snapshot(app, "38-pasted")
        Thread.sleep(forTimeInterval: 0.8)
        if app.textViews["active-editor"].exists { finishEditing(app) }

        _ = appendParagraph(app)
        slash(app, "einsetz", pick: "paste-synced-block")
        let references = app.buttons.matching(identifier: "synced-reference-menu")
        let two = expectation(for: NSPredicate(format: "count >= 2"), evaluatedWith: references)
        wait(for: [two], timeout: 10)
        if app.textViews["active-editor"].exists { finishEditing(app) }

        editor = appendParagraph(app)
        editor.typeText("Wrap\(stamp)")
        app.buttons["editor-block-type"].tap()
        let wrap = app.buttons["type-synced-block"]
        XCTAssertTrue(wrap.waitForExistence(timeout: 5), "“Synced block” missing under “Text”")
        wrap.tap()
        editor = activeEditor(app)
        Thread.sleep(forTimeInterval: 0.6)
        editor.typeText(" weiter")
        snapshot(app, "38-wrapped")
        finishEditing(app)
    }

    /// "+" in the keyboard toolbar opens the insert menu below the block (heading after it); the floating "+" groups
    /// all entries (date under "In the Text", database).
    func test39_PlusMenusAndDatabase() {
        let app = launchPage()
        var editor = appendParagraph(app)
        editor.typeText("Plus\(stamp)")
        app.buttons["editor-insert"].tap()
        let heading = app.buttons["slash-block-heading2"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5), "“+” doesn't show the insert list")
        snapshot(app, "39-plus-list")
        heading.tap()
        editor = activeEditor(app)
        Thread.sleep(forTimeInterval: 0.8)
        editor.typeText("PlusH2\(stamp)")
        finishEditing(app)

        // Floating "+" → In the Text → Date: a new paragraph with the date at the page end.
        app.buttons["page-add-block"].tap()
        let inText = labeled(app, ["In the Text", "Im Text"])
        XCTAssertTrue(inText.waitForExistence(timeout: 5), "Group “In the Text” missing")
        inText.tap()
        let date = labeled(app, ["Date", "Datum"])
        XCTAssertTrue(date.waitForExistence(timeout: 5), "“Date” missing")
        date.tap()
        editor = activeEditor(app)
        Thread.sleep(forTimeInterval: 0.8)
        editor.typeText(" FabDatum\(stamp)")
        finishEditing(app)

        app.buttons["page-add-block"].tap()
        let more = labeled(app, ["More Blocks", "Weitere Blöcke"])
        XCTAssertTrue(more.waitForExistence(timeout: 5), "Group “More Blocks” missing")
        more.tap()
        let database = labeled(app, ["Database (inline)", "Datenbank (inline)"])
        XCTAssertTrue(database.waitForExistence(timeout: 5), "“Database (inline)” missing")
        database.tap()
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'base-embed-' AND identifier != 'base-embed-'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "Embedded database doesn't appear")
        snapshot(app, "39-database")
        if app.textViews["active-editor"].exists { finishEditing(app) }
    }

    /// "/code", pick "swift" in the language bar, type: the script checks that committing the text keeps the language.
    func test40_CodeBlockLanguage() {
        let app = launchPage()
        _ = appendParagraph(app)
        slash(app, "code", pick: "block-codeBlock")
        let swift = app.buttons["swift"]
        XCTAssertTrue(swift.waitForExistence(timeout: 8), "Language bar missing")
        swift.tap()
        Thread.sleep(forTimeInterval: 0.6)
        app.typeText("Sprache\(stamp)")
        Thread.sleep(forTimeInterval: 1.2)
        snapshot(app, "40-code-language")
        finishEditing(app)
    }

    /// From text into a code block and back: the page's one editor edits both, and the keyboard stays up.
    func test63_SwitchBetweenTextAndCode() {
        let app = launchPage()
        var editor = edit(app, blockContaining: "Letzter Absatz")
        Thread.sleep(forTimeInterval: 1.0)
        let hides = keyboardHides(app)
        let code = app.staticTexts["let x = 1"].firstMatch
        XCTAssertTrue(scrollTo(code, in: app), "Code block not found")
        code.tap()
        Thread.sleep(forTimeInterval: 1.0)
        editor = activeEditor(app, "No editor in the code block")
        XCTAssertEqual(editor.value as? String, "let x = 1")
        let paragraph = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Letzter Absatz")).firstMatch
        XCTAssertTrue(scrollTo(paragraph, in: app), "Paragraph not found")
        paragraph.tap()
        Thread.sleep(forTimeInterval: 1.0)
        editor = activeEditor(app, "No editor back in the paragraph")
        XCTAssertTrue((editor.value as? String)?.contains("Letzter Absatz") == true, "The editor doesn't show the paragraph")
        XCTAssertEqual(keyboardHides(app), hides, "The keyboard hid between text and code")
        finishEditing(app)
    }

    /// Toggle via "/toggle": type a title, tap into the content below it and keep typing past the sync. The editor
    /// stays open; the script checks that the text is in the toggle's content, not in its title.
    func test41_ToggleContent() {
        let app = launchPage()
        _ = appendParagraph(app)
        slash(app, "toggle", pick: "block-toggle")
        var editor = activeEditor(app)
        Thread.sleep(forTimeInterval: 0.8)
        editor.typeText("Klapp\(stamp)")
        finishEditing(app)
        let title = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Klapp\(stamp)")).firstMatch
        XCTAssertTrue(scrollTo(title, in: app), "Toggle title missing")
        // The empty content paragraph sits right below the title.
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: 30)).tap()
        editor = activeEditor(app)
        Thread.sleep(forTimeInterval: 0.6)
        editor.typeText("Inhalt\(stamp)")
        // Past the commit (400 ms) and the engine's document update.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(editor.exists, "Editor closes after the sync")
        editor.typeText(" weiter")
        snapshot(app, "41-toggle-content")
        finishEditing(app)
    }

    /// Leave the page without closing it (the space chip pushes the space on top), go back and type: the page
    /// reconnects ("Saved") and the script finds "Erneut<stamp>" on the server.
    func test42_EditAfterReturningToPage() {
        let app = launchPage()
        let space = app.buttons["page-space"]
        XCTAssertTrue(space.waitForExistence(timeout: 10), "Space chip missing")
        space.tap()
        XCTAssertTrue(app.textFields["space-search"].waitForExistence(timeout: 20), "Space doesn't open from the page")
        backButton(app).tap()
        waitForSync(app)
        let editor = edit(app, blockContaining: "Punkt eins")
        editor.typeText(" Erneut\(stamp)")
        snapshot(app, "42-typed")
        finishEditing(app)
        let shown = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Erneut\(stamp)")).firstMatch
        XCTAssertTrue(shown.waitForExistence(timeout: 5), "Reader doesn't show the typed text after going back")
    }

    /// The toggle title's toolbar offers no block type or Duplicate (both would split the toggle). Return after the
    /// title moves to the content, keeping the keyboard; the script expects one toggle with "Zeile<stamp>" as content.
    func test43_ReturnInToggleTitle() {
        let app = launchPage()
        _ = appendParagraph(app)
        slash(app, "toggle", pick: "block-toggle")
        var editor = activeEditor(app)
        Thread.sleep(forTimeInterval: 0.8)
        editor.typeText("Titel\(stamp)")
        XCTAssertTrue(app.buttons["editor-delete"].exists, "Toolbar missing")
        XCTAssertFalse(app.buttons["editor-block-type"].exists, "Toggle title offers block types")
        XCTAssertFalse(app.buttons["editor-duplicate"].exists, "Toggle title offers Duplicate")
        let hides = keyboardHides(app)
        editor.typeText("\n")
        Thread.sleep(forTimeInterval: 1.2)
        editor = activeEditor(app, "No editor after Return in the toggle title")
        editor.typeText("Zeile\(stamp)")
        snapshot(app, "43-toggle-return")
        XCTAssertEqual(keyboardHides(app), hides, "Keyboard hid after Return in the toggle title")
        finishEditing(app)
    }

    /// Bullet list via "/bullet" with two items: Backspace at the start of the second joins it into the first; the
    /// script checks that the list holds only "Oben<stamp>Unten<stamp>".
    func test44_BackspaceJoinsListItems() {
        let app = launchPage()
        _ = appendParagraph(app)
        slash(app, "bullet", pick: "block-bulletList")
        var editor = activeEditor(app)
        Thread.sleep(forTimeInterval: 0.8)
        editor.typeText("Oben\(stamp)\n")
        Thread.sleep(forTimeInterval: 1.2)
        editor = activeEditor(app, "No editor in the second item")
        let second = "Unten\(stamp)"
        editor.typeText(second)
        // To the item's start with a tap left of its text, as on a phone: of eleven ← keys, one sometimes got lost
        // while iOS hid and brought back the on-screen keyboard after the first (⌘← never reaches the editor).
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 2, dy: 0)).tap()
        Thread.sleep(forTimeInterval: 0.6)
        editor.typeText(XCUIKeyboardKey.delete.rawValue)
        Thread.sleep(forTimeInterval: 1.2)
        snapshot(app, "44-list-join")
        finishEditing(app)
        XCTAssertTrue(app.staticTexts["Oben\(stamp)\(second)"].waitForExistence(timeout: 5), "Items aren't joined")
    }

    /// Toggle via "/toggle" with a line in its content: collapsing it while that line is edited ends editing and hides
    /// the line; the script checks that the toggle is stored closed (`open: false`), as on the web.
    func test45_CollapseToggle() {
        let app = launchPage()
        _ = appendParagraph(app)
        slash(app, "toggle", pick: "block-toggle")
        var editor = activeEditor(app)
        Thread.sleep(forTimeInterval: 0.8)
        editor.typeText("Zu\(stamp)\n")
        Thread.sleep(forTimeInterval: 1.2)
        editor = activeEditor(app, "No editor in the toggle's content")
        editor.typeText("Versteckt\(stamp)")
        let title = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Zu\(stamp)")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Toggle title missing")
        // The chevron in the title's row (toggles of other tests may be on the page too).
        let row = title.frame.midY
        guard let chevron = app.buttons.matching(NSPredicate(format: "label IN %@", ["Collapse", "Einklappen"])).allElementsBoundByIndex
            .min(by: { abs($0.frame.midY - row) < abs($1.frame.midY - row) })
        else { return XCTFail("Collapse button missing") }
        chevron.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "Editor stays after collapsing")
        let line = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Versteckt\(stamp)")).firstMatch
        XCTAssertTrue(line.waitForNonExistence(timeout: 5), "Content still shown after collapsing")
        XCTAssertTrue(app.buttons["page-add-block"].waitForExistence(timeout: 5), "Line stays active after collapsing")
        snapshot(app, "45-toggle-collapsed")
    }

    /// Embed via "/iframe": its card opens Safari; after closing Safari, the first tap on a paragraph starts editing.
    func test46_EditAfterOpeningEmbed() {
        let app = launchPage()
        _ = appendParagraph(app)
        slash(app, "iframe", pick: "embed-iframe")
        let link = app.textFields["embed-link"]
        XCTAssertTrue(link.waitForExistence(timeout: 5), "Embed link sheet doesn't open")
        link.typeText("https://example.com/embed")
        app.buttons["embed-apply"].tap()
        editorAfterSheet(app, closing: link).typeText("NachEinbettung\(stamp)")
        finishEditing(app)
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'example.com'")).firstMatch
        XCTAssertTrue(scrollTo(card, in: app), "Embed card missing")
        card.tap()
        let close = browserCloseButton(app)
        let opened = close.waitForExistence(timeout: 10)
        snapshot(app, "46-safari")
        XCTAssertTrue(opened, "Tapping the embed card doesn't open Safari")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5), "Safari doesn't close")
        _ = edit(app, blockContaining: "NachEinbettung\(stamp)")
        snapshot(app, "46-editing")
        finishEditing(app)
    }

    /// Presentation mode as on the web (Docmost 0.97, here on every server): a title slide, then the page's blocks; a
    /// table ends its slide, so "Nach der Tabelle." begins the next. The bar, a swipe and the arrow keys move between
    /// slides; ✕ ends it. (Escape too, but XCUITest's Escape key never reaches an iOS app.)
    func test76_PresentationMode() {
        let app = launchPage()
        app.buttons["page-more"].tap()
        let item = button(app, labels: ["Presentation Mode", "Präsentationsmodus"])
        XCTAssertTrue(item.waitForExistence(timeout: 5), "“Presentation Mode” missing from the menu")
        item.tap()
        let counter = app.staticTexts["presentation-counter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 5), "The presentation doesn't open")
        snapshot(app, "76-title")
        let titleSlide = app.staticTexts["presentation-title"]
        XCTAssertTrue(titleSlide.isHittable && titleSlide.label == "Editor-Test", "The first slide doesn't show the page title: “\(titleSlide.label)”")
        // "Slide 2 of 5", "Folie 2 von 5".
        func slide() -> (number: Int, total: Int) {
            let numbers = counter.label.split(separator: " ").compactMap { Int($0) }
            return numbers.count == 2 ? (numbers[0], numbers[1]) : (0, 0)
        }
        func showsSlide(_ number: Int) -> Bool {
            let shown = NSPredicate { _, _ in slide().number == number }
            return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: shown, object: nil)], timeout: 5) == .completed
        }
        XCTAssertEqual(slide().number, 1, "The presentation doesn't begin with the title: \(counter.label)")
        let total = slide().total
        XCTAssertGreaterThanOrEqual(total, 3, "The page doesn't make at least two slides: \(counter.label)")

        app.buttons["presentation-next"].tap()
        XCTAssertTrue(showsSlide(2), "“Next Slide” doesn't move on: \(counter.label)")
        snapshot(app, "76-slide-2")
        app.swipeLeft()
        XCTAssertTrue(showsSlide(3), "Swiping doesn't move on: \(counter.label)")
        snapshot(app, "76-slide-3")
        app.swipeRight()
        XCTAssertTrue(showsSlide(2), "Swiping back doesn't go back: \(counter.label)")
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(showsSlide(3), "The right arrow key doesn't move on: \(counter.label)")
        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertTrue(showsSlide(2), "The left arrow key doesn't go back: \(counter.label)")

        // The table's slide ends with it: the paragraph after it begins the next one, without the table. (test52 types
        // at the paragraph's start.)
        let after = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Nach der Tabelle.")).firstMatch
        for _ in 0..<total where !after.isHittable {
            app.buttons["presentation-next"].tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(after.isHittable, "No slide shows “Nach der Tabelle.”")
        snapshot(app, "76-after-table")
        XCTAssertFalse(app.staticTexts["Kopf A"].firstMatch.isHittable, "The table and the paragraph after it share a slide")

        app.buttons["presentation-close"].tap()
        XCTAssertTrue(counter.waitForNonExistence(timeout: 5), "✕ doesn't end the presentation")
        XCTAssertTrue(element(app, "page-title").isHittable, "The page isn't back after the presentation")
    }

    /// A pasted link to a page of this server becomes a mention of the page, as on the web (since Docmost 0.10). The
    /// server check expects the test page's mention in the paragraph with "Verweis<stamp>".
    func test74_PastePageLink() throws {
        let server = try XCTUnwrap(environment["DOCMOST_DEBUG_SERVER"]), pageId = try XCTUnwrap(environment["DOCMOST_DEBUG_PAGE"])
        let title = environment["DOCMOST_UITEST_PAGE_TITLE"] ?? "Editor-Test"
        UIPasteboard.general.string = "\(server)/p/\(pageId)"
        let app = launchPage()
        // Into the empty paragraph: there, tapping the cursor shows "Paste" (in text, a tap only moves the cursor).
        let editor = appendParagraph(app)
        paste(into: editor, in: app)
        XCTAssertTrue(waitForText(editor, contains: title, timeout: 10), "The pasted page link doesn't become a mention: “\(editor.value ?? "")”")
        XCTAssertFalse((editor.value as? String ?? "").contains("http"), "The page link stays as text")
        // The space as a tap on the on-screen keyboard, as a person types: after a paste into the editor, key events
        // such as `typeText` sends (a hardware keyboard's too) can go nowhere until something is typed on the on-screen
        // keyboard or the cursor moves (BACKLOG).
        let space = app.keyboards.keys.matching(NSPredicate(format: "label IN %@", ["space", "Leerzeichen"])).firstMatch
        XCTAssertTrue(space.waitForExistence(timeout: 5), "No space key on the keyboard")
        waitForKeyboard(app)
        space.tap()
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in ((editor.value as? String) ?? "").count > title.count }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 5), .completed, "The space typed after the mention is lost: “\(editor.value ?? "")”")
        editor.typeText("Verweis\(stamp)")
        XCTAssertTrue(waitForText(editor, contains: "Verweis\(stamp)"), "Text typed after the mention is lost: “\(editor.value ?? "")”")
        snapshot(app, "74-page-mention")
        finishEditing(app)
    }

    /// While a block is edited, a long press belongs to the text, not to moving blocks: in the edited text the text
    /// view's magnifier moves the caret ("Lupe<stamp>" at the start of "Erster Absatz"), on another paragraph the caret
    /// goes where the finger was ("Halten<stamp>" at the start of "Letzter Absatz"), and holding and moving the list
    /// onto the heading neither moves it nor ends editing. Without editing, blocks move as before (test7). The server
    /// check expects both texts and the list after the heading.
    func test75_LongPressWhileEditingBelongsToTheText() {
        let app = launchPage()
        var editor = edit(app, blockContaining: "Erster Absatz")
        Thread.sleep(forTimeInterval: 0.6)
        // Left of the first letter: the editor's frame reaches a little beyond its text.
        editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 2, dy: 12)).press(forDuration: 1)
        Thread.sleep(forTimeInterval: 0.6)
        editor.typeText("Lupe\(stamp)")
        XCTAssertTrue(waitForText(editor, contains: "Lupe\(stamp)Erster"), "Holding the edited text doesn't move the caret: “\(editor.value ?? "")”")

        // Other tests add to the items (a mention, typed text): by their start.
        func listItem(_ text: String) -> XCUIElement { app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch }
        let item = listItem("Punkt zwei")
        let heading = app.staticTexts["Überschrift"].firstMatch
        XCTAssertTrue(scrollTo(item, in: app) && heading.exists, "List or heading not found")
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 1.2, thenDragTo: heading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
        Thread.sleep(forTimeInterval: 1)
        snapshot(app, "75-held-and-moved")
        // The long press put the caret into "Punkt zwei": the editor lies on it, still below the heading.
        let held = activeEditor(app, timeout: 2, "Holding and moving a block ends editing")
        XCTAssertTrue((held.value as? String)?.hasPrefix("Punkt zwei") == true, "Holding “Punkt zwei” doesn't edit it: “\(held.value ?? "")”")
        XCTAssertGreaterThan(held.frame.minY, app.staticTexts["Überschrift"].firstMatch.frame.minY, "Holding and moving a block while editing moves it")

        let paragraph = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Letzter Absatz")).firstMatch
        XCTAssertTrue(scrollTo(paragraph, in: app, anchor: CGVector(dx: 0, dy: 0.5)), "“Letzter Absatz” not found")
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 1, dy: 0)).press(forDuration: 1)
        editor = activeEditor(app, "Holding another paragraph doesn't edit it")
        XCTAssertTrue(waitForText(editor, contains: "Letzter Absatz"), "Holding another paragraph edits a different one: “\(editor.value ?? "")”")
        Thread.sleep(forTimeInterval: 0.6)
        editor.typeText("Halten\(stamp)")
        snapshot(app, "75-typed")
        XCTAssertTrue(waitForText(editor, contains: "Halten\(stamp)Letzter"), "Holding another paragraph doesn't put the caret where the finger was: “\(editor.value ?? "")”")
        finishEditing(app)
    }

    /// The page's files, as the web lists them (Docmost 0.96): the script uploads "Anhang<stamp>.txt" to the test page;
    /// the list finds it by name and opens it in Quick Look. From Docmost 0.97 on a space admin deletes it with a swipe
    /// and the server check expects it gone; 0.96 can't delete files, so the swipe offers nothing.
    func test77_PageAttachments() {
        let app = launchPage()
        app.buttons["page-more"].tap()
        let item = button(app, labels: ["Attachments", "Anhänge"])
        XCTAssertTrue(item.waitForExistence(timeout: 5), "“Attachments” missing from the menu")
        item.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), "The attachments list doesn't open")
        search.tap()
        search.typeText("Anhang\(stamp)")
        let file = app.staticTexts["Anhang\(stamp).txt"]
        XCTAssertTrue(file.waitForExistence(timeout: 10), "The uploaded file isn't listed")
        snapshot(app, "77-attachments")

        file.tap()
        let content = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                                                             "UI-Test \(stamp)", "UI-Test \(stamp)")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 10), "Quick Look doesn't show the file")
        snapshot(app, "77-quick-look")
        // iOS 26 and later close Quick Look with an ✕ ("Close"), earlier with "Done".
        button(app, labels: ["Close", "Schließen", "Done", "Fertig"]).tap()
        XCTAssertTrue(content.waitForNonExistence(timeout: 5), "Quick Look doesn't close")

        file.swipeLeft()
        let deleteLabels = ["Delete", "Löschen"]
        let swipeDelete = app.buttons.matching(NSPredicate(format: "label IN %@", deleteLabels)).firstMatch
        guard serverHasDocmost097 else {
            XCTAssertFalse(swipeDelete.waitForExistence(timeout: 3), "Swiping offers “Delete”, which Docmost 0.96 can't do")
            return
        }
        XCTAssertTrue(swipeDelete.waitForExistence(timeout: 5), "Swiping shows no “Delete”")
        swipeDelete.tap()
        let confirm = app.popovers.firstMatch.buttons.matching(NSPredicate(format: "label IN %@", deleteLabels)).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Deleting asks nothing")
        confirm.tap()
        XCTAssertTrue(file.waitForNonExistence(timeout: 10), "The deleted file stays in the list")
    }

    // MARK: - Docmost 0.97 (`PORT=3001 Tools/run-uitests.sh`; skipped on older servers)

    /// Tabs: "/reiter" inserts "Tab 1" and "Tab 2" with the cursor in the first; "+" adds a tab and asks for its name;
    /// the tab's menu moves it left; a tab added and deleted again leaves nothing behind. The server check expects the
    /// labels "Tab 1", "Dritter<stamp>", "Tab 2", the text in the first tab and an id of its own on every tab. Tab drag
    /// off (`-tabs.tabDrag NO`): otherwise iOS keeps the drag armed while the menu is open and XCUITest waits a minute
    /// per step.
    func test69_Tabs() throws {
        try requireDocmost097()
        let app = launchPage(arguments: ["-tabs.tabDrag", "NO"])
        _ = appendParagraph(app)
        slash(app, "reiter", pick: "tabs")
        Thread.sleep(forTimeInterval: 0.8)
        activeEditor(app, "No cursor in the first tab").typeText("Reiter\(stamp)")
        finishEditing(app)
        let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reiter\(stamp)")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5), "The first tab doesn't show its text")

        let add = app.buttons["tabs-add"]
        XCTAssertTrue(scrollTo(add, in: app), "The tabs' “+” is missing")
        add.tap()
        let name = app.alerts.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 8), "Adding a tab doesn't ask for its name")
        if (name.value(forKey: "hasKeyboardFocus") as? Bool) != true { name.tap() }
        // The field holds the web's name "Tab 3".
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "Dritter\(stamp)")
        let rename = app.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["Rename", "Umbenennen"])).firstMatch
        rename.tap()
        // After the typed keys iOS brings the on-screen keyboard back and the alert moves up with it; a tap during that
        // move misses "Rename".
        if !app.alerts.firstMatch.waitForNonExistence(timeout: 3) { rename.tap() }
        let third = app.buttons["tab-Dritter\(stamp)"]
        XCTAssertTrue(third.waitForExistence(timeout: 8), "The renamed tab doesn't show")
        XCTAssertTrue(third.isSelected, "The new tab isn't the one shown")
        XCTAssertFalse(text.exists, "The first tab's text shows in the new tab")

        third.press(forDuration: 1.0)
        let moveLeft = button(app, labels: ["Move Left", "Nach links verschieben"])
        XCTAssertTrue(moveLeft.waitForExistence(timeout: 5), "“Move Left” is missing from the tab menu")
        moveLeft.tap()
        let first = app.buttons["tab-Tab 1"], second = app.buttons["tab-Tab 2"]
        let order = NSPredicate { _, _ in first.frame.minX < third.frame.minX && third.frame.minX < second.frame.minX }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: order, object: nil)], timeout: 8), .completed,
                       "“Move Left” doesn't put the tab between “Tab 1” and “Tab 2”")

        add.tap()
        let cancel = app.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Abbrechen"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8), "Adding a tab doesn't ask for its name")
        cancel.tap()
        let fourth = app.buttons["tab-Tab 4"]
        XCTAssertTrue(fourth.waitForExistence(timeout: 8), "The added tab “Tab 4” doesn't show")
        fourth.press(forDuration: 1.0)
        let delete = button(app, labels: ["Delete Tab", "Tab löschen"])
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "“Delete Tab” is missing from the tab menu")
        delete.tap()
        XCTAssertTrue(fourth.waitForNonExistence(timeout: 8), "The deleted tab remains")

        first.tap()
        XCTAssertTrue(text.waitForExistence(timeout: 5), "The first tab doesn't show its text again")
        snapshot(app, "69-tabs")
    }

    /// Tabs: "Tab 2" dragged onto the left half of "Tab 1" goes first. The server check expects "Tab 2", "Tab 1" with the
    /// text in "Tab 1". Tab menu off (`-tabs.tabMenu NO`): XCUITest doesn't do the menu-to-drag transition; on a device,
    /// holding shows the menu and moving drags the tab.
    func test73_TabDrag() throws {
        try requireDocmost097()
        let app = launchPage(arguments: ["-tabs.tabMenu", "NO"])
        _ = appendParagraph(app)
        slash(app, "reiter", pick: "tabs")
        Thread.sleep(forTimeInterval: 0.8)
        activeEditor(app, "No cursor in the first tab").typeText("Zieh\(stamp)")
        finishEditing(app)
        // test69's tabs may be on the page too: this test's are the last ones.
        let firsts = app.buttons.matching(identifier: "tab-Tab 1"), seconds = app.buttons.matching(identifier: "tab-Tab 2")
        let first = firsts.element(boundBy: max(0, firsts.count - 1)), second = seconds.element(boundBy: max(0, seconds.count - 1))
        XCTAssertTrue(scrollTo(second, in: app), "“Tab 2” is missing")
        second.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.8, thenDragTo: first.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)),
            withVelocity: .slow, thenHoldForDuration: 0.4
        )
        let moved = NSPredicate { _, _ in second.frame.minX < first.frame.minX }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)], timeout: 8), .completed,
                       "Dragging doesn't put “Tab 2” before “Tab 1”")
        snapshot(app, "73-tab-dragged")
    }

    /// Sub-pages: the block's order changes as on the web; the test page's children "Sortiert B" and "Sortiert A"
    /// (Tools/run-uitests.sh creates them in that order) swap places. The server check expects `sortBy` "title-asc".
    func test70_SubpagesSort() throws {
        try requireDocmost097()
        let app = launchPage()
        _ = appendParagraph(app)
        slash(app, "unterseit", pick: "subpages")
        _ = activeEditor(app)
        Thread.sleep(forTimeInterval: 0.8)
        finishEditing(app)
        // test36 may have added sub-pages before: this test's block is the last.
        let sorts = app.buttons.matching(identifier: "subpages-sort")
        let sort = sorts.element(boundBy: max(0, sorts.count - 1))
        XCTAssertTrue(scrollTo(sort, in: app), "The sub-pages' sort menu is missing")
        sort.tap()
        let titles = button(app, labels: ["A–Z"])
        XCTAssertTrue(titles.waitForExistence(timeout: 5), "“A–Z” is missing from the sort menu")
        titles.tap()
        XCTAssertTrue(waitForLabel(sort, matching: ".*A–Z.*", timeout: 8), "The menu doesn't show the new order: “\(sort.label)”")
        // This block's rows are the last ones of each page.
        func row(_ title: String) -> XCUIElement? {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).allElementsBoundByIndex.last
        }
        let a = try XCTUnwrap(row("Sortiert A"), "Child page “Sortiert A” missing"), b = try XCTUnwrap(row("Sortiert B"), "Child page “Sortiert B” missing")
        XCTAssertLessThan(a.frame.minY, b.frame.minY, "A–Z doesn't put “Sortiert A” before “Sortiert B”")
        snapshot(app, "70-subpages-sorted")
    }

    /// A comment's link: "Copy Link" copies the page's web address with `?commentId=`; opened from outside
    /// (`diderot://open?url=…`), it shows the page with the comments at that thread.
    func test71_CommentLink() throws {
        try requireDocmost097()
        let app = launchPage()
        app.buttons["page-comments"].tap()
        let composer = element(app, "comments-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Comments sheet doesn't open")
        // Test-Kollegin's reply (seed-notifications.py).
        let reply = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'comment-'"))
            .containing(NSPredicate(format: "label == 'Nachtrag der Kollegin'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "Test-Kollegin's reply is missing")
        let replyId = String(reply.identifier.dropFirst("comment-".count))
        app.buttons["comment-menu-\(replyId)"].tap()
        let copy = button(app, labels: ["Copy Link", "Link kopieren"])
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "“Copy Link” is missing from the comment menu")
        copy.tap()

        // The link, pasted into the composer (and not sent).
        composer.tap()
        composer.tap()
        let paste = labeled(app, ["Paste", "Einsetzen"])
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "No “Paste” in the composer")
        paste.tap()
        let copied = NSPredicate { _, _ in (composer.value as? String)?.contains("commentId=\(replyId)") == true }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: copied, object: nil)], timeout: 5), .completed,
                       "The copied link is “\(composer.value ?? "")”")
        let link = (composer.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(link.contains("/p/"), "The copied link isn't a page's web address: \(link)")
        tapSheetBarButton(app.buttons["comments-done"], in: element(app, "comments-sheet"))
        XCTAssertTrue(composer.waitForNonExistence(timeout: 5), "The comments don't close")
        backButton(app).tap()
        XCTAssertTrue(app.buttons["page-comments"].waitForNonExistence(timeout: 5), "The page doesn't close")

        var deepLink = URLComponents()
        deepLink.scheme = "diderot"
        deepLink.host = "open"
        deepLink.queryItems = [URLQueryItem(name: "url", value: link)]
        app.open(try XCTUnwrap(deepLink.url))
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "The comment link doesn't open the comments")
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "The comments don't show the linked thread")
        snapshot(app, "71-comment-link")
        tapSheetBarButton(app.buttons["comments-done"], in: element(app, "comments-sheet"))
    }

    /// A pasted link of an installed integration (Tools/run-uitests.sh installs a stand-in GitHub integration on the 0.97
    /// dev instance): "Paste As" offers card, mention and link; the card offers to connect one's GitHub account in the
    /// web's settings; a mention shows as a link after a tap. The server check expects the card and the link, both
    /// with provider "github".
    func test72_PasteIntegrationLink() throws {
        try requireDocmost097()
        try XCTSkipUnless((environment["DOCMOST_INTEGRATIONS"] ?? "").split(separator: ",").contains("github"),
                          "No GitHub integration installed on the dev server")
        let link = "https://github.com/docmost/docmost/pull/\(stamp)"
        UIPasteboard.general.string = link
        let app = launchPage()
        paste(into: appendParagraph(app), in: app)
        let card = button(app, labels: ["Card", "Karte"])
        XCTAssertTrue(card.waitForExistence(timeout: 8), "Pasting a GitHub link doesn't ask how to show it")
        XCTAssertTrue(button(app, labels: ["Mention", "Erwähnung"]).exists, "“Mention” is missing from “Paste As”")
        XCTAssertTrue(button(app, labels: ["URL"]).exists, "“URL” is missing from “Paste As”")
        snapshot(app, "72-paste-as")
        card.tap()
        let connect = app.buttons["integration-connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15), "The card doesn't offer to connect a GitHub account")
        if app.textViews["active-editor"].exists { finishEditing(app) }
        XCTAssertTrue(scrollTo(connect, in: app), "The card's “Connect” is out of reach")
        snapshot(app, "72-card")
        connect.tap()
        let done = app.buttons["integration-connect-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "“Connect” doesn't open the web's settings")
        // The web's dialog "Connect GitHub to Docmost" (its language may differ) hides the page behind it from VoiceOver.
        let settings = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'GitHub' AND label CONTAINS 'Docmost'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "The web's connection settings don't load")
        snapshot(app, "72-connect")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5), "The settings don't close")

        paste(into: appendParagraph(app), in: app)
        let mention = button(app, labels: ["Mention", "Erwähnung"])
        XCTAssertTrue(mention.waitForExistence(timeout: 8), "The second paste doesn't ask how to show the link")
        mention.tap()
        Thread.sleep(forTimeInterval: 1.0)
        let afterMention = activeEditor(app)
        afterMention.typeText(" danach")
        XCTAssertTrue(waitForText(afterMention, contains: "danach"), "Text typed after the mention is lost: “\(afterMention.value ?? "")”")
        finishEditing(app)
        let shown = app.links.matching(NSPredicate(format: "label CONTAINS %@", "docmost/docmost#\(stamp)")).firstMatch
        XCTAssertTrue(scrollTo(shown, in: app), "The mention doesn't show")
        shown.tap()
        let asLink = button(app, labels: ["Show as URL", "Als URL anzeigen"])
        XCTAssertTrue(asLink.waitForExistence(timeout: 5), "Tapping the mention doesn't offer “Show as URL”")
        asLink.tap()
        let plain = app.links.matching(NSPredicate(format: "label == %@", link)).firstMatch
        XCTAssertTrue(plain.waitForExistence(timeout: 8), "The mention doesn't turn into the link")
        snapshot(app, "72-link")
    }

    /// Pastes the clipboard at the cursor: tapping the cursor shows the edit menu; otherwise ⌘V.
    private func paste(into editor: XCUIElement, in app: XCUIApplication) {
        editor.tap()
        let paste = labeled(app, ["Paste", "Einsetzen"])
        if paste.waitForExistence(timeout: 3) {
            paste.tap()
        } else {
            editor.typeKey("v", modifierFlags: .command)
        }
    }

    /// Waits until the label matches the regular expression.
    private func waitForLabel(_ element: XCUIElement, matching pattern: String, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES %@", pattern), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
