#if os(iOS)
import SwiftUI
import Security
import InboxPlusCore
import InboxPlusUI
import InboxPlusFeatures
import InboxPlusGateway
import InboxPlusRemote
import InboxPlusBridge

@MainActor @Observable
final class MobileSession {
    var model: InboxPlusAppModel?
    var client: CompanionClient?
    var isDemo = false
    var error: String?
    var isConnecting = false
    private let directoryURL = URL.applicationSupportDirectory.appendingPathComponent("contacts.json")
    init() {
        if ProcessInfo.processInfo.arguments.contains("--demo") { demo(); return }
        if let config = try? PairingKeychain.load() { Task { await connect(config, save: false) } }
    }
    func connect(_ config: CompanionConfiguration, save: Bool = true) async {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        do {
            let client = CompanionClient(configuration: config)
            let cacheURL = URL.cachesDirectory.appendingPathComponent("InboxPlusMedia")
            let loader = MediaLoader(cache: try MediaCache(directory: cacheURL), fetcher: CompanionMediaFetcher(client: client), freeSpace: VolumeFreeSpaceReporter(url: cacheURL))
            let directory = (try? Data(contentsOf: directoryURL)).flatMap { try? JSONDecoder().decode(SavedDirectory.self, from: $0).directory } ?? ContactDirectory()
            let next = InboxPlusAppModel(gateway: CompanionGateway(client: client), directory: directory, media: MediaController(loader: loader))
            try await next.start()
            if save { try PairingKeychain.save(config) }
            model?.stop()
            self.client = client; model = next; isDemo = false; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func demo() {
        model?.stop(); client = nil; isDemo = true; error = nil
        model = InboxPlusAppModel(gateway: InMemoryMessagingGateway(seed: Fixtures.demoSnapshot), directory: Fixtures.directory)
        Task { try? await model?.start() }
    }
    func saveContacts() {
        guard !isDemo, let model else { return }
        do {
            try FileManager.default.createDirectory(at: directoryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(SavedDirectory(model.contactDirectory)).write(to: directoryURL, options: [.atomic, .completeFileProtection])
        } catch { self.error = "Could not save contacts: \(error.localizedDescription)" }
    }
    func unpair() {
        model?.stop(); model = nil; client = nil; isDemo = false
        PairingKeychain.delete()
        try? FileManager.default.removeItem(at: directoryURL)
        try? FileManager.default.removeItem(at: URL.cachesDirectory.appendingPathComponent("InboxPlusMedia"))
    }
}
private struct SavedDirectory: Codable {
    let people: [String: InboxPlusPerson]
    let links: [String: PersonLink]
    init(_ directory: ContactDirectory) { people = directory.people; links = directory.links }
    var directory: ContactDirectory? { try? ContactDirectory(people: people, links: links) }
}
@MainActor private enum PairingKeychain {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.inboxplus.ios.pairing", kSecAttrAccount as String: "companion"]
    static func save(_ configuration: CompanionConfiguration) throws {
        let data = try JSONEncoder().encode(configuration)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw CompanionError.server("Could not update the pairing key (\(update)).") }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw CompanionError.server("Could not store the pairing key (\(status)).") }
    }
    static func load() throws -> CompanionConfiguration? {
        var item = query; item[kSecReturnData as String] = true; item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        let saved = try JSONDecoder().decode(CompanionConfiguration.self, from: data)
        return try CompanionConfiguration(address: saved.address.absoluteString, token: saved.token)
    }
    static func delete() { SecItemDelete(query as CFDictionary) }
}

public struct MobileAppView: View {
    @State private var session = MobileSession()
    @Environment(\.scenePhase) private var scenePhase
    public init() {}
    public var body: some View {
        Group {
            if let model = session.model {
                MobileHome(session: session, model: model)
            } else { PairingView(session: session) }
        }
        .tint(.primary)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { do { try await session.model?.start() } catch { session.model?.reportStartupFailure(error) } }
            } else if phase == .background {
                session.saveContacts(); session.model?.stop()
            }
        }
    }
}

private struct PairingView: View {
    @Bindable var session: MobileSession
    @State private var address = ""
    @State private var token = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    InboxPlusBrandMark().frame(width: 78, height: 78).padding(.top, 36)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your people.\nOne inbox.").font(.system(.largeTitle, design: .rounded, weight: .bold))
                        Text("Inbox+ for iPhone and iPad").font(.title3).foregroundStyle(.secondary)
                    }
                    Text("Connect to your Mac to bring your messages, accounts, and conversations with you.").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 16) {
                        TextField("Mac HTTPS address", text: $address).keyboardType(.URL).textContentType(.URL).accessibilityIdentifier("pairing-address")
                        Divider()
                        SecureField("Pairing key", text: $token).accessibilityIdentifier("pairing-key")
                    }.textInputAutocapitalization(.never).autocorrectionDisabled().padding(18).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
                    if let error = session.error { Text(error).font(.callout).foregroundStyle(.red).accessibilityIdentifier("pairing-error") }
                    Button {
                        do {
                            let config = try CompanionConfiguration(address: address, token: token)
                            Task { await session.connect(config) }
                        } catch { session.error = error.localizedDescription }
                    } label: {
                        HStack { Spacer(); if session.isConnecting { ProgressView() }; Text(session.isConnecting ? "Connecting…" : "Connect to Mac").fontWeight(.semibold); Spacer() }.padding(.vertical, 10)
                    }.buttonStyle(.borderedProminent).tint(.primary).disabled(session.isConnecting || address.isEmpty || token.isEmpty).accessibilityIdentifier("pairing-connect")
                    Text("Keep Inbox+ Companion running on your Mac. Use its secure HTTPS address and pairing key. Your key is stored in this device’s Keychain.").font(.footnote).foregroundStyle(.secondary)
                    Button("Explore demo inbox") { session.demo() }.frame(maxWidth: .infinity).accessibilityIdentifier("explore-demo")
                }.padding(28).frame(maxWidth: 540)
            }.frame(maxWidth: .infinity).navigationTitle("Inbox+").navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct MobileHome: View {
    @Bindable var session: MobileSession
    @Bindable var model: InboxPlusAppModel
    @State private var tab = 0
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var showPicker = false
    @State private var login: BridgeLoginController?
    @State private var showLogin = false
    @State private var notice: String?
    @State private var pendingRemoval: ConnectedAccount?
    @State private var showUnpair = false
    var body: some View {
        VStack(spacing: 0) {
            if session.isDemo {
                Text("DEMO · Sample conversations").font(.caption.weight(.semibold)).padding(6).frame(maxWidth: .infinity).background(.quaternary)
            }
            if let message = model.healthBannerMessage {
                Label(message, systemImage: "wifi.exclamationmark").font(.caption).padding(10).frame(maxWidth: .infinity).background(.quaternary)
            }
            TabView(selection: $tab) {
                NavigationSplitView(preferredCompactColumn: $compactColumn) {
                    InboxView(items: model.inboxItems, onSelect: { model.selectInboxItem($0); compactColumn = .detail })
                        .navigationTitle("Inbox+").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showPicker = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add account") } }
                } detail: { detail }
                .tabItem { Label("Inbox", systemImage: "tray") }.tag(0)
                NavigationStack {
                    List(model.people) { person in
                        NavigationLink {
                            ContactSummaryView(personName: person.displayName, summaries: model.summaries(for: person.id), onOpen: { model.openConversation($0); tab = 0; compactColumn = .detail })
                        } label: { Label(person.displayName, systemImage: "person.crop.circle") }
                    }.overlay { if model.people.isEmpty { ContentUnavailableView("No linked people", systemImage: "person.2", description: Text("Open a conversation and choose Link to person to group their accounts.")) } }
                        .navigationTitle("Contacts")
                }.tabItem { Label("Contacts", systemImage: "person.2") }.tag(1)
                NavigationStack { settings }.tabItem { Label("Settings", systemImage: "gearshape") }.tag(2)
            }
        }
        .sheet(isPresented: $showPicker) {
            AccountPickerView(connectedPlatforms: model.platformsWithAccounts, onSelect: connect, onCancel: { showPicker = false })
        }
        .sheet(isPresented: $showLogin) {
            if let login {
                LoginStepView(controller: login, onFinished: { _ in
                    showLogin = false
                    if let config = session.client?.configuration { Task { await session.connect(config) } }
                }, onCancel: { showLogin = false })
            }
        }
        .alert("Inbox+", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("OK") { notice = nil } } message: { Text(notice ?? "") }
        .onChange(of: model.detailSelection) { session.saveContacts() }
        .confirmationDialog("Remove this account’s history from this device?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
            Button("Remove from this device", role: .destructive) { if let account = pendingRemoval { model.eraseAccount(accountID: account.id) }; pendingRemoval = nil }
        } message: { Text("The account remains connected on your Mac. Reconnecting this device can load its history again.") }
        .confirmationDialog("Disconnect this device?", isPresented: $showUnpair, titleVisibility: .visible) {
            Button("Disconnect and clear local data", role: .destructive) { session.unpair() }
        }
    }
    @ViewBuilder private var detail: some View {
        switch model.detailSelection {
        case .empty: ContentUnavailableView("Choose a conversation", systemImage: "message", description: Text("All your networks, together."))
        case let .personSummary(id):
            ContactSummaryView(personName: model.people.first { $0.id == id }?.displayName ?? "Contact", summaries: model.summaries(for: id), onOpen: model.openConversation)
                .navigationTitle("Conversations")
        case let .conversation(route):
            ConversationView(model: model, route: route).id(route).navigationBarTitleDisplayMode(.inline)
        }
    }
    private var settings: some View {
        List {
            Section("Connection") {
                Label(session.isDemo ? "Demo inbox" : "Connected through your Mac", systemImage: session.isDemo ? "play.circle" : model.health.symbolName)
                if let host = session.client?.configuration.address.host { Text(host).font(.caption).foregroundStyle(.secondary) }
                Text("Messages sync while Inbox+ is open. Your Mac must stay online.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Accounts") {
                ForEach(model.accounts) { account in
                    HStack {
                        PlatformBadge(platform: account.platform)
                        VStack(alignment: .leading) { Text(account.platform.accessibilityLabel); Text(account.displayName).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Image(systemName: model.isConnected(account.id) ? "checkmark.circle" : "exclamationmark.circle")
                    }.contextMenu {
                        Button("Remove from this device", role: .destructive) { pendingRemoval = account }
                    }
                }
                Button { showPicker = true } label: { Label("Add account", systemImage: "plus") }.accessibilityIdentifier("add-account")
            }
            Section("About") {
                Text("Inbox+ IOS").font(.headline)
                Text("The same inbox. Made for your pocket.").foregroundStyle(.secondary)
                Text("iMessage is provided by the Mac companion. Network availability matches Inbox+ for Mac.").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button(session.isDemo ? "Leave demo" : "Disconnect this device", role: .destructive) { if session.isDemo { session.unpair() } else { showUnpair = true } }.accessibilityIdentifier("disconnect-device")
            }
        }.navigationTitle("Settings")
    }
    private func connect(_ platform: Platform) {
        showPicker = false
        guard let client = session.client else { notice = "Connect to your Mac to add real accounts. Demo mode uses sample conversations."; return }
        guard platform != .iMessage else { notice = "Enable iMessage on your Mac by granting Inbox+ Companion Full Disk Access and Messages Automation permission, then restart the companion."; return }
        login = BridgeLoginController(platform: platform, session: CompanionLoginSession(client: client, platform: platform))
        Task { try? await Task.sleep(for: .milliseconds(350)); showLogin = true }
    }
}
#endif
