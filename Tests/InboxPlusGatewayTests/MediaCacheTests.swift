import Foundation
import Testing
import InboxPlusCore
@testable import InboxPlusGateway

private func makeCacheDirectory() -> URL {
    // Matches the runtime tests: `/var`-rooted temporary directories are symlinked, which several
    // path checks in this project reject.
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/MediaCacheTests-\(UUID().uuidString)")
}

private func handle(_ source: String, mimeType: String? = nil, bytes: Int? = nil) -> MediaHandle {
    MediaHandle(source: source, mimeType: mimeType, byteCount: bytes)
}

private let context = MediaCacheContext(accountID: "instagram", messageID: "$event1")

@Test func mediaIsAbsentUntilItIsDownloaded() async throws {
    let directory = makeCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try MediaCache(directory: directory)

    #expect(await cache.cachedFile(for: handle("mxc://s/1")) == nil)
    #expect(await cache.totalBytes == 0)
}

@Test func aStoredFileIsPrivateAndFindableAgain() async throws {
    let directory = makeCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try MediaCache(directory: directory)

    let stored = try await cache.store(Data(repeating: 7, count: 128), for: handle("mxc://s/1", mimeType: "image/jpeg"), context: context)
    #expect(try Data(contentsOf: stored).count == 128)

    let attributes = try FileManager.default.attributesOfItem(atPath: stored.path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect(directoryAttributes[.posixPermissions] as? Int == 0o700)

    #expect(await cache.cachedFile(for: handle("mxc://s/1", mimeType: "image/jpeg")) == stored)
    #expect(await cache.totalBytes == 128)
}

@Test func aCachedFileRemembersWhereItCameFrom() async throws {
    let directory = makeCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try MediaCache(directory: directory)

    let link = try DeepLinkVerifier.verify("https://instagram.com/reel/1", for: .instagram)
    try await cache.store(
        Data(repeating: 1, count: 10),
        for: handle("mxc://s/1", mimeType: "video/mp4"),
        context: MediaCacheContext(accountID: "instagram", messageID: "$abc", deepLink: link)
    )

    // The design requires all five of these to survive alongside the bytes.
    let record = try #require(await cache.record(for: handle("mxc://s/1")))
    #expect(record.accountID == "instagram")
    #expect(record.messageID == "$abc")
    #expect(record.mimeType == "video/mp4")
    #expect(record.byteCount == 10)
    #expect(record.deepLink == link)
}

@Test func theCacheSurvivesBeingReopened() async throws {
    let directory = makeCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = try MediaCache(directory: directory)
    try await first.store(Data(repeating: 3, count: 64), for: handle("mxc://s/1"), context: context)

    let second = try MediaCache(directory: directory)
    #expect(await second.cachedFile(for: handle("mxc://s/1")) != nil)
    #expect(await second.totalBytes == 64)
}

@Test func anIndexEntryWhoseFileVanishedIsForgottenRatherThanReported() async throws {
    let directory = makeCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try MediaCache(directory: directory)

    let stored = try await cache.store(Data(repeating: 3, count: 64), for: handle("mxc://s/1"), context: context)
    try FileManager.default.removeItem(at: stored)

    // Reporting a file that is not there would show an empty image forever.
    #expect(await cache.cachedFile(for: handle("mxc://s/1")) == nil)
    #expect(await cache.record(for: handle("mxc://s/1")) == nil)
}

@Test func evictionRemovesTheLeastRecentlyUsedFirstAndOnlyUntilItFits() async throws {
    let directory = makeCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try MediaCache(directory: directory, budgetBytes: 250)

    let old = Date(timeIntervalSince1970: 1_000)
    try await cache.store(Data(repeating: 1, count: 100), for: handle("mxc://s/oldest"), context: context, now: old)
    try await cache.store(Data(repeating: 2, count: 100), for: handle("mxc://s/middle"), context: context, now: old.addingTimeInterval(60))
    try await cache.store(Data(repeating: 3, count: 100), for: handle("mxc://s/newest"), context: context, now: old.addingTimeInterval(120))

    let evicted = try await cache.evictToFitBudget()
    #expect(evicted == [MediaCache.key(for: "mxc://s/oldest")])
    #expect(await cache.totalBytes == 200)
    #expect(await cache.cachedFile(for: handle("mxc://s/newest")) != nil)
}

@Test func evictionNeverRemovesSomethingThatCannotBeFetchedAgain() async throws {
    let directory = makeCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try MediaCache(directory: directory, budgetBytes: 50)

    // A photo the user attached but has not sent yet exists nowhere else. Staying over budget is a
    // smaller harm than destroying it.
    try await cache.store(
        Data(repeating: 9, count: 400),
        for: handle("file://outgoing/1"),
        context: MediaCacheContext(accountID: "instagram", messageID: "draft", isReproducible: false)
    )

    #expect(try await cache.evictToFitBudget().isEmpty)
    #expect(await cache.totalBytes == 400)
    #expect(await cache.cachedFile(for: handle("file://outgoing/1")) != nil)
}

@Test func erasingAnAccountTakesOnlyItsOwnMedia() async throws {
    let directory = makeCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try MediaCache(directory: directory)

    try await cache.store(Data(repeating: 1, count: 10), for: handle("mxc://s/ig"), context: MediaCacheContext(accountID: "instagram", messageID: "$1"))
    try await cache.store(Data(repeating: 2, count: 10), for: handle("mxc://s/wa"), context: MediaCacheContext(accountID: "whatsapp", messageID: "$2"))

    #expect(try await cache.purge(accountID: "instagram").count == 1)
    #expect(await cache.cachedFile(for: handle("mxc://s/ig")) == nil)
    #expect(await cache.cachedFile(for: handle("mxc://s/wa")) != nil)
}

@Test func aFilenameIsDerivedFromTheMediaIdentifierNotFromAnythingRemoteChose() {
    // A remote filename must never steer a write. Same source, same key; different source,
    // different key; and the key is safe to use as a path component.
    let key = MediaCache.key(for: "mxc://inboxplus.localhost/../../etc/passwd")
    #expect(key == MediaCache.key(for: "mxc://inboxplus.localhost/../../etc/passwd"))
    #expect(key != MediaCache.key(for: "mxc://inboxplus.localhost/other"))
    #expect(key.count == 64)
    #expect(!key.contains("/"))
    #expect(!key.contains("."))
}

@Test func theStoredExtensionFollowsTheContentTypeWhenOneIsKnown() {
    #expect(MediaCache.pathExtension(forMimeType: "image/jpeg") == "jpeg")
    #expect(MediaCache.pathExtension(forMimeType: "video/mp4") == "mp4")
    #expect(MediaCache.pathExtension(forMimeType: nil) == nil)
    #expect(MediaCache.pathExtension(forMimeType: "not/a-real-type") == nil)
}
