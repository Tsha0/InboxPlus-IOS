import Foundation
import Testing
import InboxPlusRemote
import InboxPlusFeatures
import InboxPlusGateway
import InboxPlusCore
import InboxPlusCompanionServer

@Test func pairingRequiresSecureTransportAndStrongKey() throws {
    #expect(throws: CompanionError.self) { try CompanionConfiguration(address: "http://mac.local:8765", token: String(repeating: "a", count: 32)) }
    #expect(throws: CompanionError.self) { try CompanionConfiguration(address: "https://user:password@mac.example", token: String(repeating: "a", count: 32)) }
    #expect(throws: CompanionError.self) { try CompanionConfiguration(address: "https://mac.example", token: "short") }
    #expect(throws: CompanionError.self) { try CompanionConfiguration(address: "https://mac.example?token=secret", token: String(repeating: "a", count: 32)) }
    #expect(try CompanionConfiguration(address: "https://mac.example", token: String(repeating: "a", count: 32)).address.host == "mac.example")
    #expect(try CompanionConfiguration(address: "http://127.0.0.1:8765", token: String(repeating: "a", count: 32)).address.port == 8765)
}
@Test func wireSnapshotPreservesAccountRoutingAndMessages() throws {
    let seed = Fixtures.snapshot
    var response = CompanionResponse(); response.snapshot = seed
    let decoded = try JSONDecoder().decode(CompanionResponse.self, from: JSONEncoder().encode(response))
    #expect(decoded.snapshot?.accounts == seed.accounts)
    #expect(decoded.snapshot?.conversations == seed.conversations)
    #expect(decoded.snapshot?.messagesByRoute == seed.messagesByRoute)
}
@Test func pairingKeyComparisonRejectsPrefixesAndChanges() {
    #expect(CompanionHTTPServer.matches("Bearer abc", "Bearer abc"))
    #expect(!CompanionHTTPServer.matches("Bearer ab", "Bearer abc"))
    #expect(!CompanionHTTPServer.matches("Bearer abd", "Bearer abc"))
}
@Test func companionRoundTripAuthenticatesAndSendsToCorrectConversation() async throws {
    let token = UUID().uuidString
    let gateway = InMemoryMessagingGateway(seed: Fixtures.snapshot)
    let port: UInt16 = 18765
    let server = try CompanionHTTPServer(port: port, token: token) { request in
        var response = CompanionResponse()
        do {
            if request.operation == "snapshot" { response.snapshot = try await gateway.loadSnapshot() }
            else if request.operation == "sendText", let route = request.route, let body = request.body {
                response.receipt = try await gateway.sendText(body, to: route)
            } else { response.error = "Unsupported operation" }
        } catch { response.error = error.localizedDescription }
        return response
    }
    server.start(); defer { server.stop() }
    let client = CompanionClient(configuration: try .init(address: "http://127.0.0.1:\(port)", token: token))
    var snapshot: MessagingSnapshot?
    for _ in 0..<30 {
        do { snapshot = try await client.call(.init("snapshot")).snapshot; break }
        catch { try await Task.sleep(for: .milliseconds(50)) }
    }
    #expect(snapshot?.accounts == Fixtures.snapshot.accounts)
    let remote = CompanionGateway(client: client)
    let receipt = try await remote.sendText("iOS integration test", to: Fixtures.whatsAppRoute)
    #expect(receipt.route == Fixtures.whatsAppRoute)
    #expect(receipt.deliveryState == .acknowledged)
    let updated = try await remote.loadSnapshot()
    #expect(updated.messagesByRoute[Fixtures.whatsAppRoute]?.contains { $0.body == "iOS integration test" } == true)
    #expect(updated.messagesByRoute[Fixtures.instagramRoute]?.contains { $0.body == "iOS integration test" } == false)
    let unauthorized = CompanionClient(configuration: try .init(address: "http://127.0.0.1:\(port)", token: String(repeating: "x", count: 32)))
    await #expect(throws: CompanionError.self) { try await unauthorized.call(.init("snapshot")) }
}
