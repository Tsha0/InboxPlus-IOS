import Foundation
import InboxPlusCore
import InboxPlusFeatures
import InboxPlusGateway
import InboxPlusRemote
import InboxPlusCompanionServer
import InboxPlusBridge
import InboxPlusUI

@main struct CompanionMain {
    @MainActor static func main() async throws {
        guard let token = ProcessInfo.processInfo.environment["INBOXPLUS_PAIRING_KEY"], token.count >= 32 else {
            throw CompanionError.server("Set INBOXPLUS_PAIRING_KEY to a random key of at least 32 characters. See README.md.")
        }
        guard GatewaySelection.resolveProfileName(environment: ProcessInfo.processInfo.environment) != nil else {
            throw CompanionError.server("Select a prepared Mac profile with INBOXPLUS_PROFILE before starting the companion.")
        }
        let services = GatewaySelection.makeServices()
        let endpoint = CompanionEndpoint(gateway: services.gateway, media: services.media)
        try await endpoint.start()
        let server = try CompanionHTTPServer(token: token) { request in await endpoint.handle(request) }
        server.start()
        print("Inbox+ Companion listening at http://127.0.0.1:8765. Expose through a trusted HTTPS proxy for your phone. Pairing key is never logged.")
        while !Task.isCancelled { try await Task.sleep(for: .seconds(60)) }
        server.stop()
    }
}

@MainActor final class CompanionEndpoint {
    let gateway: any MessagingGateway
    let media: MediaController
    var snapshot = MessagingSnapshot.empty
    var disconnectedAccounts: Set<String> = []
    var sessionDates: [String: Date] = [:]
    var eventTask: Task<Void, Never>?
    var sessions: [String: any BridgeLoginSession] = [:]
    init(gateway: any MessagingGateway, media: MediaController) { self.gateway = gateway; self.media = media }
    func start() async throws {
        let stream = await gateway.events()
        snapshot = try await gateway.loadSnapshot()
        eventTask = Task { [weak self] in
            for await event in stream { self?.apply(event) }
        }
    }
    func apply(_ event: GatewayEvent) {
        switch event {
        case .messageUpserted(let message):
            var messages = snapshot.messagesByRoute[message.route, default: []]
            messages.removeAll { $0.id == message.id }; messages.append(message)
            snapshot.messagesByRoute[message.route] = messages.sorted { $0.timestamp < $1.timestamp }
        case .conversationUpserted(let conversation):
            snapshot.conversations.removeAll { $0.route == conversation.route }; snapshot.conversations.append(conversation)
        case .identityUpserted(let identity):
            snapshot.identities.removeAll { $0.id == identity.id }; snapshot.identities.append(identity)
        case .connectionChanged(let id, let connected):
            if connected { disconnectedAccounts.remove(id) } else { disconnectedAccounts.insert(id) }
        }
    }
    func handle(_ request: CompanionRequest) async -> CompanionResponse {
        var response = CompanionResponse()
        do {
            switch request.operation {
            case "snapshot": response.snapshot = snapshot; response.disconnectedAccountIDs = disconnectedAccounts
            case "sendText":
                guard let route = request.route, snapshot.conversations.contains(where: { $0.route == route }), let body = request.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CompanionError.invalidResponse }
                response.receipt = try await gateway.sendText(body, to: route)
            case "sendAttachment":
                guard let route = request.route, let conversation = snapshot.conversations.first(where: { $0.route == route }), let data = request.data, data.count <= 25 * 1024 * 1024,
                      let name = request.filename, name == (name as NSString).lastPathComponent, !name.isEmpty, name != ".", name != ".." else { throw CompanionError.invalidResponse }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: folder) }
                let file = folder.appendingPathComponent(name)
                try data.write(to: file, options: .atomic)
                let attachment = try OutgoingAttachment.describing(fileURL: file)
                try attachment.validate(against: conversation.capabilities)
                response.receipt = try await gateway.send(attachment, to: route)
            case "media":
                guard let handle = request.handle,
                      let message = snapshot.messagesByRoute.values.flatMap({ $0 }).first(where: { $0.attachments.contains { $0.source == handle } }),
                      let attachment = message.attachments.first(where: { $0.source == handle }) else { throw CompanionError.invalidResponse }
                media.load(attachment, accountID: message.route.accountID, messageID: message.id)
                for _ in 0..<200 {
                    switch media.state(for: attachment) {
                    case .ready(let url):
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= 25 * 1024 * 1024 else { throw CompanionError.server("This media is larger than the mobile transfer limit of 25 MB.") }
                        response.data = try Data(contentsOf: url); return response
                    case .failed(let reason), .paused(let reason): throw CompanionError.server(reason)
                    default: try await Task.sleep(for: .milliseconds(250))
                    }
                }
                throw CompanionError.server("Media download timed out. Try again.")
            case "loginPrepare":
                for (id, created) in sessionDates where Date().timeIntervalSince(created) > 900 { sessions[id] = nil; sessionDates[id] = nil }
                guard sessions.count < 8, let platform = request.platform, let provider = BridgeSelection.makeProvider() else { throw CompanionError.server("Account setup is unavailable. Check the Mac profile.") }
                switch try await provider(platform) {
                case .ready(let session):
                    let id = UUID().uuidString
                    response.flows = try await session.loginFlows(); sessions[id] = session; sessionDates[id] = Date(); response.sessionID = id
                case .installedPendingRuntimeRestart(let outcome):
                    throw CompanionError.server(
                        "\(outcome.platform.accessibilityLabel) is installed on your Mac. "
                        + "Restart the Inbox+ runtime on your Mac, then choose this network again on your phone."
                    )
                }
            case "loginStart":
                guard let id = request.sessionID, let session = sessions[id], let flowID = request.body else { throw CompanionError.invalidResponse }
                response.step = try await session.startLogin(flowID: flowID)
            case "loginSubmit":
                guard let id = request.sessionID, let session = sessions[id], let loginID = request.loginID, let stepID = request.stepID, let type = request.stepType else { throw CompanionError.invalidResponse }
                response.step = try await session.submit(loginID: loginID, stepID: stepID, type: type, values: request.values ?? [:])
                if response.step?.type == .complete {
                    sessions[id] = nil; sessionDates[id] = nil
                    snapshot = try await gateway.loadSnapshot()
                }
            case "loginCancel":
                guard let id = request.sessionID, let session = sessions.removeValue(forKey: id), let loginID = request.loginID else { throw CompanionError.invalidResponse }
                sessionDates[id] = nil
                try await session.cancelLogin(loginID: loginID)
            default: throw CompanionError.server("This operation is not supported. Update the Mac companion.")
            }
        } catch { response.error = error.localizedDescription }
        return response
    }
}
