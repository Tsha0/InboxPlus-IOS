import Foundation
import Observation
import InboxPlusCore
import InboxPlusGateway

public enum DetailSelection: Equatable, Sendable {
    case empty
    case personSummary(String)
    case conversation(ConversationRoute)
}

public enum ServiceHealth: Equatable, Sendable {
    case starting
    case healthy
    case needsAttention(String)
}

public extension ServiceHealth {
    var menuBarTitle: String {
        switch self {
        case .starting: "Inbox+ is starting"
        case .healthy: "Inbox+ is running"
        case .needsAttention: "Inbox+ needs attention"
        }
    }

    var symbolName: String {
        switch self {
        case .starting: "ellipsis.circle"
        case .healthy: "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        }
    }
}

public enum InboxPlusAppModelError: Error, Equatable {
    case missingOpenConversation
}

public struct DraftSubmission: Sendable {
    public let body: String
    public let route: ConversationRoute
    fileprivate let draftRevision: UInt64
    fileprivate let routeGeneration: UInt64

    fileprivate init(
        body: String,
        route: ConversationRoute,
        draftRevision: UInt64,
        routeGeneration: UInt64
    ) {
        self.body = body
        self.route = route
        self.draftRevision = draftRevision
        self.routeGeneration = routeGeneration
    }
}

private final class StartupWaiterCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private struct StartupWaiter {
    let startupID: UUID
    let cancellation: StartupWaiterCancellation
    let continuation: CheckedContinuation<Void, any Error>
}

@MainActor
@Observable
public final class InboxPlusAppModel {
    public private(set) var accounts: [ConnectedAccount] = []
    public private(set) var identities: [RemoteIdentity] = []
    public private(set) var conversations: [RemoteConversation] = []
    public private(set) var messagesByRoute: [ConversationRoute: [Message]] = [:]
    public private(set) var inboxItems: [InboxItem] = []
    public private(set) var detailSelection: DetailSelection = .empty
    public private(set) var health: ServiceHealth = .starting
    public var draft = "" {
        didSet { draftRevision &+= 1 }
    }

    public var openRoute: ConversationRoute? {
        guard case let .conversation(route) = detailSelection else { return nil }
        return route
    }

    public var healthBannerMessage: String? {
        guard case let .needsAttention(message) = health else { return nil }
        return message
    }

    /// A network the user asked to connect from the menu bar. The main window consumes this —
    /// the login sheet has to present from a window, and the menu bar owns no window of its own.
    public private(set) var pendingConnectionRequest: Platform?

    public func requestConnection(to platform: Platform) {
        pendingConnectionRequest = platform
    }

    public func clearConnectionRequest() {
        pendingConnectionRequest = nil
    }

    private let gateway: any MessagingGateway
    public var contactDirectory: ContactDirectory { directory }
    private var directory: ContactDirectory
    private var draftRevision: UInt64 = 0
    private var disconnectedAccountIDs: Set<String> = []
    private var sendFailuresByRoute: [ConversationRoute: String] = [:]
    private var latestSendGenerationByRoute: [ConversationRoute: UInt64] = [:]
    private var startupID: UUID?
    private var startupTask: Task<Void, Never>?
    private var startupWaiters: [UUID: StartupWaiter] = [:]
    private var eventTask: Task<Void, Never>?
    private var eventTaskID: UUID?
    private var bufferingEventTaskID: UUID?
    private var bufferedStartupEvents: [GatewayEvent] = []

    /// Lazy media loading for the transcript. Without a loader it simply never downloads, which is
    /// what previews and fixture runs want.
    public let media: MediaController

    public init(
        gateway: any MessagingGateway,
        directory: ContactDirectory = .init(),
        media: MediaController = MediaController()
    ) {
        self.gateway = gateway
        self.directory = directory
        self.media = media
    }

    public func start() async throws {
        if eventTask != nil, startupTask == nil {
            return
        }
        let id = startupID ?? beginStartup()
        try await waitForStartup(id: id)
    }

    public func stop() {
        let id = startupID
        startupID = nil
        startupTask?.cancel()
        startupTask = nil
        if let id {
            cancelStartup(id: id)
        }
        resumeStartupWaiters(throwing: CancellationError(), respectingCallerCancellation: false)
        if id == nil {
            eventTask?.cancel()
            eventTask = nil
            eventTaskID = nil
        }
    }

    public func reportStartupFailure(_ error: any Error) {
        health = .needsAttention("Inbox+ could not start: \(error.localizedDescription)")
    }

    isolated deinit {
        startupTask?.cancel()
        eventTask?.cancel()
    }

    public func selectInboxItem(_ item: InboxItem) {
        switch item.id {
        case let .person(id):
            detailSelection = .personSummary(id)
        case let .conversation(route):
            openConversation(route)
        }
    }

    public func selectPerson(_ personID: String) {
        detailSelection = .personSummary(personID)
    }

    public func openConversation(_ route: ConversationRoute) {
        detailSelection = .conversation(route)
        markConversationRead(route)
    }

    public func markConversationRead(_ route: ConversationRoute) {
        guard
            let index = conversations.firstIndex(where: { $0.route == route }),
            conversations[index].unreadCount != 0
        else { return }
        conversations[index].unreadCount = 0
        rebuildInbox()
    }

    /// Names each loaded account and how many conversations it owns.
    ///
    /// A conversation attributed to the wrong network is invisible as a bug — a bridged Instagram
    /// chat simply reads "Matrix" and looks like a design choice. Stating it once at load makes it
    /// checkable without a screenshot.
    private static func reportLoadedAccounts(_ snapshot: MessagingSnapshot) {
        guard !snapshot.accounts.isEmpty else { return }
        let counts = snapshot.conversations.reduce(into: [String: Int]()) { totals, conversation in
            totals[conversation.accountID, default: 0] += 1
        }
        let described = snapshot.accounts
            .map { "\($0.platform.rawValue)(\($0.id))=\(counts[$0.id] ?? 0)" }
            .sorted()
            .joined(separator: " ")
        FileHandle.standardError.write(Data("Inbox+: conversations by account — \(described)\n".utf8))
    }

    public func isConnected(_ accountID: String) -> Bool {
        !disconnectedAccountIDs.contains(accountID)
    }

    // MARK: - Accounts

    /// When each account last produced traffic, so "connected" can be distinguished from "silent".
    public private(set) var lastActivityByAccount: [String: Date] = [:]

    public func lastActivity(for accountID: String) -> Date? {
        lastActivityByAccount[accountID]
    }

    public var platformsWithAccounts: Set<Platform> {
        Set(accounts.map(\.platform))
    }

    /// Records a newly connected account.
    ///
    /// The one-account-per-platform rule is enforced here as well as in the picker: the picker
    /// disables an already-connected network, but a view is a convenience, not the rule.
    public func addAccount(_ account: ConnectedAccount) throws {
        try AccountPolicy.validate(accounts + [account])
        accounts.append(account)
        disconnectedAccountIDs.remove(account.id)
        rebuildInbox()
    }

    /// Marks an account disconnected without touching anything it delivered.
    ///
    /// History stays: a disconnected account is a connection problem, and deleting someone's
    /// messages is never the right response to one.
    public func disconnect(accountID: String) {
        guard accounts.contains(where: { $0.id == accountID }) else { return }
        disconnectedAccountIDs.insert(accountID)
        health = .needsAttention("\(disconnectedAccountIDs.count) account(s) disconnected")
    }

    public func reconnect(accountID: String) {
        disconnectedAccountIDs.remove(accountID)
        if disconnectedAccountIDs.isEmpty { health = .healthy }
    }

    /// Removes an account and everything it brought with it.
    ///
    /// Separate from `disconnect` and destructive on purpose — the caller must have confirmed with
    /// the user, because nothing here can be undone.
    public func eraseAccount(accountID: String) {
        accounts.removeAll { $0.id == accountID }
        let removedIdentityIDs = Set(
            identities.filter { $0.accountID == accountID }.map(\.id)
        )
        identities.removeAll { $0.accountID == accountID }
        for route in messagesByRoute.keys where route.accountID == accountID {
            messagesByRoute[route] = nil
        }
        conversations.removeAll { $0.accountID == accountID }
        for identityID in removedIdentityIDs {
            guard let personID = directory.personID(linkedTo: identityID) else { continue }
            try? directory.unlink(remoteIdentityID: identityID, from: personID)
        }
        disconnectedAccountIDs.remove(accountID)
        lastActivityByAccount[accountID] = nil
        if openRoute?.accountID == accountID { detailSelection = .empty }
        if disconnectedAccountIDs.isEmpty, case .needsAttention = health { health = .healthy }
        rebuildInbox()
    }

    public func captureDraft(to route: ConversationRoute) -> DraftSubmission {
        let previousGeneration = latestSendGenerationByRoute[route, default: 0]
        precondition(previousGeneration < UInt64.max, "Send generation exhausted")
        let generation = previousGeneration + 1
        latestSendGenerationByRoute[route] = generation
        return DraftSubmission(
            body: draft,
            route: route,
            draftRevision: draftRevision,
            routeGeneration: generation
        )
    }

    public func sendDraft(_ submission: DraftSubmission) async throws {
        let body = submission.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        _ = try await gateway.sendText(body, to: submission.route)
        guard isLatest(submission) else { return }
        sendFailuresByRoute[submission.route] = nil
        if draftRevision == submission.draftRevision {
            draft = ""
        }
    }

    // MARK: - Attachment composition

    /// Files staged for the open conversation, kept per route so switching conversations does not
    /// carry someone's photo into a different chat.
    public private(set) var stagedAttachmentsByRoute: [ConversationRoute: [OutgoingAttachment]] = [:]

    public func stagedAttachments(for route: ConversationRoute) -> [OutgoingAttachment] {
        stagedAttachmentsByRoute[route] ?? []
    }

    public func capabilities(for route: ConversationRoute) -> ConversationCapabilities {
        conversations.first { $0.route == route }?.capabilities ?? .textOnly
    }

    /// Stages a chosen file, rejecting it now rather than failing the send later.
    @discardableResult
    public func stageAttachment(at fileURL: URL, for route: ConversationRoute) -> AttachmentRejection? {
        do {
            let attachment = try OutgoingAttachment.describing(fileURL: fileURL)
            try attachment.validate(against: capabilities(for: route))
            stagedAttachmentsByRoute[route, default: []].append(attachment)
            sendFailuresByRoute[route] = nil
            return nil
        } catch let rejection as AttachmentRejection {
            sendFailuresByRoute[route] = rejection.message
            return rejection
        } catch {
            let rejection = AttachmentRejection.unreadable(error.localizedDescription)
            sendFailuresByRoute[route] = rejection.message
            return rejection
        }
    }

    public func removeStagedAttachment(_ attachment: OutgoingAttachment, for route: ConversationRoute) {
        stagedAttachmentsByRoute[route]?.removeAll { $0 == attachment }
        if stagedAttachmentsByRoute[route]?.isEmpty == true {
            stagedAttachmentsByRoute[route] = nil
        }
    }

    /// Sends everything staged for a route, then the text, in that order.
    ///
    /// A file that fails to send stays staged: dropping it would lose the user's choice with
    /// nothing to show for it.
    public func sendStagedAttachments(to route: ConversationRoute) async throws {
        for attachment in stagedAttachments(for: route) {
            _ = try await gateway.send(attachment, to: route)
            removeStagedAttachment(attachment, for: route)
        }
    }

    public func reportSendFailure(_ error: any Error, for submission: DraftSubmission) {
        guard isLatest(submission) else { return }
        sendFailuresByRoute[submission.route] = error.localizedDescription
    }

    public func sendFailure(for route: ConversationRoute) -> String? {
        sendFailuresByRoute[route]
    }

    private func isLatest(_ submission: DraftSubmission) -> Bool {
        latestSendGenerationByRoute[submission.route] == submission.routeGeneration
    }

    public func summaries(for personID: String) -> [ConversationSummary] {
        inboxItems.first { $0.id == .person(personID) }?.conversationSummaries ?? []
    }

    public var people: [InboxPlusPerson] {
        directory.people.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    public func personID(for route: ConversationRoute) -> String? {
        guard let identityID = conversations.first(where: { $0.route == route })?.identityID else { return nil }
        return directory.personID(linkedTo: identityID)
    }

    public func linkOpenConversation(to personID: String) throws {
        guard
            let route = openRoute,
            let identityID = conversations.first(where: { $0.route == route })?.identityID
        else { throw InboxPlusAppModelError.missingOpenConversation }
        try directory.link(remoteIdentityID: identityID, to: personID)
        rebuildInbox()
        detailSelection = .personSummary(personID)
    }

    @discardableResult
    public func createPersonAndLinkOpenConversation(displayName: String) throws -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ContactDirectoryError.missingPerson }
        let personID = UUID().uuidString
        try directory.createPerson(id: personID, displayName: trimmed)
        do {
            try linkOpenConversation(to: personID)
        } catch {
            directory.removePerson(id: personID)
            throw error
        }
        return personID
    }

    private func apply(_ snapshot: MessagingSnapshot) {
        Self.reportLoadedAccounts(snapshot)
        accounts = snapshot.accounts
        identities = snapshot.identities
        conversations = snapshot.conversations
        messagesByRoute = snapshot.messagesByRoute.mapValues { $0.sorted { $0.timestamp < $1.timestamp } }
        lastActivityByAccount = Dictionary(
            snapshot.conversations.map { ($0.accountID, $0.latestActivity) },
            uniquingKeysWith: max
        )
        rebuildInbox()
    }

    private func performStart(id: UUID) async throws {
        let stream = await gateway.events()
        try Task.checkCancellation()
        guard startupID == id else { throw CancellationError() }

        let subscriptionTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                self?.receive(event, from: id)
            }
        }
        eventTask = subscriptionTask
        eventTaskID = id

        let snapshot = try await gateway.loadSnapshot()
        try Task.checkCancellation()
        guard startupID == id else { throw CancellationError() }
        try AccountPolicy.validate(snapshot.accounts)
        apply(snapshot)
        disconnectedAccountIDs.removeAll()
        health = .healthy

        let events = bufferedStartupEvents
        bufferedStartupEvents.removeAll()
        for event in events {
            apply(event)
        }
        bufferingEventTaskID = nil
    }

    private func beginStartup() -> UUID {
        let id = UUID()
        startupID = id
        bufferingEventTaskID = id
        bufferedStartupEvents.removeAll()
        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.performStart(id: id)
                self.finishStartup(id: id)
            } catch {
                self.finishStartup(id: id, throwing: error)
            }
        }
        return id
    }

    private func waitForStartup(id: UUID) async throws {
        let waiterID = UUID()
        let cancellation = StartupWaiterCancellation()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if cancellation.isCancelled() || Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if startupID == id {
                    startupWaiters[waiterID] = StartupWaiter(
                        startupID: id,
                        cancellation: cancellation,
                        continuation: continuation
                    )
                } else if eventTask != nil {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor [weak self] in
                self?.cancelStartupWaiter(waiterID, startupID: id)
            }
        }
    }

    private func finishStartup(id: UUID, throwing error: (any Error)? = nil) {
        guard startupID == id else { return }
        if error != nil {
            cancelStartup(id: id)
        }
        startupID = nil
        startupTask = nil
        resumeStartupWaiters(throwing: error, respectingCallerCancellation: true)
    }

    private func receive(_ event: GatewayEvent, from id: UUID) {
        guard eventTaskID == id else { return }
        if bufferingEventTaskID == id {
            bufferedStartupEvents.append(event)
        } else {
            apply(event)
        }
    }

    private func cancelStartup(id: UUID) {
        if eventTaskID == id {
            eventTask?.cancel()
            eventTask = nil
            eventTaskID = nil
        }
        if bufferingEventTaskID == id {
            bufferingEventTaskID = nil
            bufferedStartupEvents.removeAll()
        }
    }

    private func cancelStartupWaiter(_ waiterID: UUID, startupID: UUID) {
        guard
            let waiter = startupWaiters[waiterID],
            waiter.startupID == startupID
        else { return }
        startupWaiters[waiterID] = nil
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resumeStartupWaiters(
        throwing error: (any Error)? = nil,
        respectingCallerCancellation: Bool
    ) {
        let waiters = Array(startupWaiters.values)
        startupWaiters.removeAll()
        for waiter in waiters {
            if respectingCallerCancellation, waiter.cancellation.isCancelled() {
                waiter.continuation.resume(throwing: CancellationError())
            } else if let error {
                waiter.continuation.resume(throwing: error)
            } else {
                waiter.continuation.resume()
            }
        }
    }

    private func apply(_ event: GatewayEvent) {
        switch event {
        case let .messageUpserted(message):
            var messages = messagesByRoute[message.route, default: []]
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = message
            } else {
                let insertion = messages.firstIndex { $0.timestamp > message.timestamp }
                messages.insert(message, at: insertion ?? messages.endIndex)
            }
            messagesByRoute[message.route] = messages
            let accountID = message.route.accountID
            if message.timestamp > lastActivityByAccount[accountID] ?? .distantPast {
                lastActivityByAccount[accountID] = message.timestamp
            }
            if
                let conversationIndex = conversations.firstIndex(where: { $0.route == message.route }),
                message.timestamp > conversations[conversationIndex].latestActivity
            {
                conversations[conversationIndex].latestPreview = message.body
                conversations[conversationIndex].latestActivity = message.timestamp
                rebuildInbox()
            }
        case let .identityUpserted(identity):
            if let index = identities.firstIndex(where: { $0.id == identity.id }) {
                identities[index] = identity
            } else {
                identities.append(identity)
            }
            rebuildInbox()
        case let .conversationUpserted(conversation):
            conversations.removeAll { $0.id == conversation.id && $0.accountID == conversation.accountID }
            conversations.append(conversation)
            rebuildInbox()
        case let .connectionChanged(accountID, isConnected):
            guard accounts.contains(where: { $0.id == accountID }) else { return }
            if isConnected {
                disconnectedAccountIDs.remove(accountID)
            } else {
                disconnectedAccountIDs.insert(accountID)
            }
            health = disconnectedAccountIDs.isEmpty
                ? .healthy
                : .needsAttention("\(disconnectedAccountIDs.count) account(s) disconnected")
        }
    }

    private func rebuildInbox() {
        inboxItems = InboxProjector.project(
            accounts: accounts,
            identities: identities,
            conversations: conversations,
            directory: directory
        )
    }
}
