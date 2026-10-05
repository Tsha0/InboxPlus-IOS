import Foundation
import Testing
import InboxPlusRemote
import InboxPlusFeatures
import InboxPlusCore
import InboxPlusGateway
import InboxPlusBridge

@Suite struct CompanionFailureTests {
    @Test func requestUsesAuthenticatedJSONAndCorrectEndpoint() async throws {
        let transport = try TestTransport()
        defer { transport.close() }
        var response = CompanionResponse(); response.snapshot = Fixtures.snapshot
        transport.enqueue(response)
        _ = try await transport.client.call(.init("snapshot"))
        let request = try #require(transport.requests.first)
        #expect(request.url?.path == "/v1/rpc")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(transport.config.token)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try transport.payloads().first?.operation == "snapshot")
    }
    @Test(arguments: [401, 403, 500, 503])
    func rejectsHTTPFailures(status: Int) async throws {
        let transport = try TestTransport(); defer { transport.close() }
        transport.enqueue(status: status, data: Data())
        do { _ = try await transport.client.call(.init("snapshot")); Issue.record("Expected HTTP failure") }
        catch let error as CompanionError {
            if status == 401 { if case .unauthorized = error {} else { Issue.record("Expected unauthorized") } }
            else { #expect(error.localizedDescription.contains("HTTP \(status)")) }
        }
    }
    @Test func rejectsMalformedResponseAndServerErrors() async throws {
        let transport = try TestTransport(); defer { transport.close() }
        transport.enqueue(status: 200, data: Data("broken-json".utf8))
        await #expect(throws: DecodingError.self) { try await transport.client.call(.init("snapshot")) }
        var error = CompanionResponse(); error.error = "Bridge unavailable"; transport.enqueue(error)
        await #expect(throws: CompanionError.self) { try await transport.client.call(.init("snapshot")) }
        transport.enqueue(CompanionResponse())
        await #expect(throws: CompanionError.self) { try await CompanionGateway(client: transport.client).loadSnapshot() }
    }
    @Test(arguments: [URLError.timedOut, .notConnectedToInternet, .networkConnectionLost, .cancelled])
    func preservesNetworkFailures(code: URLError.Code) async throws {
        let transport = try TestTransport(); defer { transport.close() }
        transport.enqueue(error: URLError(code))
        do { _ = try await transport.client.call(.init("snapshot")); Issue.record("Expected network failure") }
        catch let error as URLError { #expect(error.code == code) }
    }
    @Test func missingMediaAndReceiptsAreRejected() async throws {
        let transport = try TestTransport(); defer { transport.close() }
        transport.enqueue(CompanionResponse())
        await #expect(throws: CompanionError.self) { try await CompanionMediaFetcher(client: transport.client).fetch(MediaHandle(source: "test", mimeType: "image/png")) }
        transport.enqueue(CompanionResponse())
        await #expect(throws: CompanionError.self) { try await CompanionGateway(client: transport.client).sendText("hello", to: Fixtures.telegramRoute) }
    }
    @Test func attachmentTransfersExactBytesAndRoute() async throws {
        let transport = try TestTransport(); defer { transport.close() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let data = Data("mobile attachment".utf8); try data.write(to: file)
        var receipt = CompanionResponse(); receipt.receipt = .init(messageID: "sent", route: Fixtures.telegramRoute, deliveryState: .acknowledged)
        transport.enqueue(receipt)
        var snapshot = CompanionResponse(); snapshot.snapshot = Fixtures.snapshot; transport.enqueue(snapshot)
        let attachment = OutgoingAttachment(fileURL: file, kind: .file, filename: "test.txt", mimeType: "text/plain", byteCount: data.count)
        _ = try await CompanionGateway(client: transport.client).send(attachment, to: Fixtures.telegramRoute)
        let request = try #require(transport.payloads().first)
        #expect(request.operation == "sendAttachment"); #expect(request.data == data)
        #expect(request.route == Fixtures.telegramRoute); #expect(request.filename == "test.txt")
    }
    @Test func oversizedOrGrownAttachmentIsRejectedBeforeNetworkRequest() async throws {
        let transport = try TestTransport(); defer { transport.close() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let handle = try FileHandle(forWritingTo: file); try handle.truncate(atOffset: 25 * 1024 * 1024 + 1); try handle.close()
        for declaredSize in [1, 25 * 1024 * 1024 + 1] {
            let attachment = OutgoingAttachment(fileURL: file, kind: .file, filename: "large", mimeType: "application/octet-stream", byteCount: declaredSize)
            await #expect(throws: CompanionError.self) { try await CompanionGateway(client: transport.client).send(attachment, to: Fixtures.telegramRoute) }
        }
        #expect(transport.requests.isEmpty)
    }
    @Test func loginForwardsSessionStepsAndCancellation() async throws {
        let transport = try TestTransport(); defer { transport.close() }
        var prepared = CompanionResponse(); prepared.sessionID = "session-1"; prepared.flows = []
        transport.enqueue(prepared)
        let login = CompanionLoginSession(client: transport.client, platform: .telegram)
        _ = try await login.loginFlows()
        transport.enqueue(CompanionResponse())
        await #expect(throws: CompanionError.self) { try await login.startLogin(flowID: "phone") }
        transport.enqueue(CompanionResponse())
        try await login.cancelLogin(loginID: "login-1")
        let payloads = try transport.payloads()
        #expect(payloads.map(\.operation) == ["loginPrepare", "loginStart", "loginCancel"])
        #expect(payloads[0].platform == .telegram)
        #expect(payloads[1].sessionID == "session-1"); #expect(payloads[1].body == "phone")
        #expect(payloads[2].loginID == "login-1"); #expect(payloads[2].sessionID == "session-1")
    }
    @Test func pollingReportsConnectionLossAndRecoversWithoutDuplicateMessages() async throws {
        let transport = try TestTransport(); defer { transport.close() }
        let clock = PollingClock()
        let gateway = CompanionGateway(client: transport.client, sleep: { try await clock.sleep() })
        var initial = CompanionResponse(); initial.snapshot = Fixtures.snapshot; transport.enqueue(initial)
        _ = try await gateway.loadSnapshot()
        let events = await gateway.events(); var iterator = events.makeAsyncIterator()
        await clock.waitForSleep(1)
        transport.enqueue(error: URLError(.networkConnectionLost)); await clock.advance()
        for _ in Fixtures.snapshot.accounts {
            guard case let .connectionChanged(_, connected) = await iterator.next() else { Issue.record("Expected disconnect"); return }
            #expect(!connected)
        }
        await clock.waitForSleep(2)
        var recovered = initial
        recovered.snapshot?.messagesByRoute[Fixtures.telegramRoute]?.append(Message(id: "new", route: Fixtures.telegramRoute, senderIdentityID: nil, body: "Recovered", timestamp: Date(), deliveryState: .acknowledged))
        transport.enqueue(recovered); await clock.advance()
        for _ in Fixtures.snapshot.accounts {
            guard case let .connectionChanged(_, connected) = await iterator.next() else { Issue.record("Expected reconnect"); return }
            #expect(connected)
        }
        guard case let .messageUpserted(message) = await iterator.next() else { Issue.record("Expected new message"); return }
        #expect(message.id == "new")
        await clock.waitForSleep(3)
        transport.enqueue(recovered); await clock.advance()
        for _ in Fixtures.snapshot.accounts { _ = await iterator.next() }
        await clock.waitForSleep(4)
        // A marker proves the unchanged snapshot emitted no duplicate message before it.
        await gateway.setPaused(true, accountID: "marker")
        guard case let .connectionChanged(id, _) = await iterator.next() else { Issue.record("Duplicate message"); return }
        #expect(id == "marker")
        await clock.cancel()
    }
}

private actor PollingClock {
    private var count = 0
    private var sleeper: CheckedContinuation<Void, any Error>?
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func sleep() async throws {
        try await withCheckedThrowingContinuation { continuation in
            sleeper = continuation; count += 1
            let ready = waiters.filter { $0.0 <= count }; waiters.removeAll { $0.0 <= count }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForSleep(_ expected: Int) async {
        if count >= expected { return }
        await withCheckedContinuation { waiters.append((expected, $0)) }
    }
    func advance() { sleeper?.resume(); sleeper = nil }
    func cancel() { sleeper?.resume(throwing: CancellationError()); sleeper = nil }
}

private final class TestTransport: @unchecked Sendable {
    struct Reply { let status: Int; let data: Data; let error: (any Error)? }
    let config: CompanionConfiguration
    let client: CompanionClient
    private let session: URLSession
    private let lock = NSLock()
    private var replies: [Reply] = []
    private var recorded: [URLRequest] = []
    private var bodies: [Data] = []
    var requests: [URLRequest] { lock.withLock { recorded } }
    init() throws {
        let host = "\(UUID().uuidString.lowercased()).example"
        config = try CompanionConfiguration(address: "https://\(host)", token: String(repeating: "a", count: 32))
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [TestURLProtocol.self]
        session = URLSession(configuration: configuration)
        client = CompanionClient(configuration: config, session: session)
        TestURLProtocol.registry.add(self, host: host)
    }
    func close() { session.invalidateAndCancel(); TestURLProtocol.registry.remove(host: config.address.host!) }
    func enqueue(_ response: CompanionResponse) { enqueue(status: 200, data: try! JSONEncoder().encode(response)) }
    func enqueue(status: Int, data: Data) { lock.withLock { replies.append(Reply(status: status, data: data, error: nil)) } }
    func enqueue(error: any Error) { lock.withLock { replies.append(Reply(status: 0, data: Data(), error: error)) } }
    func payloads() throws -> [CompanionRequest] { try lock.withLock { try bodies.map { try JSONDecoder().decode(CompanionRequest.self, from: $0) } } }
    func reply(to request: URLRequest) -> Reply {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count)) }
        }
        return lock.withLock {
            recorded.append(request); bodies.append(body)
            return replies.isEmpty ? Reply(status: 500, data: Data(), error: nil) : replies.removeFirst()
        }
    }
}
private final class TransportRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [String: TestTransport] = [:]
    func add(_ transport: TestTransport, host: String) { lock.withLock { transports[host] = transport } }
    func remove(host: String) { lock.withLock { transports[host] = nil } }
    func get(host: String) -> TestTransport? { lock.withLock { transports[host] } }
}
private final class TestURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = TransportRegistry()
    override class func canInit(with request: URLRequest) -> Bool { registry.get(host: request.url?.host ?? "") != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let transport = Self.registry.get(host: request.url?.host ?? "") else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let reply = transport.reply(to: request)
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
