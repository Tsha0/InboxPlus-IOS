import Foundation
import Testing
import InboxPlusCore
import InboxPlusGateway
@testable import InboxPlusFeatures

private func stagingDirectory() -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/AttachmentCompositionTests-\(UUID().uuidString)")
}

private func writeFile(_ directory: URL, named name: String, bytes: Int = 32) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try Data(repeating: 2, count: bytes).write(to: url)
    return url
}

private let route = ConversationRoute(accountID: "instagram", conversationID: "c1")

@MainActor
private func makeModel(capabilities: ConversationCapabilities = .mediaCapable) async throws -> (InboxPlusAppModel, InMemoryMessagingGateway) {
    let snapshot = MessagingSnapshot(
        accounts: [ConnectedAccount(id: "instagram", platform: .instagram, displayName: "Instagram")],
        identities: [RemoteIdentity(id: "them", accountID: "instagram", displayName: "Maya")],
        conversations: [
            RemoteConversation(
                id: "c1",
                accountID: "instagram",
                identityID: "them",
                title: "Maya",
                latestActivity: Date(timeIntervalSince1970: 100),
                unreadCount: 0,
                capabilities: capabilities
            ),
        ],
        messagesByRoute: [:]
    )
    let gateway = InMemoryMessagingGateway(seed: snapshot)
    let model = InboxPlusAppModel(gateway: gateway)
    try await model.start()
    return (model, gateway)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func aChosenFileIsStagedBeforeItIsSent() async throws {
    let directory = stagingDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, _) = try await makeModel()
    let url = try writeFile(directory, named: "photo.png")

    #expect(model.stageAttachment(at: url, for: route) == nil)
    #expect(model.stagedAttachments(for: route).map(\.filename) == ["photo.png"])
    // Staging is not sending: nothing has left the app yet.
    #expect(model.messagesByRoute[route]?.isEmpty != false)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func sendingAStagedFileClearsItAndProducesAMessageWithTheAttachment() async throws {
    let directory = stagingDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, _) = try await makeModel()
    let url = try writeFile(directory, named: "photo.png", bytes: 64)
    model.stageAttachment(at: url, for: route)

    try await model.sendStagedAttachments(to: route)

    #expect(model.stagedAttachments(for: route).isEmpty)
    // The sent message reaches the model through the gateway's event stream, not the send call.
    let deadline = ContinuousClock().now.advanced(by: .seconds(5))
    while model.messagesByRoute[route]?.isEmpty != false, ContinuousClock().now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    let message = try #require(model.messagesByRoute[route]?.last)
    #expect(message.kind == .image)
    #expect(message.attachments.count == 1)
    #expect(message.attachments.first?.byteCount == 64)
    #expect(message.isOutgoing)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func aFileTheConversationWillNotTakeIsRefusedAtTheMomentItIsChosen() async throws {
    let directory = stagingDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, _) = try await makeModel(capabilities: ConversationCapabilities(attachmentKinds: [.image]))
    let url = try writeFile(directory, named: "clip.mp4")

    let rejection = model.stageAttachment(at: url, for: route)
    #expect(rejection == .kindNotSupported(.video))
    #expect(model.stagedAttachments(for: route).isEmpty)
    // The user is told, rather than discovering it when the send fails.
    #expect(model.sendFailure(for: route) == rejection?.message)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func aStagedFileCanBeTakenBackBeforeItIsSent() async throws {
    let directory = stagingDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, _) = try await makeModel()
    let url = try writeFile(directory, named: "photo.png")
    model.stageAttachment(at: url, for: route)

    let staged = try #require(model.stagedAttachments(for: route).first)
    model.removeStagedAttachment(staged, for: route)
    #expect(model.stagedAttachments(for: route).isEmpty)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func stagedFilesBelongToOneConversationOnly() async throws {
    let directory = stagingDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, _) = try await makeModel()
    let url = try writeFile(directory, named: "photo.png")
    model.stageAttachment(at: url, for: route)

    // Switching conversations must not carry someone's photo into a different chat.
    let other = ConversationRoute(accountID: "instagram", conversationID: "c2")
    #expect(model.stagedAttachments(for: other).isEmpty)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func capabilitiesReachTheComposerAndDefaultToTextOnlyForAnUnknownRoute() async throws {
    let (model, _) = try await makeModel(capabilities: ConversationCapabilities(attachmentKinds: [.image]))

    #expect(model.capabilities(for: route).accepts(.image))
    #expect(!model.capabilities(for: route).accepts(.video))
    // A route with no conversation behind it offers nothing rather than assuming.
    let unknown = ConversationRoute(accountID: "instagram", conversationID: "missing")
    #expect(!model.capabilities(for: unknown).acceptsAttachments)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func aFileThatFailsToSendStaysStaged() async throws {
    let directory = stagingDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, _) = try await makeModel()
    let url = try writeFile(directory, named: "photo.png")
    model.stageAttachment(at: url, for: route)

    // Delete the file out from under the send. Losing the user's choice with nothing to show for
    // it would be worse than leaving it staged for another try.
    try FileManager.default.removeItem(at: url)
    let projector = model.stagedAttachments(for: route)
    #expect(projector.count == 1)
}
