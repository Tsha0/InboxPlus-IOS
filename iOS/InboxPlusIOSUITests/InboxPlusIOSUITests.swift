import XCTest
final class InboxPlusIOSUITests: XCTestCase {
    @MainActor func testDemoNavigationSearchAndSend() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["DEMO · Sample conversations"].waitForExistence(timeout: 10))
        let search = app.textFields["inbox-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Family")
        let family = app.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "family-telegram")).firstMatch
        XCTAssertTrue(family.waitForExistence(timeout: 5)); family.tap()
        let composer = app.textFields["message-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5)); composer.tap(); composer.typeText("Hello from iOS")
        app.buttons["send-message"].tap()
        XCTAssertTrue(app.staticTexts["Hello from iOS"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Contacts"].tap()
        XCTAssertTrue(app.staticTexts["Maya"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        app.buttons["add-account"].tap()
        XCTAssertTrue(app.otherElements["account-picker"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.lifetime = .keepAlways; add(screenshot)
    }
    @MainActor func testPairingValidation() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo"]; app.launch()
        app.tabBars.buttons["Settings"].tap(); app.buttons["disconnect-device"].tap()
        XCTAssertTrue(app.textFields["pairing-address"].waitForExistence(timeout: 5))
        app.textFields["pairing-address"].tap(); app.textFields["pairing-address"].typeText("http://example.com")
        app.secureTextFields["pairing-key"].tap(); app.secureTextFields["pairing-key"].typeText(String(repeating: "x", count: 32))
        app.buttons["pairing-connect"].tap()
        XCTAssertTrue(app.staticTexts["pairing-error"].waitForExistence(timeout: 5))
    }
}
