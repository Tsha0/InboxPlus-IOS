import Foundation
import Testing
import UniformTypeIdentifiers
@testable import InboxPlusCore

private func writeTemporaryFile(named name: String, bytes: Int = 16) throws -> URL {
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/OutgoingAttachmentTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try Data(repeating: 1, count: bytes).write(to: url)
    return url
}

@Test func aChosenFileIsDescribedFromWhatItActuallyIs() throws {
    let url = try writeTemporaryFile(named: "holiday.png", bytes: 2_048)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let attachment = try OutgoingAttachment.describing(fileURL: url, caption: "the beach")
    #expect(attachment.kind == .image)
    #expect(attachment.filename == "holiday.png")
    #expect(attachment.mimeType == "image/png")
    #expect(attachment.byteCount == 2_048)
    #expect(attachment.caption == "the beach")
}

@Test func aFileThatIsNotThereIsRejectedWhenItIsChosen() {
    // Better a message the moment they pick it than a failed send ten seconds later.
    let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).png")
    #expect(throws: AttachmentRejection.self) {
        try OutgoingAttachment.describing(fileURL: missing)
    }
}

@Test func aDirectoryIsNotAnAttachment() throws {
    let url = try writeTemporaryFile(named: "x.txt")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    #expect(throws: AttachmentRejection.self) {
        try OutgoingAttachment.describing(fileURL: url.deletingLastPathComponent())
    }
}

@Test func contentTypesMapOntoTheKindTheReceiverGets() {
    #expect(OutgoingAttachment.kind(for: .png) == .image)
    #expect(OutgoingAttachment.kind(for: .jpeg) == .image)
    #expect(OutgoingAttachment.kind(for: .mpeg4Movie) == .video)
    #expect(OutgoingAttachment.kind(for: .mp3) == .audio)
    #expect(OutgoingAttachment.kind(for: .pdf) == .file)
    // Unrecognised is a file, which every network that takes attachments at all accepts.
    #expect(OutgoingAttachment.kind(for: nil) == .file)
}

@Test func aKindTheConversationDoesNotTakeIsRefusedRatherThanDowngraded() throws {
    let url = try writeTemporaryFile(named: "clip.mp4")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let attachment = try OutgoingAttachment.describing(fileURL: url)

    let imagesOnly = ConversationCapabilities(attachmentKinds: [.image])
    #expect(throws: AttachmentRejection.kindNotSupported(.video)) {
        try attachment.validate(against: imagesOnly)
    }
    #expect(throws: Never.self) {
        try attachment.validate(against: .mediaCapable)
    }
}

@Test func aFileOverTheNetworksLimitIsRefusedWithBothNumbers() throws {
    let url = try writeTemporaryFile(named: "big.png", bytes: 4_096)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let attachment = try OutgoingAttachment.describing(fileURL: url)

    let capped = ConversationCapabilities(attachmentKinds: [.image], maximumAttachmentBytes: 1_024)
    let rejection = AttachmentRejection.tooLarge(byteCount: 4_096, limit: 1_024)
    #expect(throws: rejection) { try attachment.validate(against: capped) }
    // The message has to say what was too big and what would fit, or it is not actionable.
    #expect(rejection.message.contains("4 KB") || rejection.message.contains("4,096"))
    #expect(rejection.message.contains("1 KB") || rejection.message.contains("1,024"))
}

@Test func aTextOnlyConversationTakesNothing() {
    #expect(!ConversationCapabilities.textOnly.acceptsAttachments)
    #expect(!ConversationCapabilities.textOnly.accepts(.image))
    #expect(ConversationCapabilities.mediaCapable.acceptsAttachments)
    #expect(ConversationCapabilities.mediaCapable.accepts(.file))
    // A sticker is received but never composed, so it is not in the sendable set.
    #expect(!ConversationCapabilities.mediaCapable.accepts(.sticker))
}
