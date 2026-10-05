import XCTest

final class NavigationTests: InboxPlusUITestCase {
    @MainActor func testSearchSendAndTabNavigation() throws {
        let app = launch()
        XCTAssertTrue(app.staticTexts["DEMO · Sample conversations"].waitForExistence(timeout: 10))
        record(app, name: "inbox")
        let search = app.textFields["inbox-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Family")
        openFamily(app)
        let composer = app.textFields["message-composer"]
        composer.tap(); composer.typeText("Hello from iOS")
        app.buttons["send-message"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Hello from iOS")).firstMatch.waitForExistence(timeout: 5))
        if app.buttons["dismiss-keyboard"].exists { app.buttons["dismiss-keyboard"].tap() }
        record(app, name: "conversation")
        selectTab("Contacts", app: app)
        XCTAssertTrue(app.staticTexts["Maya"].waitForExistence(timeout: 5))
        selectTab("Settings", app: app)
        XCTAssertTrue(app.buttons["add-account"].waitForExistence(timeout: 5))
        record(app, name: "settings")
    }
    @MainActor func testUnreadFilterExcludesReadConversation() {
        let app = launch()
        let family = app.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "family-telegram")).firstMatch
        XCTAssertTrue(family.waitForExistence(timeout: 10))
        app.buttons["Unread"].tap(); XCTAssertFalse(family.exists)
        app.buttons["All"].tap(); XCTAssertTrue(family.exists)
    }
}
