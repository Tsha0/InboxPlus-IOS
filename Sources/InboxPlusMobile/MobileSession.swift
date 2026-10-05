import Foundation
import Observation
import InboxPlusCore
import InboxPlusFeatures
import InboxPlusGateway
import InboxPlusRemote

@MainActor @Observable
final class MobileSession {
    var model: InboxPlusAppModel?
    var client: CompanionClient?
    var gateway: CompanionGateway?
    var isDemo = false
    var error: String?
    var isConnecting = false
    private let credentials: any PairingCredentialStore
    private let storage: any MobileLocalStorage
    private let makeGateway: (CompanionClient) -> any MessagingGateway
    private var generation = UUID()

    init(credentials: any PairingCredentialStore = PairingKeychain(),
         storage: any MobileLocalStorage = FileMobileStorage(),
         makeGateway: @escaping (CompanionClient) -> any MessagingGateway = { CompanionGateway(client: $0) },
         launchArguments: [String] = ProcessInfo.processInfo.arguments,
         automaticallyRestore: Bool = true) {
        self.credentials = credentials; self.storage = storage; self.makeGateway = makeGateway
        if launchArguments.contains("--demo") { demo(); return }
        if automaticallyRestore { Task { await restore() } }
    }
    func restore() async {
        do {
            if let config = try credentials.load() { await connect(config, save: false) }
        } catch { self.error = error.localizedDescription }
    }
    func connect(_ config: CompanionConfiguration, save: Bool = true) async {
        guard !isConnecting else { return }
        let attempt = UUID(); generation = attempt; isConnecting = true
        defer { if generation == attempt { isConnecting = false } }
        var pendingModel: InboxPlusAppModel?
        do {
            let client = CompanionClient(configuration: config)
            let loader = MediaLoader(cache: try MediaCache(directory: storage.mediaDirectory), fetcher: CompanionMediaFetcher(client: client), freeSpace: VolumeFreeSpaceReporter(url: storage.mediaDirectory))
            let gateway = makeGateway(client)
            let next = InboxPlusAppModel(gateway: gateway, directory: try storage.loadContacts(), media: MediaController(loader: loader))
            pendingModel = next
            try await next.start()
            // A slow connection must not restore credentials after the user leaves or unpairs.
            guard generation == attempt else { next.stop(); return }
            if save { try credentials.save(config) }
            model?.stop()
            self.client = client; self.gateway = gateway as? CompanionGateway
            model = next; isDemo = false; error = nil
        } catch {
            pendingModel?.stop()
            if generation == attempt { self.error = error.localizedDescription }
        }
    }
    func demo() {
        generation = UUID(); isConnecting = false
        model?.stop(); client = nil; gateway = nil; isDemo = true; error = nil
        let demoModel = InboxPlusAppModel(gateway: InMemoryMessagingGateway(seed: Fixtures.demoSnapshot), directory: Fixtures.directory)
        model = demoModel
        Task { try? await demoModel.start() }
    }
    func saveContacts() {
        guard !isDemo, let model else { return }
        do { try storage.saveContacts(model.contactDirectory) }
        catch { self.error = "Could not save contacts: \(error.localizedDescription)" }
    }
    func resume() async {
        do { try await model?.start() }
        catch { model?.reportStartupFailure(error) }
    }
    func suspend() { saveContacts(); model?.stop() }
    func pauseAccount(_ account: ConnectedAccount, paused: Bool) {
        if paused { model?.disconnect(accountID: account.id) } else { model?.reconnect(accountID: account.id) }
        Task { await gateway?.setPaused(paused, accountID: account.id) }
    }
    func unpair() {
        generation = UUID(); isConnecting = false
        model?.stop(); model = nil; client = nil; gateway = nil; isDemo = false; error = nil
        do { try credentials.delete(); try storage.clear() }
        catch { self.error = "Could not clear local data: \(error.localizedDescription)" }
    }
}

@MainActor protocol MobileLocalStorage {
    var mediaDirectory: URL { get }
    func loadContacts() throws -> ContactDirectory
    func saveContacts(_ directory: ContactDirectory) throws
    func clear() throws
}

@MainActor struct FileMobileStorage: MobileLocalStorage {
    let directoryURL: URL
    let mediaDirectory: URL
    init(directoryURL: URL = URL.applicationSupportDirectory.appendingPathComponent("contacts.json"),
         mediaDirectory: URL = URL.cachesDirectory.appendingPathComponent("InboxPlusMedia")) {
        self.directoryURL = directoryURL; self.mediaDirectory = mediaDirectory
    }
    func loadContacts() throws -> ContactDirectory {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return ContactDirectory() }
        return try JSONDecoder().decode(SavedDirectory.self, from: Data(contentsOf: directoryURL)).directory
    }
    func saveContacts(_ directory: ContactDirectory) throws {
        try FileManager.default.createDirectory(at: directoryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(SavedDirectory(directory)).write(to: directoryURL, options: [.atomic, .completeFileProtection])
    }
    func clear() throws {
        for url in [directoryURL, mediaDirectory] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
private struct SavedDirectory: Codable {
    let people: [String: InboxPlusPerson]
    let links: [String: PersonLink]
    init(_ directory: ContactDirectory) { people = directory.people; links = directory.links }
    var directory: ContactDirectory { get throws { try ContactDirectory(people: people, links: links) } }
}

@MainActor extension MobileSession {
    static func applicationSession() -> MobileSession {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing") {
            let root = URL.cachesDirectory.appendingPathComponent("InboxPlusUITestData")
            let credentials = PairingKeychain(service: "com.inboxplus.ios.ui-tests")
            let storage = FileMobileStorage(directoryURL: root.appendingPathComponent("contacts.json"), mediaDirectory: root.appendingPathComponent("media"))
            let restore = arguments.contains("--ui-restore")
            if !restore { try? credentials.delete(); try? storage.clear() }
            return MobileSession(credentials: credentials, storage: storage, launchArguments: arguments, automaticallyRestore: restore)
        }
        #endif
        return MobileSession()
    }
}
