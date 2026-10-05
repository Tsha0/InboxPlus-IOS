import Foundation
import InboxPlusCore
import InboxPlusFeatures
import InboxPlusGateway
import InboxPlusRemote
import InboxPlusCompanionServer
import InboxPlusBridge

/// A deterministic service used only by automated tests and local development.
private actor FixtureService {
    private var gateway = InMemoryMessagingGateway(seed: Fixtures.snapshot)
    private var failedMessages: Set<String> = []
    private var media: [String: Data] = [:]
    func call(_ request: CompanionRequest) async -> CompanionResponse {
        var response = CompanionResponse()
        do {
            switch request.operation {
            case "fixtureReset":
                gateway = InMemoryMessagingGateway(seed: Fixtures.snapshot); failedMessages = []; media = [:]
            case "snapshot": response.snapshot = try await gateway.loadSnapshot()
            case "sendText":
                guard let body = request.body, let route = request.route else { throw CompanionError.invalidResponse }
                if body.hasPrefix("fixture-fail-once:"), failedMessages.insert(body).inserted { throw CompanionError.server("Fixture temporary send failure. Retry your message.") }
                response.receipt = try await gateway.sendText(body, to: route)
            case "sendAttachment":
                guard let bytes = request.data, bytes.count <= 25 * 1024 * 1024, let route = request.route else { throw CompanionError.invalidResponse }
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try bytes.write(to: file)
                defer { try? FileManager.default.removeItem(at: file) }
                let attachment = OutgoingAttachment(fileURL: file, kind: .file, filename: request.filename ?? "fixture.txt", mimeType: "text/plain", byteCount: bytes.count)
                response.receipt = try await gateway.send(attachment, to: route)
                media[file.absoluteString] = bytes
            case "media":
                guard let source = request.handle?.source, let bytes = media[source] else { throw CompanionError.server("Fixture media not found") }
                response.data = bytes
            case "loginPrepare":
                response.sessionID = "fixture-session"
                response.flows = [.init(id: "fixture", name: "Fixture login", description: "Automated test account")]
            case "loginStart":
                guard request.sessionID == "fixture-session" else { throw CompanionError.invalidResponse }
                response.step = .init(type: .userInput, stepID: "username", loginID: "fixture-login", instructions: "Enter a fixture username", userInput: .init(fields: [.init(type: .username, id: "username", name: "Username")]))
            case "loginSubmit":
                guard request.sessionID == "fixture-session", request.values?["username"]?.isEmpty == false else { throw CompanionError.invalidResponse }
                response.step = .init(type: .complete, stepID: "complete", loginID: "fixture-login", complete: .init(userLoginID: "fixture-account"))
            case "loginCancel": break
            default: throw CompanionError.server("Unsupported fixture operation")
            }
        } catch { response.error = error.localizedDescription }
        return response
    }
}
@main struct FixtureMain {
    static func main() async throws {
        guard let token = ProcessInfo.processInfo.environment["INBOXPLUS_PAIRING_KEY"] else { throw CompanionError.server("Set INBOXPLUS_PAIRING_KEY.") }
        let port = UInt16(ProcessInfo.processInfo.environment["INBOXPLUS_FIXTURE_PORT"] ?? "8765") ?? 8765
        let service = FixtureService()
        let server = try CompanionHTTPServer(port: port, token: token) { await service.call($0) }
        server.start()
        print("DEMO companion listening on 127.0.0.1:\(port)")
        while !Task.isCancelled { try await Task.sleep(for: .seconds(60)) }
    }
}
