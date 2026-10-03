import Foundation
import InboxPlusCore

/// Presents several gateways as one.
///
/// Not every network reaches Inbox+ the same way. Bridged networks arrive through Matrix; iMessage
/// is read from a local database and sent through Messages. The app layer should not have to know
/// that, so the difference stops here.
///
/// A gateway that fails is stepped over rather than allowed to empty the inbox: one broken source
/// must not take the working ones down with it, which is the same rule bridge supervision follows.
public actor CompositeMessagingGateway: MessagingGateway {
    private let gateways: [any MessagingGateway]
    /// Which gateway owns each account, so a send goes to the one that can actually perform it.
    private var gatewayByAccountID: [String: any MessagingGateway] = [:]
    private var forwardingTasks: [Task<Void, Never>] = []
    private var streamContinuations: [UUID: AsyncStream<GatewayEvent>.Continuation] = [:]
    private var startedForwarding = false

    /// Reported so the app can tell the user a source is unavailable rather than silently showing
    /// a short inbox.
    public private(set) var failures: [String] = []

    public init(_ gateways: [any MessagingGateway]) {
        self.gateways = gateways
    }

    deinit { forwardingTasks.forEach { $0.cancel() } }

    public func loadSnapshot() async throws -> MessagingSnapshot {
        var merged = MessagingSnapshot.empty
        failures = []

        for gateway in gateways {
            do {
                let snapshot = try await gateway.loadSnapshot()
                for account in snapshot.accounts {
                    gatewayByAccountID[account.id] = gateway
                }
                merged.accounts.append(contentsOf: snapshot.accounts)
                merged.identities.append(contentsOf: snapshot.identities)
                merged.conversations.append(contentsOf: snapshot.conversations)
                merged.messagesByRoute.merge(snapshot.messagesByRoute) { existing, _ in existing }
            } catch {
                // One source failing is not a reason to show nothing.
                failures.append(String(describing: error))
            }
        }

        merged.conversations.sort { $0.latestActivity > $1.latestActivity }
        startForwarding()
        return merged
    }

    public func events() async -> AsyncStream<GatewayEvent> {
        startForwarding()
        return AsyncStream { continuation in
            let id = UUID()
            streamContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func sendText(_ body: String, to route: ConversationRoute) async throws -> SendReceipt {
        try await gateway(for: route).sendText(body, to: route)
    }

    public func send(_ attachment: OutgoingAttachment, to route: ConversationRoute) async throws -> SendReceipt {
        try await gateway(for: route).send(attachment, to: route)
    }

    // MARK: - Routing

    private func gateway(for route: ConversationRoute) throws -> any MessagingGateway {
        guard let gateway = gatewayByAccountID[route.accountID] else {
            // Sending into the first gateway that happens to be there would deliver a private
            // message to the wrong network.
            throw CompositeGatewayError.unknownAccount(route.accountID)
        }
        return gateway
    }

    private func startForwarding() {
        guard !startedForwarding else { return }
        startedForwarding = true
        for gateway in gateways {
            forwardingTasks.append(
                Task { [weak self] in
                    for await event in await gateway.events() {
                        await self?.publish(event)
                    }
                }
            )
        }
    }

    private func publish(_ event: GatewayEvent) {
        for continuation in streamContinuations.values { continuation.yield(event) }
    }

    private func removeContinuation(_ id: UUID) { streamContinuations[id] = nil }
}

public enum CompositeGatewayError: Error, Equatable, CustomStringConvertible {
    case unknownAccount(String)

    public var description: String {
        switch self {
        case let .unknownAccount(id):
            "no connected source owns account '\(id)'"
        }
    }
}
