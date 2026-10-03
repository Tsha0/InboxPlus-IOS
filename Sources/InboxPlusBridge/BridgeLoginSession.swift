import Foundation

/// The seam between the login UI and a running bridge.
///
/// The same seam the messaging gateway uses: `InboxPlusFeatures` and `InboxPlusUI` drive a login through
/// this protocol, so neither has to know that a real bridge is an external process reached over a
/// loopback HTTP API — and tests drive the whole flow with no process at all.
public protocol BridgeLoginSession: Sendable {
    func loginFlows() async throws -> [BridgeLoginFlow]
    func startLogin(flowID: String) async throws -> BridgeLoginStep
    func submit(
        loginID: String,
        stepID: String,
        type: BridgeLoginStepType,
        values: [String: String]
    ) async throws -> BridgeLoginStep
    /// Tells the bridge an attempt is over, so it drops the connection it opened to the network.
    ///
    /// An abandoned attempt is not free: a login holds an open network session for as long as
    /// the bridge keeps it, and a bridge refuses to start more once too many are in flight. Walking
    /// away from a login has to end it on the bridge too, not only in the window.
    func cancelLogin(loginID: String) async throws
}

/// A recorded login session that replays a scripted sequence of steps.
///
/// Used by previews and by tests that need a flow without a bridge.
public actor ScriptedLoginSession: BridgeLoginSession {
    private let flows: [BridgeLoginFlow]
    private let steps: [BridgeLoginStep]
    private var index = 0

    public init(flows: [BridgeLoginFlow], steps: [BridgeLoginStep]) {
        self.flows = flows
        self.steps = steps
    }

    public func loginFlows() async throws -> [BridgeLoginFlow] { flows }

    public func startLogin(flowID: String) async throws -> BridgeLoginStep {
        guard flows.contains(where: { $0.id == flowID }) else {
            throw BridgeLoginError.unknownFlow(flowID)
        }
        index = 0
        guard let first = steps.first else {
            throw BridgeLoginError.unknownFlow(flowID)
        }
        return first
    }

    public func submit(
        loginID: String,
        stepID: String,
        type: BridgeLoginStepType,
        values: [String: String]
    ) async throws -> BridgeLoginStep {
        index += 1
        guard index < steps.count else {
            throw BridgeLoginError.bridgeRejected(status: 400, message: "login already complete")
        }
        return steps[index]
    }

    /// Nothing was opened on a network, so nothing has to be closed.
    public func cancelLogin(loginID: String) async throws {}
}
