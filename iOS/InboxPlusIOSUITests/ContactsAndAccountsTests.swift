import XCTest

final class ContactsAndAccountsTests: InboxPlusUITestCase {
    @MainActor func testCreateLinkedContactAppearsInContacts() {
        let app = launch(); openFamily(app)
        let link = app.buttons["Link to person…"]
        XCTAssertTrue(link.waitForExistence(timeout: 5)); link.tap()
        let name = app.textFields["New person’s name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Family Group")
        app.buttons["Create and link"].tap()
        if app.buttons["dismiss-keyboard"].exists { app.buttons["dismiss-keyboard"].tap() }
        selectTab("Contacts", app: app)
        XCTAssertTrue(app.staticTexts["Family Group"].waitForExistence(timeout: 5))
    }
    @MainActor func testAccountPickerAndFixtureLogin() async throws {
        let app = launch(demo: false); try await pairWithFixture(app)
        selectTab("Settings", app: app); app.buttons["add-account"].tap()
        XCTAssertTrue(app.staticTexts["Add an account"].waitForExistence(timeout: 5))
        app.buttons["picker-discord"].tap()
        let username = app.textFields["login-field-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10)); username.tap(); username.typeText("fixture-user")
        app.buttons["login-continue"].tap()
        XCTAssertTrue(app.staticTexts["Discord is connected"].waitForExistence(timeout: 10))
        record(app, name: "fixture-login")
    }
}
