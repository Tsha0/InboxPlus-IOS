import Foundation
import Observation
import InboxPlusCore
import InboxPlusGateway

/// Drives lazy media loading for the transcript.
///
/// Nothing is fetched until a view asks, and a view asks when it appears. That is what keeps
/// opening a conversation with a hundred photos cheap: the cost is paid per attachment actually
/// scrolled into view, not per conversation opened.
@MainActor
@Observable
public final class MediaController {
    public enum State: Equatable {
        case idle
        case loading
        case ready(URL)
        /// The download failed and can be retried.
        case failed(String)
        /// Downloading is off right now — disk pressure — so retrying immediately is pointless.
        case paused(String)
    }

    /// Not a `let`: the loader needs the running homeserver behind it, and the runtime is started
    /// after the window appears. Until it arrives the controller behaves exactly like one that
    /// never had a loader — it shows placeholders rather than pretending to download.
    private var loader: MediaLoader?
    private var states: [String: State] = [:]

    /// Set when the disk is under pressure, so the UI can say so once rather than per attachment.
    public private(set) var storageWarning: String?

    /// A controller with no loader never downloads anything: previews and fixtures show their
    /// placeholder rather than reaching for a network that is not there.
    public init(loader: MediaLoader? = nil) {
        self.loader = loader
    }

    /// Supplies the loader once the runtime it needs is serving.
    ///
    /// Attachments that were asked for while there was nothing to fetch them with are left `idle`,
    /// so the next time their view appears they load rather than staying blank forever.
    public func attach(loader: MediaLoader) {
        self.loader = loader
        states = states.filter { _, state in
            if case .idle = state { return false }
            return true
        }
    }

    public func state(for attachment: MessageAttachment) -> State {
        states[attachment.id] ?? .idle
    }

    /// Starts a download unless one already ran. Safe to call every time a view appears.
    public func load(_ attachment: MessageAttachment, accountID: String, messageID: String) {
        guard attachment.isDownloadable, let loader else { return }
        switch state(for: attachment) {
        case .idle, .failed: break
        case .loading, .ready, .paused: return
        }

        states[attachment.id] = .loading
        Task { [weak self] in
            let context = MediaCacheContext(
                accountID: accountID,
                messageID: messageID,
                deepLink: attachment.deepLink
            )
            do {
                let url = try await loader.file(for: attachment, context: context)
                self?.states[attachment.id] = .ready(url)
            } catch MediaLoadError.pausedForDiskSpace {
                let decision = await loader.storageDecision()
                self?.storageWarning = decision.warning
                self?.states[attachment.id] = .paused(
                    decision.warning ?? "Downloads are paused because your device is low on disk space."
                )
            } catch {
                self?.states[attachment.id] = .failed(error.localizedDescription)
            }
        }
    }

    /// Clears a failure so the next appearance tries again.
    public func retry(_ attachment: MessageAttachment, accountID: String, messageID: String) {
        states[attachment.id] = .idle
        load(attachment, accountID: accountID, messageID: messageID)
    }

    public func refreshStorageWarning() {
        guard let loader else { return }
        Task { [weak self] in
            self?.storageWarning = await loader.storageDecision().warning
        }
    }
}
