import XCTest

final class MessagingTests: InboxPlusUITestCase {
    @MainActor func testRealTransportFailureKeepsDraftAndRetrySends() async throws {
        let app = launch(demo: false); try await pairWithFixture(app); openFamily(app)
        let body = "fixture-fail-once:retry from iOS"
        let composer = app.textFields["message-composer"]
        composer.tap(); composer.typeText(body); app.buttons["send-message"].tap()
        let retry = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "send-message", "Retry message")).firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertEqual(composer.value as? String, body)
        retry.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", body)).firstMatch.waitForExistence(timeout: 10))
        record(app, name: "transport-retry")
    }
}
