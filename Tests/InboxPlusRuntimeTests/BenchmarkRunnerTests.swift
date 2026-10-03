import Foundation
import Testing
@testable import InboxPlusRuntime

// MARK: - Workload shape

@Test func representativeWorkloadMeetsApprovedShape() {
    let workload = BenchmarkWorkload.representative(seed: 42)
    #expect(workload.roomCount == 2_000)
    #expect(workload.messageCount >= 100_000)
    #expect(workload.importWorkerCount == 3)
    #expect(workload.liveTrafficCount > 0)
    #expect(workload.timelineReadCount > 0)
    #expect(workload.searchCount > 0)
    #expect(workload.mediaMetadataCount > 0)
}

@Test func reducedWorkloadKeepsEveryDimensionNonEmpty() {
    let workload = BenchmarkWorkload.reduced(seed: 7, rooms: 20, messages: 1_000, importWorkers: 3)
    #expect(workload.roomCount == 20)
    #expect(workload.messageCount == 1_000)
    #expect(workload.importWorkerCount == 3)
    #expect(workload.liveTrafficCount > 0)
    #expect(workload.timelineReadCount > 0)
    #expect(workload.searchCount > 0)
    #expect(workload.mediaMetadataCount > 0)
}

// MARK: - Execution

@Test func everyImportedEventIsReconciledExactly() async throws {
    let operations = FakeBenchmarkOperations(roomCount: 12)
    let run = try await BenchmarkRunner(operations: operations).run(
        .reduced(seed: 7, rooms: 12, messages: 60, importWorkers: 3)
    )

    #expect(run.reconciliation.missingEventIDs.isEmpty)
    #expect(run.reconciliation.duplicateEventIDs.isEmpty)
    #expect(run.reconciliation.missingRoomIDs.isEmpty)
    #expect(run.importedEventCount == 60)
}

@Test func missingEventFailsReconciliation() async throws {
    // Break caught: a dropped write is invisible unless every expected event is read back.
    let operations = FakeBenchmarkOperations(roomCount: 6, dropEventAtIndex: 3)
    let run = try await BenchmarkRunner(operations: operations).run(
        .reduced(seed: 7, rooms: 6, messages: 30, importWorkers: 3)
    )

    #expect(run.reconciliation.missingEventIDs.count == 1)
    #expect(!run.reconciliation.isExact)
}

@Test func duplicatedEventFailsReconciliation() async throws {
    let operations = FakeBenchmarkOperations(roomCount: 6, duplicateEventAtIndex: 2)
    let run = try await BenchmarkRunner(operations: operations).run(
        .reduced(seed: 7, rooms: 6, messages: 30, importWorkers: 3)
    )

    #expect(run.reconciliation.duplicateEventIDs.count == 1)
    #expect(!run.reconciliation.isExact)
}

@Test func importsArePartitionedAcrossExactlyTheConfiguredWorkers() async throws {
    let operations = FakeBenchmarkOperations(roomCount: 20)
    let run = try await BenchmarkRunner(operations: operations).run(
        .reduced(seed: 7, rooms: 20, messages: 100, importWorkers: 3)
    )

    #expect(run.importPartitionSizes.count == 3)
    #expect(run.importPartitionSizes.reduce(0, +) == 20)
    #expect(run.importPartitionSizes.allSatisfy { $0 > 0 })
}

@Test func everyWorkloadDimensionActuallyRuns() async throws {
    let operations = FakeBenchmarkOperations(roomCount: 12)
    let workload = BenchmarkWorkload.reduced(seed: 7, rooms: 12, messages: 60, importWorkers: 3)
    let run = try await BenchmarkRunner(operations: operations).run(workload)

    #expect(run.samples.warmTimelineReads.count == workload.timelineReadCount)
    #expect(run.samples.searches.count == workload.searchCount)
    #expect(run.samples.mediaMetadata.count == workload.mediaMetadataCount)
    #expect(run.liveTrafficEventCount == workload.liveTrafficCount)
    #expect(await operations.searchCount() == workload.searchCount)
    #expect(await operations.mediaMetadataCount() == workload.mediaMetadataCount)
    // Live traffic reads its own room back to measure visibility, on top of the warm reads.
    #expect(
        await operations.timelineReadCount()
            == workload.timelineReadCount + workload.liveTrafficCount
    )
}

@Test func transactionIdentifiersAreStableAcrossRuns() async throws {
    let first = FakeBenchmarkOperations(roomCount: 8)
    _ = try await BenchmarkRunner(operations: first).run(
        .reduced(seed: 99, rooms: 8, messages: 40, importWorkers: 2)
    )
    let second = FakeBenchmarkOperations(roomCount: 8)
    _ = try await BenchmarkRunner(operations: second).run(
        .reduced(seed: 99, rooms: 8, messages: 40, importWorkers: 2)
    )

    #expect(await first.transactionIdentifiers() == second.transactionIdentifiers())
}

@Test func reconciliationReadsHappenAfterEveryWriterFinishes() async throws {
    // Break caught: reading while imports are still committing under-counts and hides loss.
    let operations = FakeBenchmarkOperations(roomCount: 10)
    let run = try await BenchmarkRunner(operations: operations).run(
        .reduced(seed: 7, rooms: 10, messages: 50, importWorkers: 3)
    )

    #expect(await operations.sawReadBeforeAllWritesCompleted() == false)
    // Guards the guard: reconciliation must actually have read something back.
    #expect(run.reconciliation.observedEventCount == run.reconciliation.expectedEventCount)
    #expect(run.reconciliation.expectedEventCount > 0)
}

@Test func latencySamplesAreCollectedForEveryMeasuredCategory() async throws {
    let operations = FakeBenchmarkOperations(roomCount: 10)
    let run = try await BenchmarkRunner(operations: operations).run(
        .reduced(seed: 7, rooms: 10, messages: 50, importWorkers: 3)
    )

    #expect(!run.samples.warmTimelineReads.isEmpty)
    #expect(!run.samples.committedEventVisibility.isEmpty)
    #expect(!run.samples.imports.isEmpty)
}

@Test func anUnrecoverableRequestFailureIsRecorded() async throws {
    let operations = FakeBenchmarkOperations(roomCount: 6, failSendAtIndex: 4)
    let run = try await BenchmarkRunner(operations: operations).run(
        .reduced(seed: 7, rooms: 6, messages: 30, importWorkers: 2)
    )

    #expect(run.unrecoverableFailureCount == 1)
}

// MARK: - Heartbeat

@Test func aLateHeartbeatDoesNotInflateLaterSamples() async throws {
    // Break caught: anchoring the target once and advancing by a fixed interval accumulates
    // scheduling debt, so every later sample grows without bound instead of describing a frame.
    let clock = VirtualClock(interval: 0.5)
    // The first sleep overshoots by 5 s; every later sleep is punctual.
    await clock.setOvershoots([5.0, 0, 0, 0])

    let recorder = SampleRecorder()
    await BenchmarkRunner.measureHeartbeat(
        intervalSeconds: 0.5,
        now: { clock.currentSeconds() },
        sleep: { seconds in await clock.advance(by: seconds) },
        isCancelled: { clock.tickCount() >= 4 },
        record: { recorder.append($0) }
    )

    let samples = recorder.values()
    #expect(samples.count == 3)
    #expect(abs(samples[0] - 5.0) < 0.001)
    // The punctual wakeups that follow must report ~0, not the inherited 5 s of debt.
    #expect(samples[1] < 0.001)
    #expect(samples[2] < 0.001)
}

@Test func punctualHeartbeatsReportNoDelay() async throws {
    let clock = VirtualClock(interval: 0.5)
    await clock.setOvershoots([0, 0, 0])

    let recorder = SampleRecorder()
    await BenchmarkRunner.measureHeartbeat(
        intervalSeconds: 0.5,
        now: { clock.currentSeconds() },
        sleep: { seconds in await clock.advance(by: seconds) },
        isCancelled: { clock.tickCount() >= 3 },
        record: { recorder.append($0) }
    )

    let samples = recorder.values()
    #expect(samples.allSatisfy { $0 < 0.001 })
    #expect(!samples.isEmpty)
}

private final class SampleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Double] = []
    func append(_ value: Double) { lock.withLock { samples.append(value) } }
    func values() -> [Double] { lock.withLock { samples } }
}

/// A deterministic clock whose sleeps can overshoot by a scripted amount.
private final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds = 0.0
    private var overshoots: [Double] = []
    private var ticks = 0

    init(interval: Double) {}

    func setOvershoots(_ values: [Double]) async {
        lock.withLock { overshoots = values }
    }

    func advance(by requested: Double) async {
        lock.withLock {
            let overshoot = ticks < overshoots.count ? overshoots[ticks] : 0
            seconds += requested + overshoot
            ticks += 1
        }
    }

    func currentSeconds() -> Double { lock.withLock { seconds } }
    func tickCount() -> Int { lock.withLock { ticks } }
}

// MARK: - Fake operations

private actor FakeBenchmarkOperations: BenchmarkMatrixOperations {
    private let rooms: [String]
    private let dropEventAtIndex: Int?
    private let duplicateEventAtIndex: Int?
    private let failSendAtIndex: Int?

    private var committed: [String: [String]] = [:]
    private var sendIndex = 0
    private var recordedTransactionIdentifiers: [String] = []
    private var writesAtFirstReconciliationRead: Int?
    private var completedWrites = 0
    private var timelineReads = 0
    private var searches = 0
    private var mediaLookups = 0

    init(
        roomCount: Int,
        dropEventAtIndex: Int? = nil,
        duplicateEventAtIndex: Int? = nil,
        failSendAtIndex: Int? = nil
    ) {
        rooms = (0..<roomCount).map { "!room\($0):inboxplus.localhost" }
        self.dropEventAtIndex = dropEventAtIndex
        self.duplicateEventAtIndex = duplicateEventAtIndex
        self.failSendAtIndex = failSendAtIndex
    }

    func createdRoomIDs() async throws -> [String] { rooms }

    func sendMessage(roomID: String, transactionID: String, body: String) async throws -> String {
        recordedTransactionIdentifiers.append(transactionID)
        let index = sendIndex
        sendIndex += 1
        completedWrites += 1

        if index == failSendAtIndex {
            throw MatrixHTTPError.retriesExhausted(statusCode: 503, attempts: 4)
        }
        let eventID = "$event-\(index)"
        if index == dropEventAtIndex { return eventID }
        committed[roomID, default: []].append(eventID)
        if index == duplicateEventAtIndex {
            committed[roomID, default: []].append(eventID)
        }
        return eventID
    }

    func readTimeline(roomID: String, limit: Int) async throws -> Int {
        timelineReads += 1
        return committed[roomID]?.count ?? 0
    }

    func search(term: String) async throws -> Int {
        searches += 1
        return 0
    }

    func mediaMetadata(index: Int) async throws -> Int {
        mediaLookups += 1
        return 0
    }

    func eventIDs(inRoom roomID: String) async throws -> [String] {
        // Record the write count observed by the first reconciliation read; if any write lands
        // afterwards, reconciliation started while writers were still committing.
        if writesAtFirstReconciliationRead == nil {
            writesAtFirstReconciliationRead = completedWrites
        }
        return committed[roomID] ?? []
    }

    func transactionIdentifiers() -> [String] { recordedTransactionIdentifiers.sorted() }
    func timelineReadCount() -> Int { timelineReads }
    func searchCount() -> Int { searches }
    func mediaMetadataCount() -> Int { mediaLookups }
    func sawReadBeforeAllWritesCompleted() -> Bool {
        guard let writesAtFirstReconciliationRead else { return false }
        return writesAtFirstReconciliationRead != completedWrites
    }
}
