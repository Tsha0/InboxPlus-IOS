import Foundation
import InboxPlusCore
import InboxPlusFeatures
import InboxPlusGateway
import InboxPlusRemote
import InboxPlusCompanionServer

@main struct FixtureMain {
    static func main() async throws {
        guard let token = ProcessInfo.processInfo.environment["INBOXPLUS_PAIRING_KEY"] else { throw CompanionError.server("Set INBOXPLUS_PAIRING_KEY.") }
        let gateway = InMemoryMessagingGateway(seed: Fixtures.demoSnapshot)
        let server = try CompanionHTTPServer(token: token) { request in
            var response = CompanionResponse()
            do {
                switch request.operation {
                case "snapshot": response.snapshot = try await gateway.loadSnapshot()
                case "sendText":
                    guard let body = request.body, let route = request.route else { throw CompanionError.invalidResponse }
                    response.receipt = try await gateway.sendText(body, to: route)
                default: throw CompanionError.server("Fixture supports snapshot and sendText only.")
                }
            } catch { response.error = error.localizedDescription }
            return response
        }
        server.start()
        print("DEMO companion listening on 127.0.0.1:8765")
        while !Task.isCancelled { try await Task.sleep(for: .seconds(60)) }
    }
}
