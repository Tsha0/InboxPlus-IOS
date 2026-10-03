import Darwin
import Foundation
import Testing
@testable import InboxPlusRuntime

@Test func liveProcessWithFailedAuthenticatedRequestIsDegraded() async throws {
    // Break caught: a responsive unauthenticated endpoint is mistaken for complete health.
    let fixture = try HealthCheckerFixture(steps: [
        .response(status: 200, json: ["versions": ["v1.11"]]),
        .response(status: 401, json: ["errcode": "M_UNKNOWN_TOKEN"]),
    ], storedCredential: .valid)

    let health = await fixture.checker.check(snapshot: .healthCandidate)

    #expect(health == .degraded(.matrixRequestFailed(status: 401)))
}

@Test func processIdentityMismatchStopsBeforeAnyHTTP() async throws {
    // Break caught: health requests are sent for a reused PID that no longer names the managed child.
    let fixture = try HealthCheckerFixture(
        steps: [],
        storedCredential: .valid,
        identityStatus: .mismatched(actual: .replacement)
    )

    let health = await fixture.checker.check(snapshot: .healthCandidate)

    #expect(health == .degraded(.processIdentityMismatch(
        expected: .expected,
        actual: .replacement
    )))
    #expect(await fixture.transport.requests().isEmpty)
}

@Test func versionsAndAuthenticationFailuresRemainDistinct() async throws {
    // Break caught: diagnostics collapse endpoint readiness and token authentication into one opaque failure.
    let versions = try HealthCheckerFixture(
        steps: [.response(status: 503, json: ["error": "starting"])],
        storedCredential: .valid
    )
    let auth = try HealthCheckerFixture(steps: [
        .response(status: 200, json: ["versions": ["v1.11"]]),
        .response(status: 403, json: ["errcode": "M_FORBIDDEN"]),
    ], storedCredential: .valid)

    #expect(await versions.checker.check(snapshot: .healthCandidate) ==
        .degraded(.versionsRequestFailed(status: 503)))
    #expect(await auth.checker.check(snapshot: .healthCandidate) ==
        .degraded(.matrixRequestFailed(status: 403)))
}

@Test func firstVersionsSuccessProvisionsAndPersistsDedicatedProbe() async throws {
    // Break caught: the shared registration secret is reused for health or the probe token is not persisted.
    let fixture = try HealthCheckerFixture(steps: [
        .response(status: 200, json: ["versions": ["v1.11"]]),
        .response(status: 200, json: ["nonce": "nonce-1"]),
        .response(status: 200, json: [
            "access_token": "probe-token",
            "user_id": "@inboxplus_probe:inboxplus.localhost",
            "home_server": "inboxplus.localhost",
            "device_id": "PROBE",
        ]),
        .response(status: 200, json: ["user_id": "@inboxplus_probe:inboxplus.localhost"]),
    ])

    let health = await fixture.checker.check(snapshot: .healthCandidate)
    let credential = try fixture.store.load()
    let requests = await fixture.transport.requests()

    guard case .healthy = health else {
        Issue.record("expected healthy, got \(health)")
        return
    }
    #expect(credential == .valid)
    #expect(try fixture.store.fileMode() == 0o600)
    #expect(requests.map(\.url.path) == [
        "/_matrix/client/versions",
        "/_synapse/admin/v1/register",
        "/_synapse/admin/v1/register",
        "/_matrix/client/v3/account/whoami",
    ])
    #expect(requests.last?.headers["Authorization"] == "Bearer probe-token")
    let registration = try #require(requests[2].body)
    let registrationJSON = try #require(
        JSONSerialization.jsonObject(with: registration) as? [String: Any]
    )
    #expect(registrationJSON["username"] as? String == "inboxplus_probe")
    #expect(registrationJSON["admin"] as? Bool == false)
    #expect(registrationJSON["mac"] as? String == "8766d71dcb93c4e39f30151f619646ca28ed3d7a")
    #expect(!String(decoding: registration, as: UTF8.self).contains("registration-secret"))
}

@Test func laterHealthCheckReusesTokenWithoutRegistration() async throws {
    // Break caught: every health check creates a new account or resends the registration secret.
    let fixture = try HealthCheckerFixture(steps: [
        .response(status: 200, json: ["versions": ["v1.11"]]),
        .response(status: 200, json: ["user_id": "@inboxplus_probe:inboxplus.localhost"]),
    ], storedCredential: .valid)

    _ = await fixture.checker.check(snapshot: .healthCandidate)
    let requests = await fixture.transport.requests()

    #expect(requests.count == 2)
    #expect(requests.last?.headers["Authorization"] == "Bearer probe-token")
}

@Test func whoamiMustMatchTheExactDedicatedProbeIdentity() async throws {
    // Break caught: a valid token for a different local account is accepted as the health principal.
    let fixture = try HealthCheckerFixture(steps: [
        .response(status: 200, json: ["versions": ["v1.11"]]),
        .response(status: 200, json: ["user_id": "@admin:inboxplus.localhost"]),
    ], storedCredential: .valid)

    #expect(await fixture.checker.check(snapshot: .healthCandidate) == .degraded(
        .probeIdentityMismatch(
            expected: "@inboxplus_probe:inboxplus.localhost",
            actual: "@admin:inboxplus.localhost"
        )
    ))
}

@Test(arguments: [
    "http://192.0.2.10:8008",
    "https://127.0.0.1:8008",
    "http://localhost:8008",
    "http://127.0.0.1:8008/base",
])
func healthEndpointMustBeExactLoopbackHTTPOrigin(_ rawURL: String) throws {
    // Break caught: health follows a remote, TLS-proxied, hostname, or path-prefixed endpoint.
    let credentialFixture = try temporaryCredentialStore()
    defer { try? FileManager.default.removeItem(at: credentialFixture.root) }
    #expect(throws: HealthCheckerError.invalidBaseURL(URL(string: rawURL)!)) {
        try SynapseHealthChecker(
            baseURL: URL(string: rawURL)!,
            serverName: "inboxplus.localhost",
            registrationSecret: "registration-secret",
            credentialStore: credentialFixture.store,
            transport: FakeHealthTransport(steps: []),
            identityStatus: { _ in .matching }
        )
    }
}

@Test(arguments: [
    HealthTransportError.redirectRejected,
    .responseTooLarge(limit: 65_536),
    .timedOut,
])
func transportSafetyFailureDegradesVersionsLayer(_ error: HealthTransportError) async throws {
    // Break caught: redirects, oversized bodies, or timeouts are retried as if endpoint readiness succeeded.
    let fixture = try HealthCheckerFixture(steps: [.failure(error)])

    #expect(await fixture.checker.check(snapshot: .healthCandidate) ==
        .degraded(.versionsTransportFailure(error)))
}

@Test func credentialStoreRejectsSymlinkWithoutChangingExternalFile() throws {
    // Break caught: probe token publication follows an attacker-selected symlink outside the profile.
    let fixture = try temporaryCredentialStore()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let outside = fixture.root.appendingPathComponent("outside-token")
    try Data("sentinel".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
        at: fixture.store.credentialFile,
        withDestinationURL: outside
    )

    #expect(throws: ProbeCredentialStoreError.self) {
        try fixture.store.save(.valid)
    }
    #expect(try String(contentsOf: outside, encoding: .utf8) == "sentinel")
}

@Test func credentialStoreRejectsPermissionDriftAndRedactsSecretValues() throws {
    // Break caught: a group-readable token file is trusted, or its contents escape through diagnostics.
    let fixture = try temporaryCredentialStore()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.store.save(.valid)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: fixture.store.credentialFile.path
    )

    do {
        _ = try fixture.store.load()
        Issue.record("expected permission rejection")
    } catch {
        let diagnostic = String(describing: error)
        #expect(!diagnostic.contains("probe-token"))
        #expect(!diagnostic.contains("registration-secret"))
    }
}

@Test func credentialStoreRejectsProfileAncestorReplacementBeforePublishing() throws {
    // Break caught: a retained profile path is swapped for a symlink before token publication.
    let fixture = try temporaryCredentialStore()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let moved = fixture.root.appendingPathComponent("moved-profile")
    let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.moveItem(at: fixture.store.profileRoot, to: moved)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outside.path)
    try FileManager.default.createSymbolicLink(at: fixture.store.profileRoot, withDestinationURL: outside)

    #expect(throws: ProbeCredentialStoreError.self) {
        try fixture.store.save(.valid)
    }
    #expect(!FileManager.default.fileExists(
        atPath: outside.appendingPathComponent("configuration/inboxplus-probe-credential.json").path
    ))
}

@Test func credentialStoreRejectsHardLinkedCredential() throws {
    // Break caught: a second pathname keeps access to the token inode trusted by the runtime.
    let fixture = try temporaryCredentialStore()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.store.save(.valid)
    let externalLink = fixture.root.appendingPathComponent("linked-token")
    #expect(link(fixture.store.credentialFile.path, externalLink.path) == 0)

    #expect(throws: ProbeCredentialStoreError.unsafeCredentialFile) {
        try fixture.store.load()
    }
}

private final class HealthCheckerFixture {
    let root: URL
    let store: SynapseProbeCredentialStore
    let transport: FakeHealthTransport
    let checker: SynapseHealthChecker

    deinit { try? FileManager.default.removeItem(at: root) }

    init(
        steps: [FakeHealthTransport.Step],
        storedCredential: ProbeCredential? = nil,
        identityStatus: ManagedProcessIdentityStatus = .matching
    ) throws {
        let credentialFixture = try temporaryCredentialStore()
        root = credentialFixture.root
        store = credentialFixture.store
        if let storedCredential { try store.save(storedCredential) }
        transport = FakeHealthTransport(steps: steps)
        checker = try SynapseHealthChecker(
            baseURL: URL(string: "http://127.0.0.1:18008")!,
            serverName: "inboxplus.localhost",
            registrationSecret: "registration-secret",
            credentialStore: store,
            transport: transport,
            password: { "probe-password" },
            identityStatus: { _ in identityStatus }
        )
    }
}

private actor FakeHealthTransport: SynapseHTTPTransport {
    enum Step: Sendable {
        case response(status: Int, json: [String: JSONValue])
        case failure(HealthTransportError)
    }

    private var steps: [Step]
    private var seen: [SynapseHTTPRequest] = []

    init(steps: [Step]) { self.steps = steps }

    func send(_ request: SynapseHTTPRequest) async throws -> SynapseHTTPResponse {
        seen.append(request)
        guard !steps.isEmpty else { throw HealthTransportError.invalidResponse }
        let step = steps.removeFirst()
        switch step {
        case let .response(status, json):
            return SynapseHTTPResponse(
                statusCode: status,
                body: try JSONEncoder().encode(json)
            )
        case let .failure(error):
            throw error
        }
    }

    func requests() -> [SynapseHTTPRequest] { seen }
}

private enum JSONValue: Codable, Sendable, ExpressibleByStringLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral {
    case string(String)
    case bool(Bool)
    case strings([String])

    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: String...) { self = .strings(elements) }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        self = .strings(try container.decode([String].self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .strings(value): try container.encode(value)
        }
    }
}

private struct CredentialStoreFixture {
    let root: URL
    let store: SynapseProbeCredentialStore
}

private func temporaryCredentialStore() throws -> CredentialStoreFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("InboxPlusHealthTests-\(UUID().uuidString)", isDirectory: true)
    let profile = root.appendingPathComponent("profile", isDirectory: true)
    let configuration = profile.appendingPathComponent("configuration", isDirectory: true)
    try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profile.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configuration.path)
    return CredentialStoreFixture(
        root: root,
        store: try SynapseProbeCredentialStore(profileRoot: profile)
    )
}

private extension ProbeCredential {
    static let valid = ProbeCredential(
        userID: "@inboxplus_probe:inboxplus.localhost",
        accessToken: "probe-token"
    )
}

private extension ManagedProcessIdentity {
    static let expected = ManagedProcessIdentity(
        executablePath: "/opt/inboxplus/synapse_homeserver",
        launchTimestamp: Date(timeIntervalSince1970: 1_789_000_000),
        processIdentifier: 42,
        startIdentityToken: "42:1789000000:0"
    )

    static let replacement = ManagedProcessIdentity(
        executablePath: "/usr/bin/unrelated",
        launchTimestamp: Date(timeIntervalSince1970: 1_789_000_001),
        processIdentifier: 42,
        startIdentityToken: "42:1789000001:0"
    )
}

private extension RuntimeSnapshot {
    static let healthCandidate = try! RuntimeSnapshot(
        phase: .healthy,
        processIdentity: .expected,
        loopbackPort: 18_008,
        restartCount: 0,
        lastHealthResult: nil,
        diagnosticLogDirectory: nil,
        lastError: nil
    )
}
