import Foundation

/// A login method a bridge advertises, e.g. WhatsApp's "Pairing code" or Facebook's "facebook.com".
public struct BridgeLoginFlow: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String

    public init(id: String, name: String, description: String) {
        self.id = id
        self.name = name
        self.description = description
    }

    private enum CodingKeys: String, CodingKey { case id, name, description }
}

/// The step kinds mautrix `bridgev2` can ask a client to perform.
///
/// Inbox+ renders one native view per kind, so supporting a new network is a matter of the bridge
/// advertising flows rather than Inbox+ learning that network.
public enum BridgeLoginStepType: String, Codable, Sendable, Equatable {
    case userInput = "user_input"
    case cookies
    case clientHTTP = "client_http"
    case displayAndWait = "display_and_wait"
    case webAuthn = "webauthn"
    case complete
}

public enum BridgeLoginDisplayType: String, Codable, Sendable, Equatable {
    case qr
    case emoji
    case code
    case nothing
}

/// Field kinds a bridge can ask the user to fill in, each a hint for how Inbox+ should render it.
public enum BridgeLoginInputFieldType: String, Codable, Sendable, Equatable {
    case username
    case password
    case phoneNumber = "phone_number"
    case email
    case twoFactorCode = "2fa_code"
    case token
    case url
    case domain
    case select
    case captchaCode = "captcha_code"

    /// True when the value must never be echoed on screen or written to a log.
    public var isSecret: Bool {
        switch self {
        case .password, .token, .twoFactorCode: true
        default: false
        }
    }
}

public struct BridgeLoginInputField: Codable, Sendable, Equatable {
    public let type: BridgeLoginInputFieldType
    public let id: String
    public let name: String
    public let description: String
    public let defaultValue: String?
    public let pattern: String?

    public init(
        type: BridgeLoginInputFieldType,
        id: String,
        name: String,
        description: String = "",
        defaultValue: String? = nil,
        pattern: String? = nil
    ) {
        self.type = type
        self.id = id
        self.name = name
        self.description = description
        self.defaultValue = defaultValue
        self.pattern = pattern
    }

    /// Client-side validation, so an obviously wrong value never reaches the remote network.
    public func accepts(_ value: String) -> Bool {
        guard let pattern, !pattern.isEmpty else { return !value.isEmpty }
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private enum CodingKeys: String, CodingKey {
        case type, id, name, description, pattern
        case defaultValue = "default_value"
    }
}

public struct BridgeLoginUserInputParams: Codable, Sendable, Equatable {
    public let fields: [BridgeLoginInputField]

    public init(fields: [BridgeLoginInputField]) { self.fields = fields }
}

public struct BridgeLoginDisplayAndWaitParams: Codable, Sendable, Equatable {
    public let type: BridgeLoginDisplayType
    public let data: String?
    public let imageURL: String?

    public init(type: BridgeLoginDisplayType, data: String? = nil, imageURL: String? = nil) {
        self.type = type
        self.data = data
        self.imageURL = imageURL
    }

    private enum CodingKeys: String, CodingKey {
        case type, data
        case imageURL = "image_url"
    }
}

public struct BridgeLoginCookieFieldSource: Codable, Sendable, Equatable {
    public let type: String
    public let name: String
    public let cookieDomain: String?

    public init(type: String, name: String, cookieDomain: String? = nil) {
        self.type = type
        self.name = name
        self.cookieDomain = cookieDomain
    }

    private enum CodingKeys: String, CodingKey {
        case type, name
        case cookieDomain = "cookie_domain"
    }
}

public struct BridgeLoginCookieField: Codable, Sendable, Equatable {
    public let id: String
    public let required: Bool
    public let sources: [BridgeLoginCookieFieldSource]

    public init(id: String, required: Bool, sources: [BridgeLoginCookieFieldSource]) {
        self.id = id
        self.required = required
        self.sources = sources
    }
}

public struct BridgeLoginCookiesParams: Codable, Sendable, Equatable {
    public let url: String
    public let userAgent: String?
    public let fields: [BridgeLoginCookieField]
    public let waitForURLPattern: String?

    public init(
        url: String,
        userAgent: String? = nil,
        fields: [BridgeLoginCookieField],
        waitForURLPattern: String? = nil
    ) {
        self.url = url
        self.userAgent = userAgent
        self.fields = fields
        self.waitForURLPattern = waitForURLPattern
    }

    /// The cookies that must be captured before the webview can be dismissed.
    public var requiredFieldIDs: [String] { fields.filter(\.required).map(\.id) }

    private enum CodingKeys: String, CodingKey {
        case url, fields
        case userAgent = "user_agent"
        case waitForURLPattern = "wait_for_url_pattern"
    }
}

public struct BridgeLoginCompleteParams: Codable, Sendable, Equatable {
    public let userLoginID: String

    public init(userLoginID: String) { self.userLoginID = userLoginID }

    private enum CodingKeys: String, CodingKey { case userLoginID = "user_login_id" }
}

/// One step of a login, exactly as `bridgev2` models it.
public struct BridgeLoginStep: Codable, Sendable, Equatable {
    public let type: BridgeLoginStepType
    public let stepID: String
    /// Identifies the login attempt this step belongs to.
    ///
    /// A bridge can have several logins in flight, so submitting a step names the attempt as well
    /// as the step; the first response of a flow carries it and later requests echo it back.
    public let loginID: String?
    public let instructions: String
    public let userInput: BridgeLoginUserInputParams?
    public let displayAndWait: BridgeLoginDisplayAndWaitParams?
    public let cookies: BridgeLoginCookiesParams?
    public let complete: BridgeLoginCompleteParams?

    public init(
        type: BridgeLoginStepType,
        stepID: String,
        loginID: String? = nil,
        instructions: String = "",
        userInput: BridgeLoginUserInputParams? = nil,
        displayAndWait: BridgeLoginDisplayAndWaitParams? = nil,
        cookies: BridgeLoginCookiesParams? = nil,
        complete: BridgeLoginCompleteParams? = nil
    ) {
        self.type = type
        self.stepID = stepID
        self.loginID = loginID
        self.instructions = instructions
        self.userInput = userInput
        self.displayAndWait = displayAndWait
        self.cookies = cookies
        self.complete = complete
    }

    public var isTerminal: Bool { type == .complete }

    private enum CodingKeys: String, CodingKey {
        case type, instructions, cookies, complete
        case stepID = "step_id"
        case loginID = "login_id"
        case userInput = "user_input"
        case displayAndWait = "display_and_wait"
    }
}

public enum BridgeLoginError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownFlow(String)
    case unexpectedStep(expected: BridgeLoginStepType, actual: BridgeLoginStepType)
    case missingRequiredField(String)
    case invalidFieldValue(String)
    case bridgeRejected(status: Int, message: String?)

    public var description: String {
        switch self {
        case let .unknownFlow(id): "the bridge does not offer a login flow named '\(id)'"
        case let .unexpectedStep(expected, actual):
            "expected a \(expected.rawValue) step but the bridge returned \(actual.rawValue)"
        case let .missingRequiredField(id): "missing required value for '\(id)'"
        case let .invalidFieldValue(id): "the value for '\(id)' is not valid"
        case let .bridgeRejected(status, message):
            "the bridge rejected the login (status \(status))\(message.map { ": \($0)" } ?? "")"
        }
    }
}
