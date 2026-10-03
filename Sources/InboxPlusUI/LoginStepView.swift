import InboxPlusBridge
import InboxPlusCore
import InboxPlusFeatures
import SwiftUI

/// Renders whatever the bridge asks for next.
///
/// One view per step type, chosen by the protocol rather than by network. Adding a network is
/// catalog data; it is never a new screen.
public struct LoginStepView: View {
    @Bindable private var controller: BridgeLoginController
    private let onFinished: (String) -> Void
    private let onCancel: () -> Void

    public init(
        controller: BridgeLoginController,
        onFinished: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.controller = controller
        self.onFinished = onFinished
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let failure = controller.failureMessage {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.secondary.opacity(0.15))
                    .accessibilityIdentifier("login-failure")
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .task { await controller.start() }
        // Escape and the close button dismiss the sheet without going through Cancel; the bridge
        // has to hear about those too.
        .onDisappear { controller.cancel() }
        .accessibilityIdentifier("login-flow")
    }

    private var header: some View {
        HStack(spacing: 10) {
            PlatformBadge(platform: controller.platform)
            VStack(alignment: .leading, spacing: 2) {
                Text("Connect \(controller.platform.accessibilityLabel)")
                    .font(.headline)
                if let instructions = controller.currentStep?.instructions, !instructions.isEmpty {
                    Text(instructions)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if controller.isBusy { ProgressView().controlSize(.small) }
        }
        .padding(16)
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .loadingFlows:
            ProgressView("Asking the bridge how to sign in…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .choosingFlow(flows):
            LoginFlowPickerView(flows: flows) { flow in
                Task { await controller.begin(flowID: flow.id) }
            }

        case let .step(step), let .submitting(step):
            stepContent(step)

        case .finished:
            ContentUnavailableView(
                "\(controller.platform.accessibilityLabel) is connected",
                systemImage: "checkmark.circle.fill",
                description: Text("Your conversations will appear in the inbox as they sync.")
            )
            .accessibilityIdentifier("login-complete")

        case let .failed(message):
            ContentUnavailableView(
                "Could not sign in",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .accessibilityIdentifier("login-failed")
        }
    }

    @ViewBuilder private func stepContent(_ step: BridgeLoginStep) -> some View {
        switch step.type {
        case .userInput:
            UserInputStepView(step: step, controller: controller)

        case .cookies:
            if let parameters = step.cookies {
                CookieStepView(parameters: parameters, controller: controller)
            } else {
                unsupported("This bridge asked for cookies but did not say which.")
            }

        case .displayAndWait:
            DisplayAndWaitStepView(parameters: step.displayAndWait, instructions: step.instructions)

        case .clientHTTP, .webAuthn:
            // Modelled so the step decodes and the user is told plainly, rather than the login
            // silently stalling on a screen Inbox+ cannot draw.
            unsupported(
                """
                \(controller.platform.accessibilityLabel) is asking for a sign-in method Inbox+ \
                does not support yet.
                """
            )

        case .complete:
            EmptyView()
        }
    }

    private func unsupported(_ message: String) -> some View {
        ContentUnavailableView(
            "Unsupported sign-in step",
            systemImage: "questionmark.circle",
            description: Text(message)
        )
    }

    private var footer: some View {
        HStack {
            if let message = controller.blockingValidationMessage,
               controller.currentStep?.type == .cookies {
                Label(message, systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") {
                controller.cancel()
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
            if case let .finished(userLoginID) = controller.phase {
                Button("Done") { onFinished(userLoginID) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Continue") { Task { await controller.submit() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.canSubmit)
                    .accessibilityIdentifier("login-continue")
            }
        }
        .padding(16)
    }
}

/// A typed form for a `user_input` step.
struct UserInputStepView: View {
    let step: BridgeLoginStep
    @Bindable var controller: BridgeLoginController

    var body: some View {
        Form {
            ForEach(step.userInput?.fields ?? [], id: \.id) { field in
                VStack(alignment: .leading, spacing: 4) {
                    field.editor(
                        value: Binding(
                            get: { controller.values[field.id] ?? "" },
                            set: { controller.setValue($0, for: field.id) }
                        )
                    )
                    if !field.description.isEmpty {
                        Text(field.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

private extension BridgeLoginInputField {
    /// Secret fields get a `SecureField` so the value is never drawn on screen.
    @ViewBuilder
    func editor(value: Binding<String>) -> some View {
        if type.isSecret {
            SecureField(name, text: value)
                .textContentType(type == .password ? .password : .oneTimeCode)
                .accessibilityIdentifier("login-field-\(id)")
        } else {
            TextField(name, text: value)
                .accessibilityIdentifier("login-field-\(id)")
        }
    }
}

/// A `display_and_wait` step: show the code, wait for the bridge to say it was accepted.
struct DisplayAndWaitStepView: View {
    let parameters: BridgeLoginDisplayAndWaitParams?
    /// What to do with the code, in full. The header shows this too, but on one truncated line —
    /// and for a phone-number login the instructions are the only place that says where in
    /// WhatsApp the code goes, so a code shown without them is a code nobody can use.
    let instructions: String

    var body: some View {
        VStack(spacing: 16) {
            switch parameters?.type {
            case .qr:
                if let data = parameters?.data, let image = QRCodeRenderer.image(for: data) {
                    // Drawn at the size it was rendered: resizing resamples the module grid, and a
                    // camera reads an evenly gridded code far more reliably than a resampled one.
                    Image(platformImage: image)
                        .interpolation(.none)
                        // A scanner needs the light quiet zone around the code; in dark mode the
                        // window background supplies the opposite of one.
                        .padding(16)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("QR code to scan")
                        .accessibilityIdentifier("login-qr")
                } else {
                    ProgressView()
                }
            case .emoji, .code:
                Text(parameters?.data ?? "")
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("login-code")
            case .nothing, .none:
                ProgressView()
            }
            if !instructions.isEmpty {
                Text(instructions)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
                    .accessibilityIdentifier("login-instructions")
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for you to confirm on your phone…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// A cookie step, with the two ways a network will actually let someone sign in.
///
/// Signing in on the page is the better experience where it works. It does not always work: Google
/// refuses OAuth from any embedded web view, and the bridges' own instructions say to paste cookies
/// copied from browser devtools instead. Offering only the page would leave those networks
/// impossible to connect from an app that otherwise looks like it supports them.
private struct CookieStepView: View {
    let parameters: BridgeLoginCookiesParams
    @Bindable var controller: BridgeLoginController
    @State private var method: Method = .signIn
    @State private var pasted = ""

    private enum Method: String, CaseIterable, Identifiable {
        case signIn, paste
        var id: String { rawValue }
        var label: String {
            switch self {
            case .signIn: "Sign in here"
            case .paste: "Paste from my browser"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("How would you like to sign in?", selection: $method) {
                ForEach(Method.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("cookie-method")

            Divider()

            switch method {
            case .signIn:
                CookieLoginWebView(parameters: parameters) { captured in
                    controller.replaceValues(captured)
                }
                .accessibilityIdentifier("login-cookies-webview")
            case .paste:
                pasteForm
            }
        }
    }

    private var pasteForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("""
            Sign in to \(controller.platform.accessibilityLabel) in Safari or Chrome, open \
            developer tools, and copy the request as cURL — or paste a JSON object of cookies. \
            Inbox+ reads only the values this bridge asked for and ignores everything else.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)

            TextEditor(text: $pasted)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .accessibilityLabel("Pasted cookies or cURL command")
                .accessibilityIdentifier("cookie-paste-field")

            if !pasted.isEmpty {
                let missing = CookiePasteParser.missingRequiredFieldIDs(pasted: pasted, to: parameters)
                if missing.isEmpty {
                    Label("Found every cookie this bridge needs.", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(InboxPlusTheme.ink)
                } else {
                    // Naming what is missing beats a disabled button with no explanation.
                    Label(
                        "Still missing: \(missing.joined(separator: ", "))",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .onChange(of: pasted) {
            controller.replaceValues(CookiePasteParser.match(pasted: pasted, to: parameters))
        }
    }
}
