import CryptoKit
import Darwin
import Foundation

public enum HealthResult: Sendable, Equatable {
    case healthy(latency: Duration)
    case degraded(HealthFailure)
    case stopped
}

public enum HealthFailure: Error, Sendable, Equatable {
    case processIdentityMismatch(
        expected: ManagedProcessIdentity,
        actual: ManagedProcessIdentity
    )
    case processIdentityIndeterminate(ManagedProcessError)
    case versionsRequestFailed(status: Int)
    case versionsTransportFailure(HealthTransportError)
    case matrixRequestFailed(status: Int)
    case matrixTransportFailure(HealthTransportError)
    case invalidResponse(layer: HealthLayer)
    case probeProvisioningFailed(ProbeProvisioningFailure)
    case probeIdentityMismatch(expected: String, actual: String)

    var processIsUnavailable: Bool {
        switch self {
        case .processIdentityMismatch, .processIdentityIndeterminate:
            true
        default:
            false
        }
    }
}

public enum HealthLayer: String, Sendable, Equatable {
    case versions
    case registration
    case authentication
}

public enum ProbeProvisioningFailure: Error, Sendable, Equatable {
    case credentialStore
    case nonceRequest(status: Int)
    case registrationRequest(status: Int)
    case transport(HealthTransportError)
    case invalidResponse
    case unexpectedIdentity(expected: String, actual: String)
}

public protocol SynapseHealthChecking: Sendable {
    func check(snapshot: RuntimeSnapshot) async -> HealthResult
}

public enum SynapseHTTPMethod: String, Sendable, Equatable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
}

public struct SynapseHTTPRequest: Sendable, Equatable {
    public let method: SynapseHTTPMethod
    public let url: URL
    public let headers: [String: String]
    public let body: Data?
    public let timeout: Duration
    public let maximumResponseBytes: Int

    public init(
        method: SynapseHTTPMethod,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: Duration = .seconds(2),
        maximumResponseBytes: Int = 65_536
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.maximumResponseBytes = maximumResponseBytes
    }
}

public struct SynapseHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public protocol SynapseHTTPTransport: Sendable {
    func send(_ request: SynapseHTTPRequest) async throws -> SynapseHTTPResponse
}

public enum HealthTransportError: Error, Sendable, Equatable {
    case invalidRequest
    case invalidResponse
    case redirectRejected
    case responseTooLarge(limit: Int)
    case timedOut
    case requestFailed(code: Int)
}

public final class URLSessionSynapseHTTPTransport: SynapseHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: SynapseHTTPRequest) async throws -> SynapseHTTPResponse {
        guard request.maximumResponseBytes > 0,
              request.url.scheme == "http",
              request.url.host == "127.0.0.1"
        else {
            throw HealthTransportError.invalidRequest
        }
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = max(0.001, request.timeout.timeInterval)
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let delegate = RedirectRejectingTaskDelegate()
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest, delegate: delegate)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw HealthTransportError.invalidResponse
            }
            var body = Data()
            body.reserveCapacity(min(request.maximumResponseBytes, 4_096))
            for try await byte in bytes {
                guard body.count < request.maximumResponseBytes else {
                    throw HealthTransportError.responseTooLarge(limit: request.maximumResponseBytes)
                }
                body.append(byte)
            }
            if delegate.didRejectRedirect {
                throw HealthTransportError.redirectRejected
            }
            return SynapseHTTPResponse(statusCode: httpResponse.statusCode, body: body)
        } catch let error as HealthTransportError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw HealthTransportError.timedOut
        } catch let error as URLError {
            throw HealthTransportError.requestFailed(code: error.errorCode)
        } catch {
            throw HealthTransportError.invalidResponse
        }
    }
}

private final class RedirectRejectingTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var rejected = false

    var didRejectRedirect: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rejected
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        rejected = true
        lock.unlock()
        completionHandler(nil)
    }
}

public struct ProbeCredential: Codable, Sendable, Equatable {
    public let userID: String
    public let accessToken: String

    public init(userID: String, accessToken: String) {
        self.userID = userID
        self.accessToken = accessToken
    }
}

public struct SynapseProbeCredentialStore: Sendable {
    public static let filePermissions = 0o600
    public let profileRoot: URL
    public let credentialFile: URL

    public init(profileRoot: URL) throws {
        guard profileRoot.isFileURL,
              let resolved = realpath(profileRoot.path, nil)
        else {
            throw ProbeCredentialStoreError.invalidProfileRoot
        }
        defer { free(resolved) }
        self.profileRoot = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        credentialFile = self.profileRoot
            .appendingPathComponent("configuration", isDirectory: true)
            .appendingPathComponent("inboxplus-probe-credential.json", isDirectory: false)
    }

    public func load() throws -> ProbeCredential? {
        try withConfigurationDirectory { directory in
            let descriptor = openat(directory, credentialFile.lastPathComponent, O_RDONLY | O_NOFOLLOW)
            if descriptor < 0, errno == ENOENT { return nil }
            guard descriptor >= 0 else { throw ProbeCredentialStoreError.unsafeCredentialFile }
            defer { _ = close(descriptor) }
            try validateCredentialFile(descriptor)
            let data = try readBounded(descriptor, maximumBytes: 65_536)
            do {
                let credential = try JSONDecoder().decode(ProbeCredential.self, from: data)
                guard !credential.userID.isEmpty, !credential.accessToken.isEmpty else {
                    throw ProbeCredentialStoreError.invalidCredential
                }
                return credential
            } catch let error as ProbeCredentialStoreError {
                throw error
            } catch {
                throw ProbeCredentialStoreError.invalidCredential
            }
        }
    }

    public func save(_ credential: ProbeCredential) throws {
        guard !credential.userID.isEmpty, !credential.accessToken.isEmpty else {
            throw ProbeCredentialStoreError.invalidCredential
        }
        let data = try JSONEncoder().encode(credential)
        try withConfigurationDirectory { directory in
            let existing = openat(directory, credentialFile.lastPathComponent, O_RDONLY | O_NOFOLLOW)
            if existing >= 0 {
                defer { _ = close(existing) }
                try validateCredentialFile(existing)
            } else if errno != ENOENT {
                throw ProbeCredentialStoreError.unsafeCredentialFile
            }

            let temporaryName = ".inboxplus-probe-\(UUID().uuidString).tmp"
            let temporary = openat(
                directory,
                temporaryName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                mode_t(Self.filePermissions)
            )
            guard temporary >= 0 else { throw ProbeCredentialStoreError.cannotWrite }
            var published = false
            defer {
                _ = close(temporary)
                if !published { _ = unlinkat(directory, temporaryName, 0) }
            }
            guard fchmod(temporary, mode_t(Self.filePermissions)) == 0 else {
                throw ProbeCredentialStoreError.cannotWrite
            }
            try writeAll(data, to: temporary)
            guard fsync(temporary) == 0 else { throw ProbeCredentialStoreError.cannotWrite }
            guard renameat(
                directory,
                temporaryName,
                directory,
                credentialFile.lastPathComponent
            ) == 0 else {
                throw ProbeCredentialStoreError.cannotWrite
            }
            published = true
            guard fsync(directory) == 0 else { throw ProbeCredentialStoreError.cannotWrite }
        }
    }

    func fileMode() throws -> Int {
        try withConfigurationDirectory { directory in
            let descriptor = openat(directory, credentialFile.lastPathComponent, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw ProbeCredentialStoreError.unsafeCredentialFile }
            defer { _ = close(descriptor) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else {
                throw ProbeCredentialStoreError.unsafeCredentialFile
            }
            return Int(metadata.st_mode & 0o777)
        }
    }

    private func withConfigurationDirectory<T>(
        _ body: (Int32) throws -> T
    ) throws -> T {
        let profile = try openAbsoluteDirectory(profileRoot)
        defer { _ = close(profile) }
        try validatePrivateDirectory(profile)
        let configuration = openat(profile, "configuration", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard configuration >= 0 else { throw ProbeCredentialStoreError.unsafeConfigurationDirectory }
        defer { _ = close(configuration) }
        try validatePrivateDirectory(configuration)
        return try body(configuration)
    }

    private func openAbsoluteDirectory(_ url: URL) throws -> Int32 {
        guard url.path.hasPrefix("/") else { throw ProbeCredentialStoreError.invalidProfileRoot }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw ProbeCredentialStoreError.invalidProfileRoot }
        for component in url.pathComponents.dropFirst() {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            _ = close(descriptor)
            guard next >= 0 else { throw ProbeCredentialStoreError.invalidProfileRoot }
            descriptor = next
        }
        return descriptor
    }

    private func validatePrivateDirectory(_ descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0
        else {
            throw ProbeCredentialStoreError.unsafeConfigurationDirectory
        }
    }

    private func validateCredentialFile(_ descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o777 == mode_t(Self.filePermissions)
        else {
            throw ProbeCredentialStoreError.unsafeCredentialFile
        }
    }

    private func readBounded(_ descriptor: Int32, maximumBytes: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0, errno == EINTR { continue }
            guard count > 0, data.count + count <= maximumBytes else {
                throw ProbeCredentialStoreError.invalidCredential
            }
            data.append(buffer, count: count)
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ProbeCredentialStoreError.cannotWrite }
                offset += count
            }
        }
    }
}

public enum ProbeCredentialStoreError: Error, Sendable, Equatable {
    case invalidProfileRoot
    case unsafeConfigurationDirectory
    case unsafeCredentialFile
    case invalidCredential
    case cannotWrite
}

public enum HealthCheckerError: Error, Sendable, Equatable {
    case invalidBaseURL(URL)
    case invalidServerName
    case emptyRegistrationSecret
}

public actor SynapseHealthChecker: SynapseHealthChecking {
    // Synapse 1.158.0 rejects localparts beginning with `_` as M_INVALID_USERNAME.
    // Keep this dedicated account name stable and compatible with that pinned runtime.
    public static let probeLocalpart = "inboxplus_probe"

    public typealias IdentityStatus = @Sendable (
        ManagedProcessIdentity
    ) async -> ManagedProcessIdentityStatus
    public typealias Password = @Sendable () -> String

    private let baseURL: URL
    private let expectedProbeUserID: String
    private let registrationSecret: String
    private let credentialStore: SynapseProbeCredentialStore
    private let transport: any SynapseHTTPTransport
    private let identityStatus: IdentityStatus
    private let requestTimeout: Duration
    private let maximumResponseBytes: Int
    private let password: Password

    public init(
        baseURL: URL,
        serverName: String,
        registrationSecret: String,
        credentialStore: SynapseProbeCredentialStore,
        transport: any SynapseHTTPTransport = URLSessionSynapseHTTPTransport(),
        requestTimeout: Duration = .seconds(2),
        maximumResponseBytes: Int = 65_536,
        password: @escaping Password = { UUID().uuidString + UUID().uuidString },
        identityStatus: @escaping IdentityStatus = SynapseHealthChecker.systemIdentityStatus
    ) throws {
        guard Self.isValidBaseURL(baseURL) else {
            throw HealthCheckerError.invalidBaseURL(baseURL)
        }
        guard !serverName.isEmpty, !serverName.contains("/") else {
            throw HealthCheckerError.invalidServerName
        }
        guard !registrationSecret.isEmpty else {
            throw HealthCheckerError.emptyRegistrationSecret
        }
        self.baseURL = baseURL
        expectedProbeUserID = "@\(Self.probeLocalpart):\(serverName)"
        self.registrationSecret = registrationSecret
        self.credentialStore = credentialStore
        self.transport = transport
        self.requestTimeout = requestTimeout
        self.maximumResponseBytes = maximumResponseBytes
        self.password = password
        self.identityStatus = identityStatus
    }

    public func check(snapshot: RuntimeSnapshot) async -> HealthResult {
        guard let identity = snapshot.processIdentity, snapshot.loopbackPort != nil else {
            return .stopped
        }
        switch await identityStatus(identity) {
        case .matching:
            break
        case .exited:
            return .stopped
        case let .mismatched(actual):
            return .degraded(.processIdentityMismatch(expected: identity, actual: actual))
        case let .indeterminate(error):
            return .degraded(.processIdentityIndeterminate(error))
        }

        let clock = ContinuousClock()
        let started = clock.now
        let versions: SynapseHTTPResponse
        do {
            versions = try await request(path: "/_matrix/client/versions")
        } catch let error as HealthTransportError {
            return .degraded(.versionsTransportFailure(error))
        } catch {
            return .degraded(.versionsTransportFailure(.invalidResponse))
        }
        guard (200..<300).contains(versions.statusCode) else {
            return .degraded(.versionsRequestFailed(status: versions.statusCode))
        }
        guard (try? JSONDecoder().decode(VersionsResponse.self, from: versions.body)) != nil else {
            return .degraded(.invalidResponse(layer: .versions))
        }

        let credential: ProbeCredential
        do {
            if let stored = try credentialStore.load() {
                credential = stored
            } else {
                credential = try await provisionProbe()
                try credentialStore.save(credential)
            }
        } catch let failure as ProbeProvisioningFailure {
            return .degraded(.probeProvisioningFailed(failure))
        } catch {
            return .degraded(.probeProvisioningFailed(.credentialStore))
        }

        let whoami: SynapseHTTPResponse
        do {
            whoami = try await request(
                path: "/_matrix/client/v3/account/whoami",
                headers: ["Authorization": "Bearer \(credential.accessToken)"]
            )
        } catch let error as HealthTransportError {
            return .degraded(.matrixTransportFailure(error))
        } catch {
            return .degraded(.matrixTransportFailure(.invalidResponse))
        }
        guard (200..<300).contains(whoami.statusCode) else {
            return .degraded(.matrixRequestFailed(status: whoami.statusCode))
        }
        guard let response = try? JSONDecoder().decode(WhoamiResponse.self, from: whoami.body) else {
            return .degraded(.invalidResponse(layer: .authentication))
        }
        guard credential.userID == expectedProbeUserID else {
            return .degraded(.probeIdentityMismatch(
                expected: expectedProbeUserID,
                actual: credential.userID
            ))
        }
        guard response.userID == expectedProbeUserID else {
            return .degraded(.probeIdentityMismatch(
                expected: expectedProbeUserID,
                actual: response.userID
            ))
        }
        return .healthy(latency: started.duration(to: clock.now))
    }

    private func provisionProbe() async throws -> ProbeCredential {
        let nonceResponse: SynapseHTTPResponse
        do {
            nonceResponse = try await request(path: "/_synapse/admin/v1/register")
        } catch let error as HealthTransportError {
            throw ProbeProvisioningFailure.transport(error)
        }
        guard (200..<300).contains(nonceResponse.statusCode) else {
            throw ProbeProvisioningFailure.nonceRequest(status: nonceResponse.statusCode)
        }
        guard let nonce = try? JSONDecoder().decode(NonceResponse.self, from: nonceResponse.body).nonce,
              !nonce.isEmpty
        else {
            throw ProbeProvisioningFailure.invalidResponse
        }

        let password = password()
        guard !password.isEmpty, password.utf8.count <= 512, !password.contains("\0") else {
            throw ProbeProvisioningFailure.invalidResponse
        }
        let macInput = [nonce, Self.probeLocalpart, password, "notadmin"].joined(separator: "\0")
        let authentication = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(macInput.utf8),
            using: SymmetricKey(data: Data(registrationSecret.utf8))
        )
        let mac = authentication.map { String(format: "%02x", $0) }.joined()
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: [
                "nonce": nonce,
                "username": Self.probeLocalpart,
                "password": password,
                "admin": false,
                "mac": mac,
            ])
        } catch {
            throw ProbeProvisioningFailure.invalidResponse
        }

        let registration: SynapseHTTPResponse
        do {
            registration = try await request(
                path: "/_synapse/admin/v1/register",
                method: .post,
                headers: ["Content-Type": "application/json"],
                body: body
            )
        } catch let error as HealthTransportError {
            throw ProbeProvisioningFailure.transport(error)
        }
        guard (200..<300).contains(registration.statusCode) else {
            throw ProbeProvisioningFailure.registrationRequest(status: registration.statusCode)
        }
        guard let response = try? JSONDecoder().decode(RegistrationResponse.self, from: registration.body),
              !response.accessToken.isEmpty,
              !response.userID.isEmpty
        else {
            throw ProbeProvisioningFailure.invalidResponse
        }
        guard response.userID == expectedProbeUserID else {
            throw ProbeProvisioningFailure.unexpectedIdentity(
                expected: expectedProbeUserID,
                actual: response.userID
            )
        }
        return ProbeCredential(userID: response.userID, accessToken: response.accessToken)
    }

    private func request(
        path: String,
        method: SynapseHTTPMethod = .get,
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> SynapseHTTPResponse {
        let url = baseURL.appendingPathComponent(String(path.dropFirst()))
        guard Self.isLoopbackRequestURL(url, baseURL: baseURL) else {
            throw HealthTransportError.invalidRequest
        }
        return try await transport.send(SynapseHTTPRequest(
            method: method,
            url: url,
            headers: headers,
            body: body,
            timeout: requestTimeout,
            maximumResponseBytes: maximumResponseBytes
        ))
    }

    private static func isValidBaseURL(_ url: URL) -> Bool {
        url.scheme == "http"
            && url.host == "127.0.0.1"
            && url.port != nil
            && url.port != 0
            && url.user == nil
            && url.password == nil
            && (url.path.isEmpty || url.path == "/")
            && url.query == nil
            && url.fragment == nil
    }

    private static func isLoopbackRequestURL(_ url: URL, baseURL: URL) -> Bool {
        url.scheme == "http"
            && url.host == "127.0.0.1"
            && url.port == baseURL.port
            && url.user == nil
            && url.password == nil
            && url.query == nil
            && url.fragment == nil
    }

    public static func systemIdentityStatus(
        _ expected: ManagedProcessIdentity
    ) async -> ManagedProcessIdentityStatus {
        if let actual = FoundationManagedProcess.readIdentity(for: expected.processIdentifier) {
            return actual == expected ? .matching : .mismatched(actual: actual)
        }
        if kill(expected.processIdentifier, 0) == -1, errno == ESRCH { return .exited }
        return .indeterminate(.processIdentityUnavailable(expected.processIdentifier))
    }
}

private struct VersionsResponse: Decodable {
    let versions: [String]
}

private struct NonceResponse: Decodable {
    let nonce: String
}

private struct RegistrationResponse: Decodable {
    let accessToken: String
    let userID: String

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case userID = "user_id"
    }
}

private struct WhoamiResponse: Decodable {
    let userID: String

    private enum CodingKeys: String, CodingKey {
        case userID = "user_id"
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
