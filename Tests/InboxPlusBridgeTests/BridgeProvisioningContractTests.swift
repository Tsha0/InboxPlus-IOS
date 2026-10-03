import Foundation
import Testing
@testable import InboxPlusBridge
@testable import InboxPlusBridgeService
@testable import InboxPlusRuntime

private func makeClient(_ script: DummyBridge.Script) throws -> (BridgeProvisioningClient, DummyBridge) {
    let bridge = DummyBridge(script: script)
    let client = try BridgeProvisioningClient(
        baseURL: URL(string: "http://127.0.0.1:29337")!,
        provisioningToken: "provisioning-secret",
        userID: "@inboxplus:inboxplus.localhost",
        transport: bridge
    )
    return (client, bridge)
}

// MARK: - Flow discovery

@Test func aBridgeAdvertisesItsLoginFlows() async throws {
    let (client, _) = try makeClient(.instagram)
    let flows = try await client.loginFlows()
    #expect(flows.map(\.id) == ["instagram"])
    #expect(flows.first?.name == "instagram.com")
}

@Test func provisioningRefusesANonLoopbackBridge() {
    // A bridge is a local process; a non-loopback provisioning endpoint is never legitimate.
    #expect(throws: MatrixHTTPError.nonLoopbackBaseURL) {
        try BridgeProvisioningClient(
            baseURL: URL(string: "http://10.0.0.7:29337")!,
            provisioningToken: "t",
            userID: "@inboxplus:inboxplus.localhost"
        )
    }
}

@Test func anUnknownFlowIsRejected() async throws {
    let (client, _) = try makeClient(.instagram)
    await #expect(throws: (any Error).self) {
        _ = try await client.startLogin(flowID: "not-a-flow")
    }
}

// MARK: - Instagram: the cookie flow Phase 4 certifies

@Test func instagramLoginIsACookieStepNamingEveryRequiredCookie() async throws {
    let (client, _) = try makeClient(.instagram)
    let step = try await client.startLogin(flowID: "instagram")

    #expect(step.type == .cookies)
    #expect(step.cookies?.url == "https://www.instagram.com/accounts/login/")
    // These are the cookies mautrix-meta actually requires.
    #expect(
        Set(step.cookies?.requiredFieldIDs ?? [])
            == ["sessionid", "csrftoken", "ds_user_id", "mid", "ig_did"]
    )
    #expect(step.cookies?.waitForURLPattern?.isEmpty == false)
}

@Test func submittingEveryInstagramCookieCompletesTheLogin() async throws {
    let (client, bridge) = try makeClient(.instagram)
    let step = try await client.startLogin(flowID: "instagram")

    let cookies = [
        "sessionid": "sess", "csrftoken": "csrf", "ds_user_id": "1",
        "mid": "mid", "ig_did": "did",
    ]
    try BridgeProvisioningClient.validate(cookies, against: step)
    let done = try await client.submit(
        loginID: step.loginID!,
        stepID: step.stepID,
        type: .cookies,
        values: cookies
    )

    #expect(done.type == .complete)
    #expect(done.isTerminal)
    #expect(done.complete?.userLoginID == "17841400000000000")
    #expect(await bridge.submissions().first?["sessionid"] == "sess")
}

@Test func aMissingInstagramCookieIsCaughtBeforeLeavingTheMachine() async throws {
    // Break caught: submitting an incomplete cookie set fails at the network instead of locally.
    let (client, bridge) = try makeClient(.instagram)
    let step = try await client.startLogin(flowID: "instagram")

    #expect(throws: BridgeLoginError.missingRequiredField("ig_did")) {
        try BridgeProvisioningClient.validate(
            ["sessionid": "s", "csrftoken": "c", "ds_user_id": "1", "mid": "m"],
            against: step
        )
    }
    #expect(await bridge.submissions().isEmpty)
}

// MARK: - WhatsApp: phone pairing

@Test func whatsAppLoginRequestsAPhoneNumber() async throws {
    let (client, _) = try makeClient(.whatsApp)
    let step = try await client.startLogin(flowID: "phone")

    #expect(step.type == .userInput)
    #expect(step.userInput?.fields.first?.type == .phoneNumber)
    #expect(step.userInput?.fields.first?.id == "phone_number")
    #expect(!step.isTerminal)
}

@Test func whatsAppDisplaysAPairingCodeThenCompletes() async throws {
    let (client, bridge) = try makeClient(.whatsApp)
    let phone = try await client.startLogin(flowID: "phone")
    let code = try await client.submit(
        loginID: phone.loginID!,
        stepID: phone.stepID,
        type: .userInput,
        values: ["phone_number": "+15551234567"]
    )
    #expect(code.type == .displayAndWait)
    #expect(code.displayAndWait?.type == .code)
    #expect(code.displayAndWait?.data == "ABCD-EFGH")
    #expect(!code.instructions.isEmpty)
    #expect(await bridge.submissions().first == ["phone_number": "+15551234567"])

    let done = try await client.submit(
        loginID: code.loginID!,
        stepID: code.stepID,
        type: .displayAndWait,
        values: [:]
    )
    #expect(done.type == .complete)
    #expect(done.complete?.userLoginID == "15551234567")
}

// MARK: - Telegram: multi-step input including two-factor

@Test func telegramWalksPhoneThenCodeThenTwoFactor() async throws {
    let (client, _) = try makeClient(.telegram)

    let phone = try await client.startLogin(flowID: "phone")
    #expect(phone.type == .userInput)
    #expect(phone.userInput?.fields.first?.type == .phoneNumber)
    try BridgeProvisioningClient.validate(["phone_number": "+15551234567"], against: phone)

    let code = try await client.submit(
        loginID: phone.loginID!,
        stepID: phone.stepID,
        type: .userInput,
        values: ["phone_number": "+15551234567"]
    )
    #expect(code.userInput?.fields.first?.type == .twoFactorCode)

    let password = try await client.submit(
        loginID: code.loginID!,
        stepID: code.stepID,
        type: .userInput,
        values: ["code": "12345"]
    )
    #expect(password.userInput?.fields.first?.type == .password)

    let done = try await client.submit(
        loginID: password.loginID!,
        stepID: password.stepID,
        type: .userInput,
        values: ["password": "hunter2"]
    )
    #expect(done.type == .complete)
}

@Test(arguments: ["not-a-number", "12345", "", "+1", "+abcdefghij"])
func aMalformedPhoneNumberIsRejectedLocally(_ value: String) async throws {
    let (client, _) = try makeClient(.telegram)
    let phone = try await client.startLogin(flowID: "phone")
    #expect(throws: (any Error).self) {
        try BridgeProvisioningClient.validate(["phone_number": value], against: phone)
    }
}

@Test func aWellFormedPhoneNumberIsAccepted() async throws {
    let (client, _) = try makeClient(.telegram)
    let phone = try await client.startLogin(flowID: "phone")
    #expect(throws: Never.self) {
        try BridgeProvisioningClient.validate(["phone_number": "+447700900123"], against: phone)
    }
}

// MARK: - Secret handling

@Test func secretFieldsAreMarkedSoTheUIneverEchoesThem() {
    #expect(BridgeLoginInputFieldType.password.isSecret)
    #expect(BridgeLoginInputFieldType.token.isSecret)
    #expect(BridgeLoginInputFieldType.twoFactorCode.isSecret)
    #expect(!BridgeLoginInputFieldType.phoneNumber.isSecret)
    #expect(!BridgeLoginInputFieldType.username.isSecret)
}

// MARK: - Wire format

@Test func stepsDecodeFromTheRealBridgeWireFormat() throws {
    // Snake-cased keys exactly as mautrix bridgev2 emits them.
    let json = """
    {
      "type": "user_input",
      "step_id": "fi.mau.telegram.phone",
      "instructions": "Enter your phone number.",
      "user_input": {
        "fields": [
          {"type": "phone_number", "id": "phone_number", "name": "Phone number",
           "description": "", "pattern": "^\\\\+[0-9]{6,15}$"}
        ]
      }
    }
    """
    let step = try JSONDecoder().decode(BridgeLoginStep.self, from: Data(json.utf8))
    #expect(step.type == .userInput)
    #expect(step.stepID == "fi.mau.telegram.phone")
    #expect(step.userInput?.fields.first?.accepts("+15551234567") == true)
    #expect(step.userInput?.fields.first?.accepts("nope") == false)
}

@Test func everyStepTypeInTheProtocolIsModelled() {
    // A step type Inbox+ cannot decode would silently strand a login.
    let wireNames = ["user_input", "cookies", "client_http", "display_and_wait", "webauthn", "complete"]
    for name in wireNames {
        #expect(BridgeLoginStepType(rawValue: name) != nil, "unmodelled step type \(name)")
    }
}
