import Foundation
import MatrixRustSDK
import InboxPlusCore
import InboxPlusGateway
import Testing
@testable import InboxPlusMatrix
@testable import InboxPlusRuntime

private func makeRealProfile(_ label: String) throws -> (RuntimePaths, URL) {
    let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Library/Caches", isDirectory: true)
        .appendingPathComponent("InboxPlusGateway\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    return (try RuntimePaths(root: root, profileName: "gateway"), root)
}

/// The Phase 3 acceptance test: a real room, a real send, and a real server echo arriving through
/// the same `MessagingGateway` protocol the app already consumes.
@Test(
    .enabled(if: ProcessInfo.processInfo.environment["INBOXPLUS_RUNTIME_PYTHON"] != nil),
    .timeLimit(.minutes(5))
)
func realGatewayLoadsRoomsAndRoundTripsAMessage() async throws {
    let pythonPath = try #require(ProcessInfo.processInfo.environment["INBOXPLUS_RUNTIME_PYTHON"])
    let (paths, root) = try makeRealProfile("RoundTrip")
    defer { try? FileManager.default.removeItem(at: root) }

    let service = RuntimeProfileService(
        paths: paths,
        packageRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    )
    _ = try await service.bootstrap(python: URL(fileURLWithPath: pythonPath))

    let store = MatrixClientStore(
        profile: paths,
        keychain: MatrixKeychain(service: "org.inboxplus.tests.\(UUID().uuidString)")
    )
    defer { try? store.destroy() }

    try await service.withRunningRuntime { _, context in
        let provisioner = try MatrixAccountProvisioner(
            baseURL: context.baseURL,
            serverName: context.serverName,
            registrationSecret: context.registrationSecret
        )
        let matrix = InboxPlusMatrixClient(
            homeserverURL: context.baseURL,
            store: store,
            provisioner: provisioner
        )
        let gateway = MatrixMessagingGateway(client: matrix)
        try await gateway.start()

        // Create a room directly through the SDK so the gateway has something real to project.
        let sdkClient = try await matrix.requireClient()
        let roomID = try await sdkClient.createRoom(
            request: CreateRoomParameters(
                name: "Phase 3 acceptance",
                topic: nil,
                isEncrypted: false,
                isDirect: false,
                visibility: .private,
                preset: .privateChat,
                invite: nil,
                avatar: nil,
                powerLevelContentOverride: nil,
                joinRuleOverride: nil,
                historyVisibilityOverride: nil,
                canonicalAlias: nil,
                isSpace: false
            )
        )

        // The room must surface through the gateway's snapshot.
        // Wait for the room *and* its name: a freshly created room reports the placeholder
        // "Empty Room" until its m.room.name state reaches the client's local store.
        var snapshot = MessagingSnapshot.empty
        for _ in 0..<30 {
            snapshot = try await gateway.loadSnapshot()
            if snapshot.conversations.contains(where: {
                $0.id == roomID && $0.title == "Phase 3 acceptance"
            }) { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        let conversation = try #require(snapshot.conversations.first { $0.id == roomID })
        #expect(conversation.title == "Phase 3 acceptance")
        #expect(snapshot.accounts.first?.platform == .matrix)

        // Sending must report pending, never an unconfirmed success.
        let receipt = try await gateway.sendText("hello from Inbox+", to: conversation.route)
        #expect(receipt.deliveryState == .pending)
        #expect(receipt.route == conversation.route)

        // The server echo must arrive back through the gateway as an acknowledged message.
        // The local echo appears first and is correctly `pending`; wait for the server-confirmed
        // event, which is the only thing allowed to read as acknowledged.
        var echoed: Message?
        for _ in 0..<40 {
            let refreshed = try await gateway.loadSnapshot()
            if let found = refreshed.messagesByRoute[conversation.route]?
                .first(where: { $0.body == "hello from Inbox+" && $0.deliveryState == .acknowledged }) {
                echoed = found
                break
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        let message = try #require(echoed, "the sent message never came back through sync")
        #expect(message.deliveryState == .acknowledged)
        #expect(message.isOutgoing)

        await gateway.stop()
    }
}

// MARK: - Unit coverage that needs no server

@Test func userIdentifiersRenderAsReadableNames() {
    #expect(MatrixMessagingGateway.displayName(forUserID: "@alice:inboxplus.localhost") == "alice")
    #expect(MatrixMessagingGateway.displayName(forUserID: "@bob:example.org") == "bob")
    // Anything unexpected is shown verbatim rather than mangled.
    #expect(MatrixMessagingGateway.displayName(forUserID: "not-a-user-id") == "not-a-user-id")
    #expect(MatrixMessagingGateway.displayName(forUserID: "@nocolon") == "@nocolon")
}

@Test func remoteEventsAreAcknowledgedAndLocalOnesAreNot() {
    // A remote event exists because the server already accepted it.
    #expect(MatrixEventNormalizer.deliveryState(for: nil) == .acknowledged)
    #expect(MatrixEventNormalizer.deliveryState(for: .sent(eventId: "$abc")) == .acknowledged)
    #expect(MatrixEventNormalizer.deliveryState(for: .notSentYet(progress: nil)) == .pending)
}

@Test func messagesOrderByTimestampThenIdentifier() {
    let route = ConversationRoute(accountID: "a", conversationID: "!r:s")
    func message(_ id: String, _ seconds: TimeInterval) -> Message {
        Message(
            id: id,
            route: route,
            senderIdentityID: "@x:s",
            body: id,
            timestamp: Date(timeIntervalSince1970: seconds),
            deliveryState: .acknowledged
        )
    }
    let sorted = [message("c", 2), message("a", 1), message("b", 1)]
        .sorted(by: inboxplusMessageOrdering)
    // Equal timestamps break ties on identifier so bridged out-of-order events stay stable.
    #expect(sorted.map(\.id) == ["a", "b", "c"])
}
