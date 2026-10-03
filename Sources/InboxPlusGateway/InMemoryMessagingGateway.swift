import Foundation
import InboxPlusCore

public actor InMemoryMessagingGateway: MessagingGateway {
    private var snapshot: MessagingSnapshot
    private var continuations: [UUID: AsyncStream<GatewayEvent>.Continuation] = [:]

    public init(seed: MessagingSnapshot) { snapshot = seed }

    public func loadSnapshot() async throws -> MessagingSnapshot { snapshot }

    public func events() async -> AsyncStream<GatewayEvent> {
        let id = UUID()
        let pair = AsyncStream<GatewayEvent>.makeStream()
        continuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return pair.stream
    }

    public func sendText(_ body: String, to route: ConversationRoute) async throws -> SendReceipt {
        let message = Message(
            id: UUID().uuidString,
            route: route,
            senderIdentityID: nil,
            body: body,
            timestamp: Date(),
            deliveryState: .acknowledged
        )
        snapshot.messagesByRoute[route, default: []].append(message)
        continuations.values.forEach { $0.yield(.messageUpserted(message)) }
        return SendReceipt(messageID: message.id, route: route, deliveryState: message.deliveryState)
    }

    public func send(_ attachment: OutgoingAttachment, to route: ConversationRoute) async throws -> SendReceipt {
        let id = UUID().uuidString
        let message = Message(
            id: id,
            route: route,
            senderIdentityID: nil,
            body: attachment.caption ?? attachment.filename,
            timestamp: Date(),
            deliveryState: .acknowledged,
            kind: attachment.kind,
            attachments: [
                MessageAttachment(
                    id: "\(id)#0",
                    kind: attachment.kind,
                    filename: attachment.filename,
                    caption: attachment.caption,
                    mimeType: attachment.mimeType,
                    byteCount: attachment.byteCount,
                    pixelSize: attachment.pixelSize,
                    duration: attachment.duration,
                    // The fake serves the local file straight back, which is what makes an
                    // outgoing attachment visible in previews and tests without a homeserver.
                    source: MediaHandle(
                        source: attachment.fileURL.absoluteString,
                        mimeType: attachment.mimeType,
                        byteCount: attachment.byteCount
                    )
                ),
            ]
        )
        snapshot.messagesByRoute[route, default: []].append(message)
        continuations.values.forEach { $0.yield(.messageUpserted(message)) }
        return SendReceipt(messageID: message.id, route: route, deliveryState: message.deliveryState)
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }
}
