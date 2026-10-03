import Foundation
import Network
import InboxPlusRemote

/// The listener is loopback-only. A trusted HTTPS reverse proxy provides transport security.
/// Every request also requires a random pairing key, including requests from the local machine.
public final class CompanionHTTPServer: Sendable {
    private let listener: NWListener
    private let token: String
    private let handler: @Sendable (CompanionRequest) async -> CompanionResponse
    private let queue = DispatchQueue(label: "InboxPlus.Companion.HTTP")
    public init(port: UInt16 = 8765, token: String, handler: @escaping @Sendable (CompanionRequest) async -> CompanionResponse) throws {
        guard token.count >= 32, !token.contains("\r"), !token.contains("\n") else { throw CompanionError.server("Pairing key must have at least 32 characters.") }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        self.listener = try NWListener(using: parameters)
        self.token = token
        self.handler = handler
    }
    public func start() {
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            // A bounded lifetime prevents incomplete HTTP requests from holding sockets forever.
            queue.asyncAfter(deadline: .now() + 150) { connection.cancel() }
            Task { await serve(connection) }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { fputs("Companion listener failed: \(error)\n", stderr) }
        }
        listener.start(queue: queue)
    }
    public func stop() { listener.cancel() }
    private func serve(_ connection: NWConnection) async {
        do {
            var buffer = Data()
            var bodyOffset: Int?
            var contentLength = 0
            while true {
                let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let data, !data.isEmpty { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: CompanionError.server(complete ? "Connection closed" : "Empty request")) }
                    }
                }
                buffer.append(chunk)
                guard buffer.count <= 36 * 1024 * 1024 else { await reply(connection, status: 413); return }
                if bodyOffset == nil {
                    if let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) {
                        guard boundary.lowerBound < 16 * 1024,
                              let header = String(data: buffer[..<boundary.lowerBound], encoding: .utf8) else { await reply(connection, status: 400); return }
                        let lines = header.components(separatedBy: "\r\n")
                        guard lines.first == "POST /v1/rpc HTTP/1.1" else { await reply(connection, status: 404); return }
                        var headers: [String: String] = [:]
                        for line in lines.dropFirst() {
                            let parts = line.split(separator: ":", maxSplits: 1)
                            guard parts.count == 2 else { await reply(connection, status: 400); return }
                            let key = parts[0].lowercased()
                            guard headers[key] == nil else { await reply(connection, status: 400); return }
                            headers[key] = parts[1].trimmingCharacters(in: .whitespaces)
                        }
                        guard Self.matches(headers["authorization"] ?? "", "Bearer \(token)") else { await reply(connection, status: 401); return }
                        guard headers["transfer-encoding"] == nil,
                              let length = headers["content-length"].flatMap(Int.init), length >= 0, length <= 36 * 1024 * 1024 else { await reply(connection, status: 413); return }
                        contentLength = length; bodyOffset = boundary.upperBound
                    } else if buffer.count > 16 * 1024 { await reply(connection, status: 413); return }
                }
                if let offset = bodyOffset, buffer.count >= offset + contentLength {
                    let request = try JSONDecoder().decode(CompanionRequest.self, from: buffer[offset..<(offset + contentLength)])
                    let response = await handler(request)
                    await reply(connection, status: 200, data: try JSONEncoder().encode(response))
                    return
                }
            }
        } catch { await reply(connection, status: 400) }
    }
    public static func matches(_ supplied: String, _ expected: String) -> Bool {
        let a = Array(supplied.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    private func reply(_ connection: NWConnection, status: Int, data: Data = Data()) async {
        var response = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        response.append(data)
        await withCheckedContinuation { continuation in
            connection.send(content: response, completion: .contentProcessed { _ in continuation.resume() })
        }
        connection.cancel()
    }
}
