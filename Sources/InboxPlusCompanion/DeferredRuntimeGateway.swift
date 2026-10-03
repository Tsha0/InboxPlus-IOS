import Foundation
import InboxPlusCore
import InboxPlusFeatures
import InboxPlusGateway
import InboxPlusRuntime

/// A gateway that brings the runtime up the first time it is actually used.
///
/// The window has to appear immediately, and a cold runtime takes tens of seconds — Synapse plus a
/// bridge process per network. Doing that work at launch would freeze the app before it drew
/// anything, so it happens behind the first `loadSnapshot()`, which the model already performs
/// asynchronously and already reports as a startup state.
///
/// Everything downstream is built only once the homeserver answers, because a Matrix client
/// constructed against a port nothing is listening on fails in ways that read as a bug in Inbox+.
actor DeferredRuntimeGateway: MessagingGateway {
    private let paths: RuntimePaths
    private let profileName: String
    private let build: @Sendable (RuntimeProfileState) throws -> any MessagingGateway
    private let onReady: @Sendable (RuntimeProfileState) async -> Void

    private var resolved: (any MessagingGateway)?
    private var resolving: Task<any MessagingGateway, any Error>?

    init(
        paths: RuntimePaths,
        profileName: String,
        build: @escaping @Sendable (RuntimeProfileState) throws -> any MessagingGateway,
        onReady: @escaping @Sendable (RuntimeProfileState) async -> Void = { _ in }
    ) {
        self.paths = paths
        self.profileName = profileName
        self.build = build
        self.onReady = onReady
    }

    // MARK: - MessagingGateway

    func loadSnapshot() async throws -> MessagingSnapshot {
        try await gateway().loadSnapshot()
    }

    func events() async -> AsyncStream<GatewayEvent> {
        // A failure here cannot be thrown, and an empty stream would silently mean "no messages
        // ever". The snapshot path reports the real error; this one waits for the gateway that
        // path resolves rather than inventing a second answer.
        guard let gateway = try? await gateway() else { return AsyncStream { $0.finish() } }
        return await gateway.events()
    }

    func sendText(_ body: String, to route: ConversationRoute) async throws -> SendReceipt {
        try await gateway().sendText(body, to: route)
    }

    func send(_ attachment: OutgoingAttachment, to route: ConversationRoute) async throws -> SendReceipt {
        try await gateway().send(attachment, to: route)
    }

    // MARK: - Resolution

    /// Starts the runtime once, however many callers arrive at the same moment.
    private func gateway() async throws -> any MessagingGateway {
        if let resolved { return resolved }
        if let resolving { return try await resolving.value }

        let task = Task<any MessagingGateway, any Error> { [paths, profileName, build, onReady] in
            let state = try await ManagedRuntime.shared.ensureRunning(
                paths: paths,
                profileName: profileName,
                progress: { message in
                    FileHandle.standardError.write(Data("Inbox+: \(message)\n".utf8))
                }
            )
            let gateway = try build(state)
            await onReady(state)
            return gateway
        }
        resolving = task

        do {
            let gateway = try await task.value
            resolved = gateway
            resolving = nil
            return gateway
        } catch {
            // Cleared so a retry — the user pressing reload, or the next send — starts again rather
            // than replaying a stored failure forever.
            resolving = nil
            throw error
        }
    }
}
