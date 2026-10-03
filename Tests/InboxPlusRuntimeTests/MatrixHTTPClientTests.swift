import Foundation
import Testing
@testable import InboxPlusRuntime

private struct EmptyResponse: Decodable, Equatable {}

private struct WhoamiPayload: Decodable, Equatable {
    let userID: String
    private enum CodingKeys: String, CodingKey { case userID = "user_id" }
}

private actor ScriptedTransport: SynapseHTTPTransport {
    private var responses: [Result<SynapseHTTPResponse, any Error>]
    private(set) var requests: [SynapseHTTPRequest] = []

    init(_ responses: [Result<SynapseHTTPResponse, any Error>]) {
        self.responses = responses
    }

    func send(_ request: SynapseHTTPRequest) async throws -> SynapseHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { return SynapseHTTPResponse(statusCode: 500, body: Data()) }
        return try responses.removeFirst().get()
    }

    func recordedRequests() -> [SynapseHTTPRequest] { requests }
}

private func json(_ object: [String: Any], status: Int = 200) -> Result<SynapseHTTPResponse, any Error> {
    .success(
        SynapseHTTPResponse(
            statusCode: status,
            body: try! JSONSerialization.data(withJSONObject: object)
        )
    )
}

private func makeClient(
    transport: ScriptedTransport,
    token: String? = "secret-token",
    baseURL: String = "http://127.0.0.1:18008",
    maximumAttempts: Int = 4
) throws -> MatrixHTTPClient {
    try MatrixHTTPClient(
        baseURL: URL(string: baseURL)!,
        accessToken: token,
        transport: transport,
        maximumAttempts: maximumAttempts,
        retryDelay: { _ in }
    )
}

@Test(arguments: [
    "http://192.0.2.10:8008",
    "https://127.0.0.1:8008",
    "http://localhost:8008",
    "http://127.0.0.1:8008/prefix",
])
func clientRejectsNonLoopbackBaseURL(_ raw: String) {
    #expect(throws: MatrixHTTPError.nonLoopbackBaseURL) {
        try MatrixHTTPClient(baseURL: URL(string: raw)!, accessToken: "secret")
    }
}

@Test func clientAcceptsLoopbackBaseURL() throws {
    #expect(throws: Never.self) {
        try MatrixHTTPClient(baseURL: URL(string: "http://127.0.0.1:18008")!, accessToken: nil)
    }
}

@Test func pathSegmentsArePercentEncoded() async throws {
    // Break caught: an unencoded room ID splits the path and targets the wrong endpoint.
    let transport = ScriptedTransport([json([:])])
    let client = try makeClient(transport: transport)
    let _: EmptyResponse = try await client.send(
        .get,
        path: ["_matrix", "client", "v3", "rooms", "!abc:inboxplus.localhost", "state"]
    )

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url.absoluteString.contains("%21abc%3Ainboxplus.localhost"))
    #expect(!request.url.absoluteString.contains("!abc:inboxplus.localhost"))
}

@Test func accessTokenIsSentAsABearerCredential() async throws {
    let transport = ScriptedTransport([json(["user_id": "@bench:inboxplus.localhost"])])
    let client = try makeClient(transport: transport)
    let _: WhoamiPayload = try await client.send(
        .get,
        path: ["_matrix", "client", "v3", "account", "whoami"]
    )

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.headers["Authorization"] == "Bearer secret-token")
}

@Test func anAbsentTokenSendsNoAuthorizationHeader() async throws {
    let transport = ScriptedTransport([json([:])])
    let client = try makeClient(transport: transport, token: nil)
    let _: EmptyResponse = try await client.send(.get, path: ["_matrix", "client", "versions"])

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.headers["Authorization"] == nil)
}

@Test func matrixErrorBodiesDecodeIntoTypedErrors() async throws {
    let transport = ScriptedTransport([
        json(["errcode": "M_FORBIDDEN", "error": "bad token"], status: 401),
    ])
    let client = try makeClient(transport: transport)

    await #expect(throws: MatrixHTTPError.matrix(
        MatrixErrorBody(statusCode: 401, errorCode: "M_FORBIDDEN", message: "bad token")
    )) {
        let _: EmptyResponse = try await client.send(.get, path: ["_matrix", "client", "versions"])
    }
}

@Test func errorDescriptionsNeverLeakTheAccessToken() async throws {
    let transport = ScriptedTransport([
        json(["errcode": "M_FORBIDDEN", "error": "bad token"], status: 401),
    ])
    let client = try makeClient(transport: transport)

    do {
        let _: EmptyResponse = try await client.send(.get, path: ["_matrix", "client", "versions"])
        Issue.record("expected the request to fail")
    } catch {
        #expect(!String(describing: error).contains("secret-token"))
    }
}

@Test func transientStatusesAreRetriedWithAnIdenticalRequest() async throws {
    // Break caught: retrying a send with a fresh transaction ID duplicates a committed event.
    let transport = ScriptedTransport([
        json(["errcode": "M_LIMIT_EXCEEDED"], status: 429),
        json(["errcode": "M_UNKNOWN"], status: 503),
        json(["event_id": "$committed"]),
    ])
    let client = try makeClient(transport: transport)

    struct SendResponse: Decodable { let eventID: String
        private enum CodingKeys: String, CodingKey { case eventID = "event_id" }
    }
    let response: SendResponse = try await client.send(
        .put,
        path: ["_matrix", "client", "v3", "rooms", "!r:inboxplus.localhost", "send", "m.room.message", "txn-7"],
        body: Data("{}".utf8),
        idempotent: true
    )

    #expect(response.eventID == "$committed")
    let requests = await transport.recordedRequests()
    #expect(requests.count == 3)
    #expect(Set(requests.map(\.url.absoluteString)).count == 1)
    #expect(requests.allSatisfy { $0.url.absoluteString.contains("txn-7") })
}

@Test func nonIdempotentRequestsAreNeverRetried() async throws {
    let transport = ScriptedTransport([
        json(["errcode": "M_UNKNOWN"], status: 503),
        json(["event_id": "$duplicate"]),
    ])
    let client = try makeClient(transport: transport)

    await #expect(throws: MatrixHTTPError.self) {
        let _: EmptyResponse = try await client.send(
            .post,
            path: ["_matrix", "client", "v3", "createRoom"],
            body: Data("{}".utf8),
            idempotent: false
        )
    }
    #expect(await transport.recordedRequests().count == 1)
}

@Test func permanentFailuresAreNotRetried() async throws {
    let transport = ScriptedTransport([
        json(["errcode": "M_FORBIDDEN"], status: 403),
        json([:]),
    ])
    let client = try makeClient(transport: transport)

    await #expect(throws: MatrixHTTPError.self) {
        let _: EmptyResponse = try await client.send(
            .get,
            path: ["_matrix", "client", "versions"],
            idempotent: true
        )
    }
    #expect(await transport.recordedRequests().count == 1)
}

@Test func exhaustedRetriesSurfaceTheLastTransientStatus() async throws {
    let transport = ScriptedTransport([
        json(["errcode": "M_UNKNOWN"], status: 503),
        json(["errcode": "M_UNKNOWN"], status: 503),
    ])
    let client = try makeClient(transport: transport, maximumAttempts: 2)

    await #expect(throws: MatrixHTTPError.retriesExhausted(statusCode: 503, attempts: 2)) {
        let _: EmptyResponse = try await client.send(
            .get,
            path: ["_matrix", "client", "versions"],
            idempotent: true
        )
    }
    #expect(await transport.recordedRequests().count == 2)
}

@Test func malformedSuccessBodiesAreReportedAsDecodingFailures() async throws {
    let transport = ScriptedTransport([
        .success(SynapseHTTPResponse(statusCode: 200, body: Data("not json".utf8))),
    ])
    let client = try makeClient(transport: transport)

    await #expect(throws: MatrixHTTPError.self) {
        let _: WhoamiPayload = try await client.send(
            .get,
            path: ["_matrix", "client", "v3", "account", "whoami"]
        )
    }
}

@Test func queryItemsArePreservedAndEncoded() async throws {
    let transport = ScriptedTransport([json([:])])
    let client = try makeClient(transport: transport)
    let _: EmptyResponse = try await client.send(
        .get,
        path: ["_matrix", "client", "v3", "rooms", "!r:inboxplus.localhost", "messages"],
        query: [URLQueryItem(name: "dir", value: "b"), URLQueryItem(name: "limit", value: "50")]
    )

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url.query?.contains("dir=b") == true)
    #expect(request.url.query?.contains("limit=50") == true)
}
