import Foundation
import Observation
import InboxPlusBridge
import InboxPlusCore

/// Drives one network login from flow selection through to a connected account.
///
/// The controller knows the shape of a `bridgev2` login:
/// every screen is chosen by the step type the bridge returns, so a network Inbox+ has never heard
/// of logs in correctly as long as its bridge speaks the protocol. WhatsApp only offers phone pairing.
@MainActor
@Observable
public final class BridgeLoginController {
    public enum Phase: Equatable {
        case loadingFlows
        /// More than one way in — the user picks, e.g. Facebook's sign-in domains.
        case choosingFlow([BridgeLoginFlow])
        case step(BridgeLoginStep)
        case submitting(BridgeLoginStep)
        case finished(userLoginID: String)
        case failed(String)
    }

    public let platform: Platform
    public private(set) var phase: Phase = .loadingFlows
    /// What the user has entered or what the webview has captured for the current step.
    public private(set) var values: [String: String] = [:]

    private let session: any BridgeLoginSession
    private var activeLoginID: String?
    private var waitTask: Task<Void, Never>?

    public init(platform: Platform, session: any BridgeLoginSession) {
        self.platform = platform
        self.session = session
    }

    public var currentStep: BridgeLoginStep? {
        switch phase {
        case let .step(step), let .submitting(step): step
        default: nil
        }
    }

    public var isBusy: Bool {
        switch phase {
        case .loadingFlows, .submitting: true
        default: false
        }
    }

    /// The reason the current step will not accept what has been entered, or `nil` when it will.
    public var blockingValidationMessage: String? {
        guard let step = currentStep else { return nil }
        return step.validationFailure(in: values)?.description
    }

    public var canSubmit: Bool {
        guard case let .step(step) = phase else { return false }
        // A waiting step advances when the bridge says so, not when the user presses anything.
        if step.type == .displayAndWait { return false }
        return step.validationFailure(in: values) == nil
    }

    public func start() async {
        phase = .loadingFlows
        do {
            let advertisedFlows = try await session.loginFlows()
            let flows = platform == .whatsApp
                ? advertisedFlows.filter { $0.id == "phone" }
                : advertisedFlows
            guard !flows.isEmpty else {
                phase = .failed(platform == .whatsApp
                    ? "This bridge does not offer phone number linking for WhatsApp."
                    : "This bridge offers no way to sign in.")
                return
            }
            if flows.count == 1 {
                await begin(flowID: flows[0].id)
            } else {
                phase = .choosingFlow(flows)
            }
        } catch {
            phase = .failed(describe(error))
        }
    }

    public func begin(flowID: String) async {
        // Switching flows leaves the first attempt running on the bridge unless it is ended here.
        cancel()
        guard platform != .whatsApp || flowID == "phone" else {
            phase = .failed("WhatsApp only supports phone number linking in Inbox+.")
            return
        }
        phase = .loadingFlows
        do {
            adopt(try await session.startLogin(flowID: flowID))
        } catch {
            phase = .failed(describe(error))
        }
    }

    public func setValue(_ value: String, for fieldID: String) {
        values[fieldID] = value
    }

    /// Replaces every collected value at once, as the cookie webview does when it captures a set.
    public func replaceValues(_ replacement: [String: String]) {
        values = replacement
    }

    /// Sends the current step's values and adopts whatever the bridge asks for next.
    public func submit() async {
        guard case let .step(step) = phase else { return }
        guard let loginID = activeLoginID ?? step.loginID else {
            phase = .failed("The bridge did not identify this login attempt.")
            return
        }
        do {
            // Validate once more here, not only in the view: this is the last point before the
            // values leave the machine, and a view is not a security boundary.
            try step.validate(values)
        } catch {
            phase = .failed(describe(error))
            return
        }

        phase = .submitting(step)
        do {
            adopt(try await session.submit(
                loginID: loginID,
                stepID: step.stepID,
                type: step.type,
                values: values
            ))
        } catch {
            // Return to the step so the user can correct and retry rather than restarting the flow.
            phase = .step(step)
            failureMessage = describe(error)
        }
    }

    /// The most recent recoverable failure, shown beside the step the user can still fix.
    public private(set) var failureMessage: String?

    public func dismissFailure() { failureMessage = nil }

    /// Abandons the login: stops waiting, and tells the bridge to drop what it opened.
    ///
    /// Closing the window is not enough. The bridge keeps the attempt — and the WhatsApp session
    /// behind it — alive until it is told otherwise, and it refuses to start new ones once several
    /// are in flight, so a few abandoned attempts leave the next login failing for no visible
    /// reason.
    public func cancel() {
        waitTask?.cancel()
        waitTask = nil
        guard let loginID = activeLoginID else { return }
        activeLoginID = nil
        if case .finished = phase { return }
        let session = session
        Task { try? await session.cancelLogin(loginID: loginID) }
    }

    /// Asks the bridge for whatever follows a waiting step, and adopts it when it arrives.
    ///
    /// A `display_and_wait` step only advances while a client is asking: the provisioning API
    /// answers the wait with a long-lived POST that returns either the next code or the finished
    /// login. Phone pairing uses this to finish once the code is entered in the mobile app.
    private func waitForNextStep(after step: BridgeLoginStep) {
        guard let loginID = activeLoginID ?? step.loginID else {
            phase = .failed("The bridge did not identify this login attempt.")
            return
        }
        let session = session
        waitTask = Task { [weak self] in
            do {
                let next = try await session.submit(
                    loginID: loginID,
                    stepID: step.stepID,
                    type: step.type,
                    values: [:]
                )
                guard !Task.isCancelled else { return }
                self?.adopt(next)
            } catch {
                guard !Task.isCancelled, let self else { return }
                phase = .failed(describe(error))
            }
        }
    }

    private func adopt(_ step: BridgeLoginStep) {
        waitTask?.cancel()
        waitTask = nil
        if let loginID = step.loginID { activeLoginID = loginID }
        failureMessage = nil
        values = [:]
        if step.type == .complete {
            phase = .finished(userLoginID: step.complete?.userLoginID ?? "")
        } else {
            // Prefill anything the bridge suggested, so an offered default is not silently dropped.
            for field in step.userInput?.fields ?? [] {
                if let defaultValue = field.defaultValue, !defaultValue.isEmpty {
                    values[field.id] = defaultValue
                }
            }
            phase = .step(step)
            if step.type == .displayAndWait { waitForNextStep(after: step) }
        }
    }

    private func describe(_ error: any Error) -> String {
        if let bridgeError = error as? BridgeLoginError { return bridgeError.description }
        return error.localizedDescription
    }
}
