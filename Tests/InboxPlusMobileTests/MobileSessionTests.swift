import XCTest
@testable import InboxPlusMobile
import InboxPlusRemote
import InboxPlusFeatures
import InboxPlusGateway
import InboxPlusCore

final class MobileSessionTests: XCTestCase {
    @MainActor func testSuccessfulPairingLoadsContactsAndStoresCredential() async throws {
        let rig = try SessionRig(); defer { rig.clean() }
        let session = rig.session()
        await session.connect(rig.config)
        XCTAssertFalse(session.isConnecting); XCTAssertNil(session.error)
        XCTAssertEqual(rig.credentials.value, rig.config)
        XCTAssertEqual(session.model?.people.map(\.displayName), ["Maya"])
        XCTAssertEqual(session.model?.accounts.count, Fixtures.snapshot.accounts.count)
        session.unpair()
    }
    @MainActor func testRestoreDoesNotRewriteCredential() async throws {
        let rig = try SessionRig(); defer { rig.clean() }
        rig.credentials.value = rig.config
        let session = rig.session()
        await session.restore()
        XCTAssertNotNil(session.model); XCTAssertEqual(rig.credentials.saves, 0)
        session.unpair()
    }
    @MainActor func testFailedConnectionDoesNotSaveCredentials() async throws {
        let rig = try SessionRig(); defer { rig.clean() }
        let session = rig.session(gateway: ControlledGateway(fails: true))
        await session.connect(rig.config)
        XCTAssertNil(session.model); XCTAssertNil(rig.credentials.value)
        XCTAssertNotNil(session.error); XCTAssertFalse(session.isConnecting)
    }
    @MainActor func testCredentialSaveFailureDoesNotPresentPairedSession() async throws {
        let rig = try SessionRig(); defer { rig.clean() }
        rig.credentials.failSave = true
        let session = rig.session()
        await session.connect(rig.config)
        XCTAssertNil(session.model); XCTAssertNil(rig.credentials.value); XCTAssertNotNil(session.error)
    }
    @MainActor func testDuplicatePairingDoesNotStartAnotherRequest() async throws {
        let rig = try SessionRig(); defer { rig.clean() }
        let gateway = ControlledGateway(holds: true)
        let session = rig.session(gateway: gateway)
        let pairing = Task { await session.connect(rig.config) }
        await gateway.waitForLoad()
        await session.connect(rig.config)
        let loads = await gateway.loads; XCTAssertEqual(loads, 1)
        await gateway.release(); await pairing.value
        XCTAssertEqual(rig.credentials.saves, 1)
        session.unpair()
    }
    @MainActor func testUnpairWhileConnectingCannotRestoreSessionOrKey() async throws {
        let rig = try SessionRig(); defer { rig.clean() }
        let gateway = ControlledGateway(holds: true)
        let session = rig.session(gateway: gateway)
        let pairing = Task { await session.connect(rig.config) }
        await gateway.waitForLoad(); session.unpair()
        await gateway.release(); await pairing.value
        XCTAssertNil(session.model); XCTAssertNil(session.client); XCTAssertNil(rig.credentials.value)
        XCTAssertFalse(session.isConnecting)
    }
    @MainActor func testDemoDoesNotPersistCredentialsOrContacts() async throws {
        let rig = try SessionRig(); defer { rig.clean() }
        let before = try Data(contentsOf: rig.storage.directoryURL)
        let session = rig.session(); session.demo(); await session.resume(); session.suspend()
        XCTAssertTrue(session.isDemo); XCTAssertNotNil(session.model)
        XCTAssertEqual(rig.credentials.saves, 0)
        XCTAssertEqual(try Data(contentsOf: rig.storage.directoryURL), before)
        session.unpair()
    }
    @MainActor func testForegroundReloadsAndBackgroundSavesContacts() async throws {
        let rig = try SessionRig(); defer { rig.clean() }
        let gateway = ControlledGateway()
        let session = rig.session(gateway: gateway)
        await session.connect(rig.config); session.suspend(); await session.resume()
        let loads = await gateway.loads; XCTAssertEqual(loads, 2)
        let saved = try rig.storage.loadContacts()
        XCTAssertEqual(saved.people, Fixtures.directory.people)
        XCTAssertEqual(saved.links, Fixtures.directory.links)
        session.unpair()
    }
    @MainActor func testUnpairClearsContactsMediaAndCredentials() async throws {
        let rig = try SessionRig(); defer { rig.clean() }
        let session = rig.session(); await session.connect(rig.config); session.saveContacts()
        try Data([1, 2, 3]).write(to: rig.storage.mediaDirectory.appendingPathComponent("cached"))
        session.unpair()
        XCTAssertNil(rig.credentials.value); XCTAssertNil(session.model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.storage.directoryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.storage.mediaDirectory.path))
    }
    @MainActor func testCorruptContactsAreReportedWithoutOverwritingData() async throws {
        let rig = try SessionRig(); defer { rig.clean() }
        let corrupt = Data("not-json".utf8); try corrupt.write(to: rig.storage.directoryURL)
        let session = rig.session(); await session.connect(rig.config)
        XCTAssertNotNil(session.error); XCTAssertNil(session.model)
        XCTAssertEqual(try Data(contentsOf: rig.storage.directoryURL), corrupt)
    }
}

@MainActor private final class MemoryCredentials: PairingCredentialStore {
    var value: CompanionConfiguration?
    var saves = 0
    var failSave = false
    func load() throws -> CompanionConfiguration? { value }
    func save(_ configuration: CompanionConfiguration) throws {
        if failSave { throw CompanionError.server("Test credential failure") }
        saves += 1; value = configuration
    }
    func delete() throws { value = nil }
}
@MainActor private struct SessionRig {
    let root: URL
    let storage: FileMobileStorage
    let credentials = MemoryCredentials()
    let config: CompanionConfiguration
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        storage = FileMobileStorage(directoryURL: root.appendingPathComponent("contacts.json"), mediaDirectory: root.appendingPathComponent("media"))
        config = try CompanionConfiguration(address: "https://test.example", token: String(repeating: "a", count: 32))
        try storage.saveContacts(Fixtures.directory)
    }
    func session(gateway: any MessagingGateway = ControlledGateway()) -> MobileSession {
        let session = MobileSession(credentials: credentials, storage: storage, makeGateway: { _ in gateway }, launchArguments: [], automaticallyRestore: false)
        return session
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
private actor ControlledGateway: MessagingGateway {
    var loads = 0
    private let holds: Bool
    private let fails: Bool
    private var pending: CheckedContinuation<MessagingSnapshot, any Error>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(holds: Bool = false, fails: Bool = false) { self.holds = holds; self.fails = fails }
    func loadSnapshot() async throws -> MessagingSnapshot {
        loads += 1
        if fails { throw CompanionError.server("Test connection failure") }
        if holds {
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                waiters.forEach { $0.resume() }; waiters.removeAll()
            }
        }
        return Fixtures.snapshot
    }
    func waitForLoad() async {
        if pending != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { pending?.resume(returning: Fixtures.snapshot); pending = nil }
    func events() async -> AsyncStream<GatewayEvent> { AsyncStream { $0.finish() } }
    func sendText(_ body: String, to route: ConversationRoute) async throws -> SendReceipt { throw CompanionError.server("Not used") }
    func send(_ attachment: OutgoingAttachment, to route: ConversationRoute) async throws -> SendReceipt { throw CompanionError.server("Not used") }
}
