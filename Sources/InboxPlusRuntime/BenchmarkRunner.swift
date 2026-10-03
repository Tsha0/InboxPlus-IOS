import Foundation

/// The narrow set of Matrix operations the benchmark exercises.
///
/// Injecting this lets tests drop, duplicate, or fail individual writes deterministically without
/// adding fault branches to the production path.
public protocol BenchmarkMatrixOperations: Sendable {
    func createdRoomIDs() async throws -> [String]
    func sendMessage(roomID: String, transactionID: String, body: String) async throws -> String
    func readTimeline(roomID: String, limit: Int) async throws -> Int
    func search(term: String) async throws -> Int
    func mediaMetadata(index: Int) async throws -> Int
    func eventIDs(inRoom roomID: String) async throws -> [String]
}

/// Runs the representative concurrent workload and reconciles every committed event.
public struct BenchmarkRunner: Sendable {
    private let operations: any BenchmarkMatrixOperations

    public init(operations: any BenchmarkMatrixOperations) {
        self.operations = operations
    }

    public func run(_ workload: BenchmarkWorkload) async throws -> BenchmarkRun {
        let clock = ContinuousClock()
        let started = clock.now
        let rooms = try await operations.createdRoomIDs()
        let partitions = Self.partition(rooms, into: workload.importWorkerCount)
        let collector = BenchmarkCollector()

        // Runs on the main executor for the whole workload so scheduling delay is measurable.
        //
        // The priority is explicit and load-bearing. This probe stands in for an app's UI main
        // thread, which macOS runs at user-initiated QoS. Inheriting the benchmark's own lower
        // priority instead lets the saturated import workers deschedule the probe for minutes at a
        // time, which measures QoS starvation of the instrument rather than timeline responsiveness.
        let heartbeat = Task(priority: .userInitiated) { @MainActor in
            let start = clock.now
            await Self.measureHeartbeat(
                intervalSeconds: Self.heartbeatIntervalSeconds,
                now: { Self.seconds(from: start, to: clock.now) },
                sleep: { seconds in
                    try? await Task.sleep(for: .microseconds(Int64(seconds * 1_000_000)))
                },
                isCancelled: { Task.isCancelled },
                record: { await collector.recordHeartbeat(seconds: $0) }
            )
        }
        defer { heartbeat.cancel() }

        // Every writer and reader runs concurrently; reconciliation waits for all of them.
        await withTaskGroup(of: Void.self) { group in
            for (workerIndex, partition) in partitions.enumerated() {
                group.addTask {
                    await runImportWorker(
                        workerIndex: workerIndex,
                        rooms: partition,
                        allRooms: rooms,
                        workload: workload,
                        collector: collector,
                        clock: clock
                    )
                }
            }
            group.addTask {
                await runLiveTraffic(rooms: rooms, workload: workload, collector: collector, clock: clock)
            }
            group.addTask {
                await runTimelineReads(rooms: rooms, workload: workload, collector: collector, clock: clock)
            }
            group.addTask {
                await runSearches(workload: workload, collector: collector, clock: clock)
            }
            group.addTask {
                await runMediaMetadata(workload: workload, collector: collector, clock: clock)
            }
            await group.waitForAll()
        }

        let expected = await collector.expectedEventsByRoom()
        var missing: [String] = []
        var duplicates: [String] = []
        var missingRooms: [String] = []
        var observedCount = 0

        for room in rooms {
            let observed = try await operations.eventIDs(inRoom: room)
            observedCount += observed.count
            let observedSet = Set(observed)
            if observed.count != observedSet.count {
                var seen: Set<String> = []
                for eventID in observed where !seen.insert(eventID).inserted {
                    duplicates.append(eventID)
                }
            }
            let expectedForRoom = expected[room] ?? []
            if expectedForRoom.isEmpty, observed.isEmpty, !expected.keys.contains(room) {
                missingRooms.append(room)
            }
            missing.append(contentsOf: expectedForRoom.filter { !observedSet.contains($0) })
        }

        let samples = await collector.samples()
        return BenchmarkRun(
            workload: workload,
            samples: samples,
            reconciliation: BenchmarkReconciliation(
                expectedEventCount: expected.values.reduce(0) { $0 + $1.count },
                observedEventCount: observedCount,
                missingEventIDs: missing.sorted(),
                duplicateEventIDs: duplicates.sorted(),
                missingRoomIDs: missingRooms.sorted()
            ),
            importPartitionSizes: partitions.map(\.count),
            importedEventCount: await collector.importedCount(),
            liveTrafficEventCount: await collector.liveTrafficCount(),
            unrecoverableFailureCount: await collector.failureCount(),
            elapsedSeconds: Self.seconds(from: started, to: clock.now)
        )
    }

    // MARK: - Workers

    private func runImportWorker(
        workerIndex: Int,
        rooms: [String],
        allRooms: [String],
        workload: BenchmarkWorkload,
        collector: BenchmarkCollector,
        clock: ContinuousClock
    ) async {
        for room in rooms {
            let roomIndex = allRooms.firstIndex(of: room) ?? 0
            for messageIndex in 0..<workload.messagesPerRoom {
                let transactionID = MatrixFixturePlan.transactionIdentifier(
                    seed: workload.seed,
                    roomIndex: roomIndex,
                    messageIndex: messageIndex
                )
                let started = clock.now
                do {
                    let eventID = try await operations.sendMessage(
                        roomID: room,
                        transactionID: transactionID,
                        body: "inboxplus import \(roomIndex):\(messageIndex)"
                    )
                    await collector.recordImport(
                        room: room,
                        eventID: eventID,
                        seconds: Self.seconds(from: started, to: clock.now)
                    )
                } catch {
                    await collector.recordFailure()
                }
            }
        }
    }

    /// Live traffic measures send-to-retrieval visibility while imports are still running.
    private func runLiveTraffic(
        rooms: [String],
        workload: BenchmarkWorkload,
        collector: BenchmarkCollector,
        clock: ContinuousClock
    ) async {
        guard !rooms.isEmpty else { return }
        for index in 0..<workload.liveTrafficCount {
            let room = rooms[index % rooms.count]
            let transactionID = MatrixFixturePlan.transactionIdentifier(
                seed: workload.seed &+ 1,
                roomIndex: index % rooms.count,
                messageIndex: index
            )
            let started = clock.now
            do {
                let eventID = try await operations.sendMessage(
                    roomID: room,
                    transactionID: transactionID,
                    body: "inboxplus live \(index)"
                )
                _ = try await operations.readTimeline(roomID: room, limit: 1)
                await collector.recordLiveTraffic(
                    room: room,
                    eventID: eventID,
                    seconds: Self.seconds(from: started, to: clock.now)
                )
            } catch {
                await collector.recordFailure()
            }
        }
    }

    private func runTimelineReads(
        rooms: [String],
        workload: BenchmarkWorkload,
        collector: BenchmarkCollector,
        clock: ContinuousClock
    ) async {
        guard !rooms.isEmpty else { return }
        for index in 0..<workload.timelineReadCount {
            let room = rooms[index % rooms.count]
            let started = clock.now
            do {
                _ = try await operations.readTimeline(roomID: room, limit: 50)
                await collector.recordTimelineRead(seconds: Self.seconds(from: started, to: clock.now))
            } catch {
                await collector.recordFailure()
            }
        }
    }

    private func runSearches(
        workload: BenchmarkWorkload,
        collector: BenchmarkCollector,
        clock: ContinuousClock
    ) async {
        for index in 0..<workload.searchCount {
            let started = clock.now
            do {
                _ = try await operations.search(term: "inboxplus \(index)")
                await collector.recordSearch(seconds: Self.seconds(from: started, to: clock.now))
            } catch {
                await collector.recordFailure()
            }
        }
    }

    private func runMediaMetadata(
        workload: BenchmarkWorkload,
        collector: BenchmarkCollector,
        clock: ContinuousClock
    ) async {
        for index in 0..<workload.mediaMetadataCount {
            let started = clock.now
            do {
                _ = try await operations.mediaMetadata(index: index)
                await collector.recordMediaMetadata(seconds: Self.seconds(from: started, to: clock.now))
            } catch {
                await collector.recordFailure()
            }
        }
    }

    // MARK: - Helpers

    /// One 60 Hz animation frame, the approved responsiveness budget.
    static let heartbeatIntervalSeconds = 1.0 / 60.0

    /// Measures how late each heartbeat wakeup fires relative to its own target.
    ///
    /// The target is re-derived from the current time on every iteration. Anchoring it once and
    /// advancing by a fixed interval instead accumulates scheduling debt: the loop cannot sustain
    /// a 60 Hz cadence while also recording each sample, so every later wakeup is reported as
    /// progressively later, and the measurement grows without bound instead of describing a frame.
    static func measureHeartbeat(
        intervalSeconds: Double,
        now: @Sendable () -> Double,
        sleep: @Sendable (Double) async -> Void,
        isCancelled: @Sendable () -> Bool,
        record: @Sendable (Double) async -> Void
    ) async {
        while !isCancelled() {
            let scheduled = now() + intervalSeconds
            await sleep(intervalSeconds)
            if isCancelled() { break }
            await record(max(0, now() - scheduled))
        }
    }

    /// Splits rooms into exactly `workers` contiguous, non-empty partitions.
    static func partition(_ rooms: [String], into workers: Int) -> [[String]] {
        let workers = max(1, min(workers, rooms.count))
        guard workers > 0, !rooms.isEmpty else { return [] }
        var partitions: [[String]] = []
        var start = 0
        for worker in 0..<workers {
            let remainingWorkers = workers - worker
            let size = (rooms.count - start + remainingWorkers - 1) / remainingWorkers
            partitions.append(Array(rooms[start..<(start + size)]))
            start += size
        }
        return partitions
    }

    static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: end).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Serializes every concurrent worker's measurements.
actor BenchmarkCollector {
    private var expected: [String: [String]] = [:]
    private var latency = LatencySamples()
    private var imported = 0
    private var liveTraffic = 0
    private var failures = 0

    func recordImport(room: String, eventID: String, seconds: Double) {
        expected[room, default: []].append(eventID)
        latency.imports.append(seconds)
        imported += 1
    }

    func recordLiveTraffic(room: String, eventID: String, seconds: Double) {
        expected[room, default: []].append(eventID)
        latency.committedEventVisibility.append(seconds)
        liveTraffic += 1
    }

    func recordTimelineRead(seconds: Double) { latency.warmTimelineReads.append(seconds) }
    func recordSearch(seconds: Double) { latency.searches.append(seconds) }
    func recordMediaMetadata(seconds: Double) { latency.mediaMetadata.append(seconds) }
    func recordHeartbeat(seconds: Double) { latency.heartbeatDelays.append(seconds) }
    func recordFailure() { failures += 1 }

    func expectedEventsByRoom() -> [String: [String]] { expected }
    func samples() -> LatencySamples { latency }
    func importedCount() -> Int { imported }
    func liveTrafficCount() -> Int { liveTraffic }
    func failureCount() -> Int { failures }
}
