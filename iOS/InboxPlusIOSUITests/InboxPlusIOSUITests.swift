import XCTest
final class InboxPlusIOSUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    @MainActor func testDemoNavigationSearchAndSend() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["DEMO · Sample conversations"].waitForExistence(timeout: 10))
        record(app, name: "iPhone-or-iPad-inbox")
        let search = app.textFields["inbox-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Family")
        let family = app.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "family-telegram")).firstMatch
        XCTAssertTrue(family.waitForExistence(timeout: 5)); family.tap()
        let composer = app.textFields["message-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5)); composer.tap(); composer.typeText("Hello from iOS")
        app.buttons["send-message"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Hello from iOS")).firstMatch.waitForExistence(timeout: 5))
        if app.buttons["dismiss-keyboard"].exists { app.buttons["dismiss-keyboard"].tap() }
        record(app, name: "conversation")
        app.buttons["Contacts"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Maya"].waitForExistence(timeout: 5))
        app.buttons["Settings"].firstMatch.tap()
        app.buttons["add-account"].tap()
        XCTAssertTrue(app.staticTexts["Add an account"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        record(app, name: "settings")
    }
    @MainActor private func record(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testPairingValidation() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo"]; app.launch()
        app.buttons["Settings"].firstMatch.tap()
        for _ in 0..<4 where !app.buttons["disconnect-device"].exists { app.swipeUp() }
        app.buttons["disconnect-device"].tap()
        XCTAssertTrue(app.textFields["pairing-address"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["inboxplus-logo"].waitForExistence(timeout: 5))
        record(app, name: "pairing")
        app.textFields["pairing-address"].tap(); app.textFields["pairing-address"].typeText("http://example.com")
        app.secureTextFields["pairing-key"].tap(); app.secureTextFields["pairing-key"].typeText(String(repeating: "x", count: 32))
        app.buttons["pairing-connect"].tap()
        XCTAssertTrue(app.staticTexts["pairing-error"].waitForExistence(timeout: 5))
    }
}
