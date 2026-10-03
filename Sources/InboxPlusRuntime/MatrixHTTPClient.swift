import Foundation

public enum MatrixMethod: String, Sendable, Equatable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
}

/// A decoded Matrix `errcode`/`error` body paired with the status that carried it.
public struct MatrixErrorBody: Error, Equatable, Sendable {
    public let statusCode: Int
    public let errorCode: String?
    public let message: String?

    public init(statusCode: Int, errorCode: String?, message: String?) {
        self.statusCode = statusCode
        self.errorCode = errorCode
        self.message = message
    }
}

public enum MatrixHTTPError: Error, Equatable, Sendable {
    case nonLoopbackBaseURL
    case invalidRequestURL
    case transport(HealthTransportError)
    case matrix(MatrixErrorBody)
    case retriesExhausted(statusCode: Int, attempts: Int)
    case decoding(String)
}

/// A narrow authenticated Matrix client used only by this developer spike.
///
/// It accepts loopback origins exclusively, percent-encodes every path segment, retries only
/// explicitly transient statuses, and never reproduces the access token in an error value.
public struct MatrixHTTPClient: Sendable {
    public typealias RetryDelay = @Sendable (Int) async -> Void

    /// Unreserved characters per RFC 3986; everything else in a segment is escaped.
    private static let unreservedSegment = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
    private static let retriableStatuses: Set<Int> = [429, 500, 502, 503, 504]

    public let baseURL: URL
    private let accessToken: String?
    private let transport: any SynapseHTTPTransport
    private let requestTimeout: Duration
    private let maximumResponseBytes: Int
    private let maximumAttempts: Int
    private let retryDelay: RetryDelay

    public init(
        baseURL: URL,
        accessToken: String?,
        transport: any SynapseHTTPTransport = URLSessionSynapseHTTPTransport(),
        requestTimeout: Duration = .seconds(30),
        maximumResponseBytes: Int = 16 * 1_024 * 1_024,
        maximumAttempts: Int = 4,
        retryDelay: @escaping RetryDelay = { attempt in
            try? await Task.sleep(for: .milliseconds(100 << min(attempt, 4)))
        }
    ) throws {
        guard Self.isLoopbackOrigin(baseURL) else { throw MatrixHTTPError.nonLoopbackBaseURL }
        precondition(maximumAttempts > 0)
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.transport = transport
        self.requestTimeout = requestTimeout
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumAttempts = maximumAttempts
        self.retryDelay = retryDelay
    }

    public func withAccessToken(_ token: String?) throws -> MatrixHTTPClient {
        try MatrixHTTPClient(
            baseURL: baseURL,
            accessToken: token,
            transport: transport,
            requestTimeout: requestTimeout,
            maximumResponseBytes: maximumResponseBytes,
            maximumAttempts: maximumAttempts,
            retryDelay: retryDelay
        )
    }

    /// Sends one request, retrying byte-identical when `idempotent` and the status is transient.
    ///
    /// Retrying the identical URL matters for sends: the transaction ID stays fixed, so Synapse
    /// deduplicates rather than committing the event twice.
    @discardableResult
    public func send<Response: Decodable>(
        _ method: MatrixMethod,
        path: [String],
        query: [URLQueryItem] = [],
        body: Data? = nil,
        idempotent: Bool = false
    ) async throws -> Response {
        let data = try await sendForData(
            method,
            path: path,
            query: query,
            body: body,
            idempotent: idempotent
        )
        if Response.self == EmptyMatrixResponse.self, data.isEmpty {
            return EmptyMatrixResponse() as! Response
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw MatrixHTTPError.decoding(String(describing: Response.self))
        }
    }

    public func sendForData(
        _ method: MatrixMethod,
        path: [String],
        query: [URLQueryItem] = [],
        body: Data? = nil,
        idempotent: Bool = false
    ) async throws -> Data {
        let url = try requestURL(path: path, query: query)
        var headers = ["Accept": "application/json"]
        if body != nil { headers["Content-Type"] = "application/json" }
        if let accessToken { headers["Authorization"] = "Bearer \(accessToken)" }

        let request = SynapseHTTPRequest(
            method: method.synapseMethod,
            url: url,
            headers: headers,
            body: body,
            timeout: requestTimeout,
            maximumResponseBytes: maximumResponseBytes
        )

        var lastRetriableStatus: Int?
        for attempt in 0..<maximumAttempts {
            let response: SynapseHTTPResponse
            do {
                response = try await transport.send(request)
            } catch let error as HealthTransportError {
                guard idempotent, attempt + 1 < maximumAttempts else {
                    throw MatrixHTTPError.transport(error)
                }
                await retryDelay(attempt)
                continue
            }

            if (200..<300).contains(response.statusCode) { return response.body }

            let failure = Self.decodeErrorBody(response)
            guard idempotent, Self.retriableStatuses.contains(response.statusCode) else {
                throw MatrixHTTPError.matrix(failure)
            }
            lastRetriableStatus = response.statusCode
            guard attempt + 1 < maximumAttempts else { break }
            await retryDelay(attempt)
        }

        throw MatrixHTTPError.retriesExhausted(
            statusCode: lastRetriableStatus ?? 0,
            attempts: maximumAttempts
        )
    }

    func requestURL(path: [String], query: [URLQueryItem]) throws -> URL {
        let encoded = path.map { segment in
            segment.addingPercentEncoding(withAllowedCharacters: Self.unreservedSegment) ?? segment
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw MatrixHTTPError.invalidRequestURL
        }
        components.percentEncodedPath = "/" + encoded.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw MatrixHTTPError.invalidRequestURL }
        return url
    }

    private static func decodeErrorBody(_ response: SynapseHTTPResponse) -> MatrixErrorBody {
        let payload = try? JSONDecoder().decode(MatrixErrorPayload.self, from: response.body)
        return MatrixErrorBody(
            statusCode: response.statusCode,
            errorCode: payload?.errcode,
            message: payload?.error
        )
    }

    static func isLoopbackOrigin(_ url: URL) -> Bool {
        url.scheme == "http"
            && url.host == "127.0.0.1"
            && url.port != nil
            && (url.path.isEmpty || url.path == "/")
            && url.user == nil
            && url.password == nil
            && url.query == nil
            && url.fragment == nil
    }
}

/// Decodes any success body that carries no fields the caller needs.
public struct EmptyMatrixResponse: Decodable, Sendable, Equatable {
    public init() {}
    public init(from decoder: any Decoder) throws {}
}

private struct MatrixErrorPayload: Decodable {
    let errcode: String?
    let error: String?
}

private extension MatrixMethod {
    var synapseMethod: SynapseHTTPMethod {
        switch self {
        case .get: .get
        case .post: .post
        case .put: .put
        }
    }
}
