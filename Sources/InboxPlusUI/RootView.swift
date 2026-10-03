#if os(macOS)
import SwiftUI
import InboxPlusBridge
import InboxPlusCore
import InboxPlusFeatures

/// Opens a login session against the bridge for one network.
///
/// Supplied by the app layer, which owns the bridge processes. `InboxPlusUI` stays ignorant of how a
/// bridge is installed or supervised — it only renders the conversation the bridge asks for.
public typealias BridgeLoginSessionProvider =
    @MainActor (Platform) async throws -> BridgeLoginPreparation

public struct RootView: View {
    @Bindable var model: InboxPlusAppModel
    @State private var section: SidebarSection = .inbox
    @State private var accountFlow: AccountFlow?
    @State private var connectFailure: String?
    /// Informational, not a failure — reusing the failure alert would title good news as an error.
    @State private var connectNotice: ConnectNotice?

    private let makeLoginSession: BridgeLoginSessionProvider?

    enum AccountFlow: Identifiable {
        case picker
        /// Downloading and registering a bridge this profile has never installed, which takes long
        /// enough that a picker sitting there unchanged would read as a dead click.
        case installing(Platform)
        case login(Platform, BridgeLoginController)
        case iMessagePermissions

        // The platform is carried alongside the controller because the controller is main-actor
        // isolated and `id` is not.
        var id: String {
            switch self {
            case .picker: "picker"
            case let .installing(platform): "installing-\(platform.rawValue)"
            case let .login(platform, _): "login-\(platform.rawValue)"
            case .iMessagePermissions: "imessage"
            }
        }
    }

    /// An alert that reports something worked, with its own title.
    struct ConnectNotice: Identifiable {
        let title: String
        let message: String
        var id: String { title }
    }

    public init(model: InboxPlusAppModel, makeLoginSession: BridgeLoginSessionProvider? = nil) {
        self.model = model
        self.makeLoginSession = makeLoginSession
    }

    private var selectedInboxID: InboxItem.ID? {
        switch model.detailSelection {
        case .empty: nil
        case let .personSummary(id): .person(id)
        case let .conversation(route): .conversation(route)
        }
    }

    private var selectedPersonID: String? {
        guard case let .personSummary(id) = model.detailSelection else { return nil }
        return id
    }

    public var body: some View {
        VStack(spacing: 0) {
            if model.health == .starting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Preparing your inbox…")
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(0.15))
                .accessibilityIdentifier("startup-progress")
            }
            if let message = model.healthBannerMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.secondary.opacity(0.15))
                    .accessibilityIdentifier("health-banner")
            }
            HStack(spacing: 0) {
                NavigationRailView(selection: $section)
                    .fixedSize(horizontal: true, vertical: false)
                Divider()
                sidebar
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 380)
                Divider()
                detail
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .tint(InboxPlusTheme.ink)
        .accentColor(InboxPlusTheme.ink)
        // The menu bar panel owns the connections overview; a Connect there lands here as a
        // pending request because the login sheet has to present from a window.
        .onChange(of: model.pendingConnectionRequest, initial: true) { _, platform in
            guard let platform else { return }
            model.clearConnectionRequest()
            startConnecting(platform)
        }
        .sheet(item: $accountFlow) { flow in
            switch flow {
            case .picker:
                AccountPickerView(
                    connectedPlatforms: model.platformsWithAccounts,
                    onSelect: startConnecting,
                    onCancel: { accountFlow = nil }
                )
            case let .installing(platform):
                BridgeInstallProgressView(platform: platform)
            case let .login(platform, controller):
                LoginStepView(
                    controller: controller,
                    onFinished: { userLoginID in
                        finishConnecting(platform: platform, userLoginID: userLoginID)
                    },
                    onCancel: { accountFlow = nil }
                )
            case .iMessagePermissions:
                IMessagePermissionsView(
                    onConnect: {
                        // There is nothing to sign in to. Inbox+ opens the Messages database at
                        // launch, so a grant made just now takes effect on the next launch — and
                        // adding an account here would invent one the gateway never produced.
                        accountFlow = nil
                        connectNotice = ConnectNotice(
                            title: "iMessage is connected",
                            message: """
                            iMessage is ready. Quit and reopen Inbox+ to load your conversations — \
                            macOS only applies Full Disk Access to a newly launched process.
                            """
                        )
                    },
                    onCancel: { accountFlow = nil }
                )
            }
        }
        .alert(
            "Could not start the bridge",
            isPresented: Binding(
                get: { connectFailure != nil },
                set: { if !$0 { connectFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) { connectFailure = nil }
        } message: {
            Text(connectFailure ?? "")
        }
        .alert(
            connectNotice?.title ?? "",
            isPresented: Binding(
                get: { connectNotice != nil },
                set: { if !$0 { connectNotice = nil } }
            )
        ) {
            Button("OK", role: .cancel) { connectNotice = nil }
        } message: {
            Text(connectNotice?.message ?? "")
        }
    }

    private func startConnecting(_ platform: Platform) {
        // iMessage authenticates through macOS rather than a bridge process, so it takes the
        // permissions route instead of a login flow.
        guard platform != .iMessage else {
            accountFlow = .iMessagePermissions
            return
        }
        guard let makeLoginSession else {
            connectFailure = """
            Account setup is not ready. No unique messaging profile was selected. \
            Prepare a messaging profile and reopen Inbox+ before connecting a network.
            """
            accountFlow = nil
            return
        }
        Task { @MainActor in
            accountFlow = .installing(platform)
            do {
                switch try await makeLoginSession(platform) {
                case let .ready(session):
                    accountFlow = .login(
                        platform,
                        BridgeLoginController(platform: platform, session: session)
                    )
                case let .installedPendingRuntimeRestart(outcome):
                    accountFlow = nil
                    connectNotice = ConnectNotice(
                        title: outcome.title,
                        message: outcome.message
                    )
                }
            } catch {
                connectFailure = String(describing: error)
                accountFlow = nil
            }
        }
    }

    private func finishConnecting(platform: Platform, userLoginID: String) {
        do {
            try model.addAccount(
                ConnectedAccount(
                    id: "\(platform.rawValue):\(userLoginID)",
                    platform: platform,
                    displayName: userLoginID.isEmpty ? platform.accessibilityLabel : userLoginID
                )
            )
        } catch {
            connectFailure = String(describing: error)
        }
        accountFlow = nil
    }

    @ViewBuilder private var sidebar: some View {
        switch section {
        case .inbox:
            InboxView(
                items: model.inboxItems,
                selectedID: selectedInboxID,
                onSelect: model.selectInboxItem
            )
        case .contacts:
            ContactsListView(
                people: model.people,
                items: model.inboxItems,
                selectedPersonID: selectedPersonID,
                onSelect: model.selectPerson
            )
        case .settings:
            AccountsListView(
                accounts: model.accounts,
                health: model.health,
                isConnected: model.isConnected,
                lastActivity: { model.lastActivity(for: $0) },
                onAddAccount: { accountFlow = .picker },
                onDisconnect: { model.disconnect(accountID: $0.id) },
                onReconnect: { model.reconnect(accountID: $0.id) },
                onErase: { model.eraseAccount(accountID: $0.id) }
            )
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.detailSelection {
        case .empty:
            ContentUnavailableView(
                "Choose a conversation",
                systemImage: "message",
                description: Text("Pick someone from the list to see their messages.")
            )
        case let .personSummary(personID):
            ContactSummaryView(
                personName: model.inboxItems.first { $0.id == .person(personID) }?.title
                    ?? model.people.first { $0.id == personID }?.displayName
                    ?? "Contact",
                summaries: model.summaries(for: personID),
                onOpen: model.openConversation
            )
        case let .conversation(route):
            ConversationView(model: model, route: route)
                .id(route)
        }
    }
}

#endif
