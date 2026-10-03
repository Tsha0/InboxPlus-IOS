import Foundation
import InboxPlusCore
import InboxPlusGateway
import Testing

/// A fake that exists to exercise text sending and startup, not attachments.
///
/// Rather than eight silent stubs, sending a file through one of these records an issue: a test
/// that starts relying on attachment sending should adopt a fake that actually models it.
protocol TextOnlyTestGateway: MessagingGateway {}

struct TextOnlyTestGatewayError: Error {}

extension TextOnlyTestGateway {
    func send(_ attachment: OutgoingAttachment, to route: ConversationRoute) async throws -> SendReceipt {
        Issue.record("\(Self.self) does not model attachment sending")
        throw TextOnlyTestGatewayError()
    }
}
