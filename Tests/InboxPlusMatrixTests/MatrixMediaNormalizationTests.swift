import Foundation
import Testing
import InboxPlusCore
@testable import InboxPlusMatrix

// The SDK's `MediaSource` is an FFI object that cannot be constructed in a unit test, so these
// cover the value conversions the normalizer performs around it — the places where a wrong answer
// puts a wrong duration, size or label on screen.

@Test func aBlankFieldFromABridgeIsTreatedAsUnknown() {
    #expect(MatrixEventNormalizer.text(nil) == nil)
    #expect(MatrixEventNormalizer.text("") == nil)
    #expect(MatrixEventNormalizer.text("   \n ") == nil)
    #expect(MatrixEventNormalizer.text("  clip.mp4 ") == "clip.mp4")
}

@Test func aSizeThatCannotBeRepresentedIsReportedUnknownRatherThanWrapped() {
    #expect(MatrixEventNormalizer.count(nil) == nil)
    #expect(MatrixEventNormalizer.count(0) == 0)
    #expect(MatrixEventNormalizer.count(1_048_576) == 1_048_576)
    #expect(MatrixEventNormalizer.count(UInt64.max) == nil)
}

@Test func dimensionsAreOnlyKeptWhenBothAreUsable() {
    #expect(MatrixEventNormalizer.pixelSize(width: 1920, height: 1080) == PixelSize(width: 1920, height: 1080))
    #expect(MatrixEventNormalizer.pixelSize(width: 1920, height: nil) == nil)
    #expect(MatrixEventNormalizer.pixelSize(width: 0, height: 1080) == nil)
}

@Test func durationsConvertFromSecondsToMillisecondsAndRejectNonsense() {
    #expect(MatrixEventNormalizer.duration(12.5) == .milliseconds(12_500))
    #expect(MatrixEventNormalizer.duration(0.0005) == .milliseconds(1))
    #expect(MatrixEventNormalizer.duration(nil) == nil)
    #expect(MatrixEventNormalizer.duration(0) == nil)
    #expect(MatrixEventNormalizer.duration(-3) == nil)
    #expect(MatrixEventNormalizer.duration(.infinity) == nil)
    #expect(MatrixEventNormalizer.duration(.nan) == nil)
}

@Test func aSharedReelBecomesAnOpenInAppCard() throws {
    let card = try #require(
        AppNativeContentDetector.attachment(forBody: "https://www.instagram.com/reel/Cabc123/", id: "e1#link")
    )
    #expect(card.kind == .appNative)
    #expect(card.deepLink?.platform == .instagram)
    #expect(!card.isDownloadable)
    // The card explains what the bridge reported rather than inventing a preview.
    #expect(card.reportedDescription?.contains("Instagram") == true)
}

@Test func anOrdinaryLinkStaysAnOrdinaryMessage() {
    // A profile link is just a link; dressing every URL as a card would be noise.
    #expect(AppNativeContentDetector.attachment(forBody: "https://instagram.com/tzsha0", id: "e") == nil)
    #expect(AppNativeContentDetector.attachment(forBody: "https://example.com/reel/1", id: "e") == nil)
    #expect(AppNativeContentDetector.attachment(forBody: "see you at 6", id: "e") == nil)
    #expect(AppNativeContentDetector.attachment(forBody: "", id: "e") == nil)
}

@Test func aSentenceMentioningAReelIsNotAReel() {
    // Only a body that is the link is the content itself.
    #expect(
        AppNativeContentDetector.attachment(
            forBody: "look at this https://www.instagram.com/reel/Cabc123/", id: "e"
        ) == nil
    )
}

@Test func anUnverifiableSchemeNeverBecomesACard() {
    #expect(AppNativeContentDetector.attachment(forBody: "instagram://reel/1", id: "e") == nil)
    #expect(AppNativeContentDetector.attachment(forBody: "javascript:alert(1)", id: "e") == nil)
}
