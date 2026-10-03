import CryptoKit
import Foundation
import InboxPlusCore
import UniformTypeIdentifiers

/// What the cache remembers about one stored file.
///
/// The design requires cached media to retain its source adapter, remote message identifier,
/// content type, size, and deep link, so that a file on disk can always be explained and, when it
/// is evicted, fetched again from the place it came from.
public struct MediaCacheRecord: Codable, Hashable, Sendable {
    public let key: String
    public let source: String
    public let accountID: String
    public let messageID: String
    public var mimeType: String?
    public var byteCount: Int
    public var deepLink: VerifiedDeepLink?
    public var lastAccess: Date
    /// False when these bytes cannot be fetched again. Cleanup must never remove one of these.
    public var isReproducible: Bool

    public init(
        key: String,
        source: String,
        accountID: String,
        messageID: String,
        mimeType: String? = nil,
        byteCount: Int,
        deepLink: VerifiedDeepLink? = nil,
        lastAccess: Date,
        isReproducible: Bool = true
    ) {
        self.key = key
        self.source = source
        self.accountID = accountID
        self.messageID = messageID
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.deepLink = deepLink
        self.lastAccess = lastAccess
        self.isReproducible = isReproducible
    }
}

/// Where a cached file came from, recorded at the moment it is stored.
public struct MediaCacheContext: Hashable, Sendable {
    public let accountID: String
    public let messageID: String
    public var deepLink: VerifiedDeepLink?
    /// Set false for bytes Inbox+ cannot fetch again — anything composed locally and not yet sent.
    public var isReproducible: Bool

    public init(
        accountID: String,
        messageID: String,
        deepLink: VerifiedDeepLink? = nil,
        isReproducible: Bool = true
    ) {
        self.accountID = accountID
        self.messageID = messageID
        self.deepLink = deepLink
        self.isReproducible = isReproducible
    }
}

public enum MediaCacheError: Error, Equatable {
    case directoryNotUsable(String)
    case notCached(String)
}

/// A bounded, on-disk cache for media that downloads lazily.
///
/// Eviction is least-recently-used and, critically, only ever touches reproducible files. A file
/// that cannot be fetched again is retained even when that leaves the cache over budget, because
/// the design forbids deleting irreplaceable local content without explicit consent — being over
/// budget is a smaller harm than losing something permanently.
public actor MediaCache {
    public static let defaultBudgetBytes = 2 * 1024 * 1024 * 1024

    private let directory: URL
    private let indexURL: URL
    private let fileManager: FileManager
    public let budgetBytes: Int

    private var records: [String: MediaCacheRecord] = [:]

    public init(
        directory: URL,
        budgetBytes: Int = MediaCache.defaultBudgetBytes,
        fileManager: FileManager = .default
    ) throws {
        self.directory = directory
        self.budgetBytes = budgetBytes
        self.fileManager = fileManager
        indexURL = directory.appendingPathComponent("index.json")

        // Media is message content, so the cache is as private as the database beside it.
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MediaCacheError.directoryNotUsable(directory.path)
        }
        records = Self.loadIndex(at: indexURL)
    }

    // MARK: - Reading

    /// The file holding this media, or nil when it has not been downloaded yet.
    ///
    /// Reading marks the entry as recently used, which is what keeps a conversation the user is
    /// actually looking at from being evicted out from under them.
    public func cachedFile(for handle: MediaHandle, now: Date = Date()) -> URL? {
        let key = Self.key(for: handle.source)
        guard var record = records[key] else { return nil }
        let url = fileURL(key: key, mimeType: record.mimeType)
        guard fileManager.fileExists(atPath: url.path) else {
            // The index outlived the file — a deleted cache directory, say. Forget it so the next
            // read downloads instead of reporting a file that is not there.
            records[key] = nil
            try? persistIndex()
            return nil
        }
        record.lastAccess = now
        records[key] = record
        try? persistIndex()
        return url
    }

    public func record(for handle: MediaHandle) -> MediaCacheRecord? {
        records[Self.key(for: handle.source)]
    }

    public var totalBytes: Int {
        records.values.reduce(0) { $0 + $1.byteCount }
    }

    public func allRecords() -> [MediaCacheRecord] {
        Array(records.values)
    }

    // MARK: - Writing

    @discardableResult
    public func store(
        _ data: Data,
        for handle: MediaHandle,
        context: MediaCacheContext,
        now: Date = Date()
    ) throws -> URL {
        let key = Self.key(for: handle.source)
        let mimeType = handle.mimeType
        let url = fileURL(key: key, mimeType: mimeType)
        // Written user-only, like every other secret-adjacent file the runtime produces.
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        records[key] = MediaCacheRecord(
            key: key,
            source: handle.source,
            accountID: context.accountID,
            messageID: context.messageID,
            mimeType: mimeType,
            byteCount: data.count,
            deepLink: context.deepLink,
            lastAccess: now,
            isReproducible: context.isReproducible
        )
        try persistIndex()
        return url
    }

    // MARK: - Cleanup

    /// Evicts least-recently-used reproducible files until the cache fits its budget.
    ///
    /// Returns the keys removed, so a caller can say what happened rather than silently shrinking.
    @discardableResult
    public func evictToFitBudget() throws -> [String] {
        var total = totalBytes
        guard total > budgetBytes else { return [] }

        let candidates = records.values
            .filter(\.isReproducible)
            .sorted { $0.lastAccess < $1.lastAccess }

        var evicted: [String] = []
        for record in candidates where total > budgetBytes {
            try? fileManager.removeItem(at: fileURL(key: record.key, mimeType: record.mimeType))
            records[record.key] = nil
            total -= record.byteCount
            evicted.append(record.key)
        }
        if !evicted.isEmpty { try persistIndex() }
        return evicted
    }

    /// Removes every cached file for one account, used when an account is erased.
    @discardableResult
    public func purge(accountID: String) throws -> [String] {
        let doomed = records.values.filter { $0.accountID == accountID }
        for record in doomed {
            try? fileManager.removeItem(at: fileURL(key: record.key, mimeType: record.mimeType))
            records[record.key] = nil
        }
        if !doomed.isEmpty { try persistIndex() }
        return doomed.map(\.key)
    }

    // MARK: - Storage

    /// A cache filename is derived from the media's own identifier, so the same media is never
    /// stored twice and a remote name can never steer the write anywhere.
    static func key(for source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The extension matters: AVFoundation and NSImage both do a better job when the file name
    /// admits what it holds.
    static func pathExtension(forMimeType mimeType: String?) -> String? {
        guard let mimeType, let type = UTType(mimeType: mimeType) else { return nil }
        return type.preferredFilenameExtension
    }

    private func fileURL(key: String, mimeType: String?) -> URL {
        guard let ext = Self.pathExtension(forMimeType: mimeType) else {
            return directory.appendingPathComponent(key)
        }
        return directory.appendingPathComponent(key).appendingPathExtension(ext)
    }

    private func persistIndex() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(records).write(to: indexURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }

    /// A corrupt or unreadable index costs the user a re-download, never a crash on launch.
    private static func loadIndex(at url: URL) -> [String: MediaCacheRecord] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: MediaCacheRecord].self, from: data)) ?? [:]
    }
}
