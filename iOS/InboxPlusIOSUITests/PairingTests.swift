import XCTest

final class PairingTests: InboxPlusUITestCase {
    @MainActor func testInvalidAddressIsVisibleAndLogoIsAccessible() {
        let app = launch(demo: false)
        XCTAssertTrue(app.images["inboxplus-logo"].waitForExistence(timeout: 5))
        record(app, name: "pairing")
        app.textFields["pairing-address"].tap(); app.textFields["pairing-address"].typeText("http://example.com")
        app.secureTextFields["pairing-key"].tap(); app.secureTextFields["pairing-key"].typeText(String(repeating: "x", count: 32))
        app.buttons["pairing-connect"].tap()
        XCTAssertTrue(app.staticTexts["pairing-error"].waitForExistence(timeout: 5))
    }
    @MainActor func testPairingRestoresAfterRelaunchAndDisconnectClearsIt() async throws {
        var app = launch(demo: false); try await pairWithFixture(app)
        app.terminate(); app = launch(demo: false, restoring: true)
        XCTAssertTrue(app.textFields["inbox-search"].waitForExistence(timeout: 15))
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.textFields["inbox-search"].waitForExistence(timeout: 10))
        selectTab("Settings", app: app)
        for _ in 0..<5 where !app.buttons["disconnect-device"].isHittable { app.swipeUp() }
        app.buttons["disconnect-device"].tap()
        let confirm = app.buttons["Disconnect and clear local data"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(app.textFields["pairing-address"].waitForExistence(timeout: 10))
        app.terminate(); app = launch(demo: false, restoring: true)
        XCTAssertTrue(app.textFields["pairing-address"].waitForExistence(timeout: 10))
    }
}
