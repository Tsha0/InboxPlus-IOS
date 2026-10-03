import Foundation
import InboxPlusCore

/// Fetches the bytes behind a handle. Implemented over the Matrix SDK; faked in tests.
public protocol RemoteMediaFetching: Sendable {
    func fetch(_ handle: MediaHandle) async throws -> Data
}

/// Reports free space on the volume holding the cache.
public protocol FreeSpaceReporting: Sendable {
    func freeBytes() -> Int?
}

public struct VolumeFreeSpaceReporter: FreeSpaceReporting {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func freeBytes() -> Int? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        return capacity > Int64(Int.max) ? Int.max : Int(capacity)
    }
}

public struct MediaStorageDecision: Equatable, Sendable {
    /// Media downloads are optional work: they are the first thing to stop when disk runs low.
    public let allowsDownloads: Bool
    /// Non-nil when the user should be told. A silent stop looks like a broken app.
    public let warning: String?

    public init(allowsDownloads: Bool, warning: String?) {
        self.allowsDownloads = allowsDownloads
        self.warning = warning
    }
}

/// Decides what to do about disk pressure.
///
/// The design is explicit: stop optional media downloads first and warn, and never automatically
/// delete messages. Nothing here deletes anything — the worst it does is decline to add more.
public struct MediaStoragePolicy: Sendable {
    public let pauseBelowFreeBytes: Int
    public let warnBelowFreeBytes: Int

    public init(
        pauseBelowFreeBytes: Int = 2 * 1024 * 1024 * 1024,
        warnBelowFreeBytes: Int = 5 * 1024 * 1024 * 1024
    ) {
        self.pauseBelowFreeBytes = pauseBelowFreeBytes
        self.warnBelowFreeBytes = warnBelowFreeBytes
    }

    public func decide(freeBytes: Int?) -> MediaStorageDecision {
        // An unreadable volume is not evidence of pressure; refusing downloads because a query
        // failed would break media on a working Mac.
        guard let freeBytes else { return MediaStorageDecision(allowsDownloads: true, warning: nil) }

        if freeBytes < pauseBelowFreeBytes {
            return MediaStorageDecision(
                allowsDownloads: false,
                warning: "Your device is low on disk space, so Inbox+ has paused downloading media. "
                    + "Your messages are safe and nothing has been deleted."
            )
        }
        if freeBytes < warnBelowFreeBytes {
            return MediaStorageDecision(
                allowsDownloads: true,
                warning: "Your device is running low on disk space."
            )
        }
        return MediaStorageDecision(allowsDownloads: true, warning: nil)
    }
}

public enum MediaLoadError: Error, Equatable {
    case pausedForDiskSpace
    case nothingToDownload
}

/// Downloads media on demand and keeps it in a bounded cache.
///
/// Nothing here runs until something on screen asks for a specific attachment, which is what makes
/// the download lazy: a conversation with a hundred photos costs nothing to open.
public actor MediaLoader {
    private let cache: MediaCache
    private let fetcher: any RemoteMediaFetching
    private let freeSpace: any FreeSpaceReporting
    private let policy: MediaStoragePolicy

    /// One in-flight download per handle, so a view appearing twice does not fetch twice.
    private var inFlight: [String: Task<URL, any Error>] = [:]

    public init(
        cache: MediaCache,
        fetcher: any RemoteMediaFetching,
        freeSpace: any FreeSpaceReporting,
        policy: MediaStoragePolicy = MediaStoragePolicy()
    ) {
        self.cache = cache
        self.fetcher = fetcher
        self.freeSpace = freeSpace
        self.policy = policy
    }

    public func storageDecision() -> MediaStorageDecision {
        policy.decide(freeBytes: freeSpace.freeBytes())
    }

    /// The local file for an attachment, downloading it if this is the first time it is needed.
    public func file(for attachment: MessageAttachment, context: MediaCacheContext) async throws -> URL {
        guard let handle = attachment.source else { throw MediaLoadError.nothingToDownload }
        return try await file(for: handle, context: context)
    }

    public func file(for handle: MediaHandle, context: MediaCacheContext) async throws -> URL {
        if let cached = await cache.cachedFile(for: handle) { return cached }
        if let existing = inFlight[handle.source] { return try await existing.value }

        // Checked only on the path that would actually write bytes, so cached media keeps working
        // when the disk is full.
        guard storageDecision().allowsDownloads else { throw MediaLoadError.pausedForDiskSpace }

        let task = Task<URL, any Error> { [cache, fetcher] in
            let data = try await fetcher.fetch(handle)
            let url = try await cache.store(data, for: handle, context: context)
            _ = try? await cache.evictToFitBudget()
            return url
        }
        inFlight[handle.source] = task
        defer { inFlight[handle.source] = nil }
        return try await task.value
    }
}
