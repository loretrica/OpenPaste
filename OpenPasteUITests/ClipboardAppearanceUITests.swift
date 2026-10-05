import XCTest

final class ClipboardAppearanceUITests: XCTestCase {
    @MainActor
    func testLightAndDarkPillSnapshots() throws {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "--appearance-" + appearance]
            app.launch()
            let card = app.descendants(matching: .any).matching(identifier: "clipboard.card.1").firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 10))
            let pill = app.descendants(matching: .any).matching(identifier: "clipboard.pill").firstMatch
            XCTAssertTrue(pill.waitForExistence(timeout: 5))
            let screenshot = pill.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "OpenPaste pill " + appearance
            attachment.lifetime = .keepAlways
            add(attachment)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenPasteSnapshots", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try screenshot.pngRepresentation.write(to: directory.appendingPathComponent("pill-" + appearance + ".png"), options: .atomic)
            print("OPENPASTE_SNAPSHOT: " + directory.appendingPathComponent("pill-" + appearance + ".png").path)
            app.terminate()
        }
    }
}
