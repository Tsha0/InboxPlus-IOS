import Foundation
import Testing
import InboxPlusCore
import InboxPlusGateway
@testable import InboxPlusFeatures

private struct StubFetcher: RemoteMediaFetching {
    var failure: (any Error)?
    func fetch(_ handle: MediaHandle) async throws -> Data {
        if let failure { throw failure }
        return Data(repeating: 4, count: 16)
    }
}

private struct FixedFreeSpace: FreeSpaceReporting {
    let bytes: Int?
    func freeBytes() -> Int? { bytes }
}

private struct Failure: Error, LocalizedError {
    var errorDescription: String? { "the homeserver refused" }
}

@MainActor
private func makeController(
    failure: (any Error)? = nil,
    freeBytes: Int = 100 * 1024 * 1024 * 1024
) throws -> (MediaController, URL) {
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/MediaControllerTests-\(UUID().uuidString)")
    let loader = MediaLoader(
        cache: try MediaCache(directory: directory),
        fetcher: StubFetcher(failure: failure),
        freeSpace: FixedFreeSpace(bytes: freeBytes)
    )
    return (MediaController(loader: loader), directory)
}

private let image = MessageAttachment(
    id: "a1",
    kind: .image,
    source: MediaHandle(source: "mxc://s/1", mimeType: "image/png")
)

@MainActor
@Test func anAttachmentIsIdleUntilSomethingAsksForIt() throws {
    let (controller, directory) = try makeController()
    defer { try? FileManager.default.removeItem(at: directory) }

    // Lazily means lazily: constructing the controller downloads nothing.
    #expect(controller.state(for: image) == .idle)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func loadingAnAttachmentEndsWithAFileOnDisk() async throws {
    let (controller, directory) = try makeController()
    defer { try? FileManager.default.removeItem(at: directory) }

    controller.load(image, accountID: "instagram", messageID: "$1")
    #expect(controller.state(for: image) == .loading)

    let url = try await waitForFile(controller, image)
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func aFailedDownloadSaysWhyAndCanBeRetried() async throws {
    let (controller, directory) = try makeController(failure: Failure())
    defer { try? FileManager.default.removeItem(at: directory) }

    controller.load(image, accountID: "instagram", messageID: "$1")
    let reason = try await waitForFailure(controller, image)
    #expect(reason.contains("refused"))

    // A failure must not be sticky, or a transient network blip loses the photo forever.
    controller.retry(image, accountID: "instagram", messageID: "$1")
    #expect(controller.state(for: image) != .idle)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func diskPressurePausesAndExplainsRatherThanLookingBroken() async throws {
    let (controller, directory) = try makeController(freeBytes: 100 * 1024 * 1024)
    defer { try? FileManager.default.removeItem(at: directory) }

    controller.load(image, accountID: "instagram", messageID: "$1")
    let deadline = ContinuousClock().now.advanced(by: .seconds(5))
    while ContinuousClock().now < deadline {
        if case .paused = controller.state(for: image) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    guard case let .paused(reason) = controller.state(for: image) else {
        Issue.record("expected the download to be paused, got \(controller.state(for: image))")
        return
    }
    #expect(reason.contains("nothing has been deleted"))
    #expect(controller.storageWarning != nil)
}

@MainActor
@Test func anAttachmentWithNothingToFetchIsNeverLoaded() throws {
    let (controller, directory) = try makeController()
    defer { try? FileManager.default.removeItem(at: directory) }

    let card = MessageAttachment(id: "card", kind: .appNative)
    controller.load(card, accountID: "instagram", messageID: "$1")
    #expect(controller.state(for: card) == .idle)
}

@MainActor
@Test func aControllerWithoutALoaderNeverDownloads() {
    // Previews and fixture runs must not reach for a network that is not there.
    let controller = MediaController()
    controller.load(image, accountID: "instagram", messageID: "$1")
    #expect(controller.state(for: image) == .idle)
}

// MARK: - Helpers

@MainActor
private func waitForFile(_ controller: MediaController, _ attachment: MessageAttachment) async throws -> URL {
    let deadline = ContinuousClock().now.advanced(by: .seconds(10))
    while ContinuousClock().now < deadline {
        if case let .ready(url) = controller.state(for: attachment) { return url }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw Failure()
}

@MainActor
private func waitForFailure(_ controller: MediaController, _ attachment: MessageAttachment) async throws -> String {
    let deadline = ContinuousClock().now.advanced(by: .seconds(10))
    while ContinuousClock().now < deadline {
        if case let .failed(reason) = controller.state(for: attachment) { return reason }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw Failure()
}
