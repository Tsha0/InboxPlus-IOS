import Foundation
import Testing
import InboxPlusCore
@testable import InboxPlusUI

@Test func durationsReadAsClockTime() {
    #expect(AttachmentFormatting.durationLabel(.seconds(9)) == "0:09")
    #expect(AttachmentFormatting.durationLabel(.seconds(75)) == "1:15")
    #expect(AttachmentFormatting.durationLabel(.seconds(3_725)) == "1:02:05")
}

@Test func anUnknownOrZeroDurationIsSimplyNotShown() {
    // A "0:00" under a voice message is a claim; absence is the truth.
    #expect(AttachmentFormatting.durationLabel(nil) == nil)
    #expect(AttachmentFormatting.durationLabel(.zero) == nil)
    #expect(AttachmentFormatting.durationLabel(.milliseconds(400)) == nil)
}

@Test func anUnknownSizeIsSimplyNotShown() {
    #expect(AttachmentFormatting.byteLabel(nil) == nil)
    #expect(AttachmentFormatting.byteLabel(0) == nil)
    #expect(AttachmentFormatting.byteLabel(1_048_576) != nil)
}

@Test func everyKindReadsAsSomethingRatherThanNothing() {
    for kind in MessageKind.allCases {
        #expect(!AttachmentFormatting.noun(for: kind).isEmpty)
    }
}

@Test func voiceOverDescribesWhatIsKnownAndInventsNothing() {
    let known = MessageAttachment(
        id: "1",
        kind: .video,
        filename: "clip.mp4",
        byteCount: 1_048_576,
        duration: .seconds(75)
    )
    let label = AttachmentFormatting.accessibilityLabel(for: known)
    #expect(label.contains("Video"))
    #expect(label.contains("clip.mp4"))
    #expect(label.contains("1:15"))

    // Nothing known but the kind: still a usable label, with no fabricated duration or size.
    let bare = AttachmentFormatting.accessibilityLabel(for: MessageAttachment(id: "2", kind: .video))
    #expect(bare == "Video, Video")
}

@Test func anAppNativeCardAnnouncesWhereItOpens() throws {
    let attachment = MessageAttachment(
        id: "1",
        kind: .appNative,
        deepLink: try DeepLinkVerifier.verify("https://instagram.com/reel/1", for: .instagram)
    )
    #expect(AttachmentFormatting.accessibilityLabel(for: attachment).contains("opens in Instagram"))
}
