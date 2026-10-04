import XCTest

final class OpenPasteUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSearchAndEscapeDismissal() {
        let app = XCUIApplication()
        app.launch()
        let search = app.textFields["clipboard.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("OpenPasteNoResult" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        XCTAssertTrue(app.staticTexts["Nessun risultato"].waitForExistence(timeout: 5))

        app.typeKey(.escape, modifierFlags: [])
        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: search)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)

        app.typeKey("v", modifierFlags: [.shift, .command])
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("x")
        app.typeKey(.escape, modifierFlags: [])
        let hiddenAgain = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: search)
        XCTAssertEqual(XCTWaiter.wait(for: [hiddenAgain], timeout: 5), .completed)
    }

    @MainActor
    func testLaunchPerformance() {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
