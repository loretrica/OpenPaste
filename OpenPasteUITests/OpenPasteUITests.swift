import XCTest

final class OpenPasteUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSearchAndEscapeLayering() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let search = app.textFields["clipboard.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("OpenPaste")
        app.typeKey(.return, modifierFlags: [])
        let firstCard = app.descendants(matching: .any).matching(identifier: "clipboard.card.1").firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 5))

        search.click()
        app.typeKey("a", modifierFlags: .command)
        search.typeText("NoResult" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        app.typeKey(.return, modifierFlags: [])
        let emptySearch = app.staticTexts["Nessun risultato"]
        XCTAssertTrue(emptySearch.waitForExistence(timeout: 5))

        app.typeKey(.escape, modifierFlags: [])
        let resultsClosed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: emptySearch)
        XCTAssertEqual(XCTWaiter.wait(for: [resultsClosed], timeout: 5), .completed)
        XCTAssertEqual(search.value as? String, "")

        app.typeKey(.escape, modifierFlags: [])
        let panelClosed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: search)
        XCTAssertEqual(XCTWaiter.wait(for: [panelClosed], timeout: 5), .completed)
    }

    @MainActor
    func testClickCardCmdCCopiesWithoutClosingPanel() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let search = app.textFields["clipboard.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))

        let firstCard = app.descendants(matching: .any).matching(identifier: "clipboard.card.2").firstMatch
        waitForHittable(firstCard)
        firstCard.click()
        waitForSelected(firstCard)

        let differentCard = app.descendants(matching: .any).matching(identifier: "clipboard.card.3").firstMatch
        waitForHittable(differentCard)
        differentCard.click()
        waitForSelected(differentCard)
        app.typeKey("c", modifierFlags: .command)

        XCTAssertTrue(app.staticTexts["Copiato"].waitForExistence(timeout: 5))
        XCTAssertTrue(search.exists, "Copying should leave the panel open")
    }

    @MainActor
    func testDragCardIntoCollection() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let card = app.descendants(matching: .any).matching(identifier: "clipboard.card.1").firstMatch
        waitForHittable(card)
        let designCollection = app.buttons["Design"]
        waitForHittable(designCollection)

        card.click(forDuration: 1, thenDragTo: designCollection)
        designCollection.click()
        XCTAssertTrue(designCollection.isSelected)

        let movedCard = app.descendants(matching: .any).matching(identifier: "clipboard.card.1").firstMatch
        waitForHittable(movedCard)
        XCTAssertTrue(app.textFields["clipboard.search"].exists, "Moving a card should leave the panel open")
    }

    @MainActor
    func testCardContextMenuPreviewAndSpaceShortcutDismiss() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let search = app.textFields["clipboard.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))

        let initiallyInactiveCard = app.descendants(matching: .any).matching(identifier: "clipboard.card.2").firstMatch
        waitForHittable(initiallyInactiveCard)
        initiallyInactiveCard.click()
        waitForSelected(initiallyInactiveCard)

        search.click()
        search.typeText("OpenPaste salva")
        app.typeKey(.return, modifierFlags: [])

        let card = app.descendants(matching: .any).matching(identifier: "clipboard.card.1").firstMatch
        waitForSelected(card)
        waitForHittable(card)
        card.rightClick()

        let previewMenuItem = app.menuItems["Anteprima"]
        XCTAssertTrue(previewMenuItem.waitForExistence(timeout: 5), "The card context menu should expose Anteprima")
        previewMenuItem.click()

        let closeButton = app.buttons["Chiudi"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "Anteprima should open for the text fixture")
        app.typeKey(.escape, modifierFlags: [])
        let contextPreviewClosed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: closeButton)
        XCTAssertEqual(XCTWaiter.wait(for: [contextPreviewClosed], timeout: 5), .completed)
        XCTAssertTrue(search.exists, "Closing Anteprima should leave the panel open")

        card.click()
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "Space should open Anteprima for the active text card")
        app.typeKey(.escape, modifierFlags: [])
        let keyboardPreviewClosed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: closeButton)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardPreviewClosed], timeout: 5), .completed)
        XCTAssertTrue(search.exists, "Closing the keyboard preview should leave the panel open")
    }

    @MainActor
    private func waitForHittable(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 5), .completed)
        XCTAssertGreaterThan(element.frame.width, 0)
        XCTAssertGreaterThan(element.frame.height, 0)
    }

    @MainActor
    private func waitForSelected(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Selezionato"),
            object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
    }

    @MainActor
    func testLaunchPerformance() {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing"]
            app.launch()
        }
    }
}
