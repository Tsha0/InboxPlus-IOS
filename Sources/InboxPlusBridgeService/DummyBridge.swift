import Foundation
import InboxPlusBridge
import InboxPlusRuntime

/// A deterministic stand-in for a real mautrix bridge.
///
/// It answers the same `bridgev2` provisioning contract as the real binaries, so every login flow
/// Inbox+ must render — QR, phone plus two-factor, cookie webview — is exercised in tests without
/// credentials or a live network. Scripts are the real flow shapes taken from the mautrix
/// connectors, not invented ones.
public actor DummyBridge: SynapseHTTPTransport {
    public struct Script: Sendable {
        public let flows: [BridgeLoginFlow]
        /// Steps returned in order: `startLogin` yields the first, each submit yields the next.
        public let steps: [String: [BridgeLoginStep]]

        public init(flows: [BridgeLoginFlow], steps: [String: [BridgeLoginStep]]) {
            self.flows = flows
            self.steps = steps
        }
    }

    private let script: Script
    private var stepIndex: [String: Int] = [:]
    private var activeFlow: String?
    private(set) var submittedValues: [[String: String]] = []
    private(set) var requestedPaths: [String] = []

    public init(script: Script) {
        self.script = script
    }

    public func submissions() -> [[String: String]] { submittedValues }
    public func paths() -> [String] { requestedPaths }

    public func send(_ request: SynapseHTTPRequest) async throws -> SynapseHTTPResponse {
        let path = request.url.path.removingPercentEncoding ?? request.url.path
        requestedPaths.append(path)
        // The real bridge refuses any provisioning request that does not name the acting user.
        guard let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "user_id" && $0.value?.isEmpty == false }) == true
        else {
            return try encodeError(status: 403, code: "M_FORBIDDEN")
        }
        let segments = path.split(separator: "/").map(String.init)

        // /_matrix/provision/v3/login/flows
        if segments.suffix(2) == ["login", "flows"] {
            return try encode(["flows": script.flows])
        }
        // /_matrix/provision/v3/login/start/{flowID}
        if segments.count >= 2, segments[segments.count - 2] == "start" {
            let flowID = segments[segments.count - 1]
            guard script.steps[flowID] != nil else {
                return try encodeError(status: 400, code: "M_INVALID_FLOW")
            }
            activeFlow = flowID
            stepIndex[flowID] = 0
            return try encode(script.steps[flowID]![0])
        }
        // /_matrix/provision/v3/login/step/{loginID}/{stepID}/{type}
        if segments.contains("step") {
            if let body = request.body,
               let values = try? JSONSerialization.jsonObject(with: body) as? [String: String] {
                submittedValues.append(values)
            }
            guard let flowID = activeFlow, let steps = script.steps[flowID] else {
                return try encodeError(status: 400, code: "M_NO_ACTIVE_LOGIN")
            }
            let next = (stepIndex[flowID] ?? 0) + 1
            stepIndex[flowID] = next
            guard next < steps.count else {
                return try encodeError(status: 400, code: "M_LOGIN_ALREADY_COMPLETE")
            }
            return try encode(steps[next])
        }
        return try encodeError(status: 404, code: "M_UNRECOGNIZED")
    }

    private func encode(_ value: some Encodable) throws -> SynapseHTTPResponse {
        SynapseHTTPResponse(statusCode: 200, body: try JSONEncoder().encode(value))
    }

    private func encodeError(status: Int, code: String) throws -> SynapseHTTPResponse {
        SynapseHTTPResponse(
            statusCode: status,
            body: try JSONSerialization.data(withJSONObject: ["errcode": code, "error": code])
        )
    }
}

// MARK: - Real flow shapes

public extension DummyBridge.Script {
    /// Instagram: a cookie login through the network's own web page.
    ///
    /// Field names are the cookies `mautrix-meta` actually requires.
    static let instagram = DummyBridge.Script(
        flows: [
            BridgeLoginFlow(
                id: "instagram",
                name: "instagram.com",
                description: "Login using cookies from instagram.com"
            ),
        ],
        steps: [
            "instagram": [
                BridgeLoginStep(
                    type: .cookies,
                    stepID: "fi.mau.meta.cookies",
                    loginID: "dummy-instagram-login",
                    instructions: "Enter a JSON object with your cookies, or a cURL command copied from browser devtools.",
                    cookies: BridgeLoginCookiesParams(
                        url: "https://www.instagram.com/accounts/login/",
                        userAgent: "Mozilla/5.0",
                        fields: ["sessionid", "csrftoken", "ds_user_id", "mid", "ig_did"].map {
                            BridgeLoginCookieField(
                                id: $0,
                                required: true,
                                sources: [
                                    BridgeLoginCookieFieldSource(
                                        type: "cookie",
                                        name: $0,
                                        cookieDomain: "instagram.com"
                                    ),
                                ]
                            )
                        },
                        waitForURLPattern:
                            "^https://www\\.instagram\\.com/(?:direct/(?:inbox/|t/[0-9]+/)?)?(?:\\?.*)?$"
                    )
                ),
                BridgeLoginStep(
                    type: .complete,
                    stepID: "fi.mau.meta.complete",
                    loginID: "dummy-instagram-login",
                    complete: BridgeLoginCompleteParams(userLoginID: "17841400000000000")
                ),
            ],
        ]
    )

    /// WhatsApp: phone number followed by a pairing code entered in the mobile app.
    static let whatsApp = DummyBridge.Script(
        flows: [
            BridgeLoginFlow(id: "phone", name: "Pairing code", description: "Link with your phone number"),
        ],
        steps: [
            "phone": [
                BridgeLoginStep(
                    type: .userInput,
                    stepID: "fi.mau.whatsapp.login.phone",
                    loginID: "dummy-whatsapp-login",
                    userInput: BridgeLoginUserInputParams(fields: [
                        BridgeLoginInputField(
                            type: .phoneNumber,
                            id: "phone_number",
                            name: "Phone number",
                            description: "Your WhatsApp phone number in international format"
                        ),
                    ])
                ),
                BridgeLoginStep(
                    type: .displayAndWait,
                    stepID: "fi.mau.whatsapp.login.code",
                    loginID: "dummy-whatsapp-login",
                    instructions: "Input the pairing code in the WhatsApp mobile app to log in",
                    displayAndWait: BridgeLoginDisplayAndWaitParams(type: .code, data: "ABCD-EFGH")
                ),
                BridgeLoginStep(
                    type: .complete,
                    stepID: "fi.mau.whatsapp.login.complete",
                    loginID: "dummy-whatsapp-login",
                    complete: BridgeLoginCompleteParams(userLoginID: "15551234567")
                ),
            ],
        ]
    )

    /// Telegram: phone number, then the SMS code, then a two-factor password.
    static let telegram = DummyBridge.Script(
        flows: [
            BridgeLoginFlow(id: "phone", name: "Phone number", description: "Login with a phone number"),
        ],
        steps: [
            "phone": [
                BridgeLoginStep(
                    type: .userInput,
                    stepID: "fi.mau.telegram.phone",
                    loginID: "dummy-telegram-login",
                    instructions: "Enter your phone number.",
                    userInput: BridgeLoginUserInputParams(fields: [
                        BridgeLoginInputField(
                            type: .phoneNumber,
                            id: "phone_number",
                            name: "Phone number",
                            pattern: "^\\+[0-9]{6,15}$"
                        ),
                    ])
                ),
                BridgeLoginStep(
                    type: .userInput,
                    stepID: "fi.mau.telegram.code",
                    loginID: "dummy-telegram-login",
                    instructions: "Enter the code Telegram sent you.",
                    userInput: BridgeLoginUserInputParams(fields: [
                        BridgeLoginInputField(
                            type: .twoFactorCode,
                            id: "code",
                            name: "Login code",
                            pattern: "^[0-9]{5,6}$"
                        ),
                    ])
                ),
                BridgeLoginStep(
                    type: .userInput,
                    stepID: "fi.mau.telegram.2fa_password",
                    loginID: "dummy-telegram-login",
                    instructions: "Enter your two-factor password.",
                    userInput: BridgeLoginUserInputParams(fields: [
                        BridgeLoginInputField(type: .password, id: "password", name: "Password"),
                    ])
                ),
                BridgeLoginStep(
                    type: .complete,
                    stepID: "fi.mau.telegram.complete",
                    loginID: "dummy-telegram-login",
                    complete: BridgeLoginCompleteParams(userLoginID: "777000")
                ),
            ],
        ]
    )
}
