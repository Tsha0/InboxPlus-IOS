import Foundation
import InboxPlusBridge
import InboxPlusRuntime

/// Health for one bridge: the process Inbox+ launched is still that process, and its provisioning
/// API answers an authenticated request.
///
/// Probing an authenticated endpoint rather than a liveness ping is deliberate — a bridge whose
/// socket is open but whose shared secret no longer matches is useless to Inbox+, and reporting it
/// healthy would hide a real failure behind a green light.
public struct BridgeHealthChecker: SynapseHealthChecking {
    private let client: MatrixHTTPClient
    private let identityStatus: @Sendable (ManagedProcessIdentity) async -> ManagedProcessIdentityStatus

    private let userID: String

    public init(
        provisioningBaseURL: URL,
        provisioningSecret: String,
        userID: String,
        transport: any SynapseHTTPTransport = URLSessionSynapseHTTPTransport(),
        requestTimeout: Duration = .seconds(5),
        identityStatus: @escaping @Sendable (ManagedProcessIdentity) async -> ManagedProcessIdentityStatus
            = { await SynapseHealthChecker.systemIdentityStatus($0) }
    ) throws {
        client = try MatrixHTTPClient(
            baseURL: provisioningBaseURL,
            accessToken: provisioningSecret,
            transport: transport,
            requestTimeout: requestTimeout,
            maximumAttempts: 1
        )
        self.userID = userID
        self.identityStatus = identityStatus
    }

    public func check(snapshot: RuntimeSnapshot) async -> HealthResult {
        guard let expected = snapshot.processIdentity else { return .stopped }
        switch await identityStatus(expected) {
        case .matching:
            break
        case .exited:
            return .stopped
        case let .mismatched(actual):
            return .degraded(.processIdentityMismatch(expected: expected, actual: actual))
        case let .indeterminate(error):
            return .degraded(.processIdentityIndeterminate(error))
        }

        let started = ContinuousClock.now
        do {
            let _: BridgeFlowsProbeResponse = try await client.send(
                .get,
                path: ["_matrix", "provision", "v3", "login", "flows"],
                query: [URLQueryItem(name: "user_id", value: userID)],
                idempotent: true
            )
            return .healthy(latency: ContinuousClock.now - started)
        } catch let MatrixHTTPError.matrix(body) {
            return .degraded(.matrixRequestFailed(status: body.statusCode))
        } catch let MatrixHTTPError.transport(failure) {
            return .degraded(.matrixTransportFailure(failure))
        } catch {
            return .degraded(.invalidResponse(layer: .registration))
        }
    }
}

private struct BridgeFlowsProbeResponse: Decodable {
    let flows: [BridgeLoginFlow]
}
