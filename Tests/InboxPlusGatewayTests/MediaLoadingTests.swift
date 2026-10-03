import Foundation
import Testing
import InboxPlusCore
@testable import InboxPlusGateway

private let gibibyte = 1024 * 1024 * 1024

@Test func aHealthyDiskDownloadsWithoutComment() {
    let decision = MediaStoragePolicy().decide(freeBytes: 100 * gibibyte)
    #expect(decision.allowsDownloads)
    #expect(decision.warning == nil)
}

@Test func aFillingDiskWarnsBeforeItStopsAnything() {
    let decision = MediaStoragePolicy().decide(freeBytes: 3 * gibibyte)
    #expect(decision.allowsDownloads)
    #expect(decision.warning != nil)
}

@Test func aFullDiskStopsDownloadsAndSaysNothingWasDeleted() {
    // The design allows stopping optional downloads; it forbids deleting messages. The warning has
    // to say so, or a user under disk pressure will assume Inbox+ threw their history away.
    let decision = MediaStoragePolicy().decide(freeBytes: 512 * 1024 * 1024)
    #expect(!decision.allowsDownloads)
    #expect(decision.warning?.contains("nothing has been deleted") == true)
}

@Test func anUnreadableVolumeIsNotTreatedAsPressure() {
    let decision = MediaStoragePolicy().decide(freeBytes: nil)
    #expect(decision.allowsDownloads)
    #expect(decision.warning == nil)
}

// MARK: - Loader

private actor CountingFetcher: RemoteMediaFetching {
    private(set) var fetches: [String] = []
    private let payload: Data
    private let delay: Duration

    init(payload: Data = Data(repeating: 5, count: 32), delay: Duration = .zero) {
        self.payload = payload
        self.delay = delay
    }

    func fetch(_ handle: MediaHandle) async throws -> Data {
        fetches.append(handle.source)
        if delay != .zero { try? await Task.sleep(for: delay) }
        return payload
    }

    func count() -> Int { fetches.count }
}

private struct FixedFreeSpace: FreeSpaceReporting {
    let bytes: Int?
    func freeBytes() -> Int? { bytes }
}

private func makeLoader(
    freeBytes: Int? = 100 * gibibyte,
    fetcher: CountingFetcher = CountingFetcher()
) throws -> (MediaLoader, CountingFetcher, URL) {
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/MediaLoaderTests-\(UUID().uuidString)")
    let cache = try MediaCache(directory: directory)
    let loader = MediaLoader(cache: cache, fetcher: fetcher, freeSpace: FixedFreeSpace(bytes: freeBytes))
    return (loader, fetcher, directory)
}

private let context = MediaCacheContext(accountID: "instagram", messageID: "$1")

@Test func mediaIsFetchedOnceAndServedFromDiskAfterwards() async throws {
    let (loader, fetcher, directory) = try makeLoader()
    defer { try? FileManager.default.removeItem(at: directory) }
    let handle = MediaHandle(source: "mxc://s/1", mimeType: "image/png")

    let first = try await loader.file(for: handle, context: context)
    let second = try await loader.file(for: handle, context: context)

    #expect(first == second)
    #expect(await fetcher.count() == 1)
}

@Test func twoViewsAskingAtOnceShareOneDownload() async throws {
    // A transcript can put the same image on screen twice; fetching it twice wastes bandwidth and
    // races two writers onto one path.
    let (loader, fetcher, directory) = try makeLoader(fetcher: CountingFetcher(delay: .milliseconds(80)))
    defer { try? FileManager.default.removeItem(at: directory) }
    let handle = MediaHandle(source: "mxc://s/1")

    async let a = loader.file(for: handle, context: context)
    async let b = loader.file(for: handle, context: context)
    _ = try await (a, b)

    #expect(await fetcher.count() == 1)
}

@Test func nothingIsFetchedForAnAttachmentThatHasNoBytes() async throws {
    let (loader, fetcher, directory) = try makeLoader()
    defer { try? FileManager.default.removeItem(at: directory) }

    await #expect(throws: MediaLoadError.nothingToDownload) {
        try await loader.file(for: MessageAttachment(id: "1", kind: .appNative), context: context)
    }
    #expect(await fetcher.count() == 0)
}

@Test func aFullDiskStopsNewDownloadsButNotCachedOnes() async throws {
    let (loader, _, directory) = try makeLoader(freeBytes: 100 * gibibyte)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cached = MediaHandle(source: "mxc://s/cached")
    let downloaded = try await loader.file(for: cached, context: context)

    // Same cache, now on a full volume.
    let squeezed = MediaLoader(
        cache: try MediaCache(directory: directory),
        fetcher: CountingFetcher(),
        freeSpace: FixedFreeSpace(bytes: 100 * 1024 * 1024)
    )
    #expect(try await squeezed.file(for: cached, context: context) == downloaded)
    await #expect(throws: MediaLoadError.pausedForDiskSpace) {
        try await squeezed.file(for: MediaHandle(source: "mxc://s/new"), context: context)
    }
}
