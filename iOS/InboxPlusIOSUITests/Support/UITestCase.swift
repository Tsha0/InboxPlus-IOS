import XCTest

class InboxPlusUITestCase: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    @MainActor func launch(demo: Bool = true, restoring: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + (demo ? ["--demo"] : []) + (restoring ? ["--ui-restore"] : [])
        if ProcessInfo.processInfo.environment["INBOXPLUS_TEST_LARGE_TEXT"] == "1" {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch(); return app
    }
    @MainActor func selectTab(_ title: String, app: XCUIApplication) {
        let tab = app.buttons[title].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5)); tab.tap()
    }
    @MainActor func openFamily(_ app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "family-telegram")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        XCTAssertTrue(app.textFields["message-composer"].waitForExistence(timeout: 5))
    }
    @MainActor func record(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func pairWithFixture(_ app: XCUIApplication) async throws {
        let token = try XCTUnwrap(ProcessInfo.processInfo.environment["INBOXPLUS_TEST_TOKEN"], "Run via Scripts/ci/test-ios.sh to start the fixture and supply its key")
        XCTAssertGreaterThanOrEqual(token.count, 32)
        var reset = URLRequest(url: URL(string: "http://127.0.0.1:8765/v1/rpc")!)
        reset.httpMethod = "POST"; reset.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        reset.setValue("application/json", forHTTPHeaderField: "Content-Type")
        reset.httpBody = Data("{\"operation\":\"fixtureReset\"}".utf8)
        let (_, response) = try await URLSession.shared.data(for: reset)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let address = app.textFields["pairing-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeText("http://127.0.0.1:8765")
        app.secureTextFields["pairing-key"].tap(); app.secureTextFields["pairing-key"].typeText(token)
        app.buttons["pairing-connect"].tap()
        XCTAssertTrue(app.textFields["inbox-search"].waitForExistence(timeout: 15))
        // iPhone presents this as a sheet and iPad as an alert; both expose the button.
        let skipPasswordSave = app.buttons["Not Now"]
        if skipPasswordSave.waitForExistence(timeout: 3) { skipPasswordSave.tap() }
        XCTAssertFalse(app.staticTexts["DEMO · Sample conversations"].exists)
    }
}
