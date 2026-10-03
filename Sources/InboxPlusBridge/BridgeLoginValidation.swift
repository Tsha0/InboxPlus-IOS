import Foundation

public extension BridgeLoginStep {
    /// Checks collected values against this step's own declared fields.
    ///
    /// Validation lives here, beside the protocol models, so the login UI can refuse a bad value
    /// before it is ever handed to a client — nothing incomplete or malformed leaves the machine.
    func validate(_ values: [String: String]) throws {
        switch type {
        case .userInput:
            for field in userInput?.fields ?? [] {
                guard let value = values[field.id], !value.isEmpty else {
                    throw BridgeLoginError.missingRequiredField(field.id)
                }
                guard field.accepts(value) else {
                    throw BridgeLoginError.invalidFieldValue(field.id)
                }
            }
        case .cookies:
            for id in cookies?.requiredFieldIDs ?? [] {
                guard let value = values[id], !value.isEmpty else {
                    throw BridgeLoginError.missingRequiredField(id)
                }
            }
        default:
            break
        }
    }

    /// The first problem with `values`, or `nil` when the step would accept them.
    ///
    /// The UI needs to know whether "Continue" is enabled on every keystroke, which is a question
    /// about the current values rather than an error worth throwing.
    func validationFailure(in values: [String: String]) -> BridgeLoginError? {
        do {
            try validate(values)
            return nil
        } catch let error as BridgeLoginError {
            return error
        } catch {
            return nil
        }
    }

    /// Values that must never be echoed on screen or written to a log.
    var secretFieldIDs: Set<String> {
        Set((userInput?.fields ?? []).filter(\.type.isSecret).map(\.id))
    }
}
