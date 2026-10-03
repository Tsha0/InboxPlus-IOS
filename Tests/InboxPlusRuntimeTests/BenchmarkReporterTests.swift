import Foundation
import Testing
@testable import InboxPlusRuntime

// MARK: - Percentiles

@Test func percentileUsesNearestRank() {
    #expect(BenchmarkReporter.percentile([1, 2, 3, 100], percentile: 0.95) == 100)
}

@Test func percentileOfASingleSampleIsThatSample() {
    #expect(BenchmarkReporter.percentile([42], percentile: 0.95) == 42)
}

@Test func percentileOfNoSamplesIsZero() {
    #expect(BenchmarkReporter.percentile([], percentile: 0.95) == 0)
}

@Test func percentileIgnoresInputOrder() {
    #expect(
        BenchmarkReporter.percentile([100, 3, 1, 2], percentile: 0.95)
            == BenchmarkReporter.percentile([1, 2, 3, 100], percentile: 0.95)
    )
}

@Test func medianUsesNearestRank() {
    #expect(BenchmarkReporter.percentile([1, 2, 3, 4], percentile: 0.5) == 2)
}

// MARK: - Verdict

@Test func aFullyPassingRunRetainsSQLite() {
    #expect(BenchmarkReporter.evaluate(passingRun()).decision == .retainSQLiteProvisionally)
}

@Test func anyIntegrityFailureRequiresPostgreSQL() {
    let run = passingRun(missingEvents: 1)
    #expect(BenchmarkReporter.evaluate(run).decision == .requirePostgreSQL)
}

@Test func aDuplicateEventRequiresPostgreSQL() {
    #expect(BenchmarkReporter.evaluate(passingRun(duplicateEvents: 1)).decision == .requirePostgreSQL)
}

@Test func aSlowWarmTimelineRequiresPostgreSQL() {
    // The gate fails at exactly 500 ms, not only beyond it.
    let run = passingRun(warmTimelineSeconds: Array(repeating: 0.5, count: 20))
    #expect(BenchmarkReporter.evaluate(run).decision == .requirePostgreSQL)
}

@Test func aSlowCommittedEventVisibilityRequiresPostgreSQL() {
    let run = passingRun(visibilitySeconds: Array(repeating: 2.0, count: 20))
    #expect(BenchmarkReporter.evaluate(run).decision == .requirePostgreSQL)
}

@Test func aDelayedHeartbeatRequiresPostgreSQL() {
    let run = passingRun(heartbeatSeconds: Array(repeating: 0.020, count: 20))
    #expect(BenchmarkReporter.evaluate(run).decision == .requirePostgreSQL)
}

@Test func aFailedSQLiteIntegrityCheckRequiresPostgreSQL() {
    #expect(BenchmarkReporter.evaluate(passingRun(integrity: "malformed")).decision == .requirePostgreSQL)
}

@Test func unverifiedRecoveryRequiresPostgreSQL() {
    #expect(BenchmarkReporter.evaluate(passingRun(recoveryVerified: false)).decision == .requirePostgreSQL)
}

@Test func anUnrecoverableRequestRequiresPostgreSQL() {
    #expect(BenchmarkReporter.evaluate(passingRun(failures: 1)).decision == .requirePostgreSQL)
}

@Test func everyFailedGateIsEnumeratedWithItsMeasuredValue() {
    let verdict = BenchmarkReporter.evaluate(
        passingRun(warmTimelineSeconds: Array(repeating: 0.75, count: 10), missingEvents: 2)
    )
    #expect(verdict.decision == .requirePostgreSQL)
    #expect(verdict.failureReasons.count >= 2)
    #expect(verdict.gates.contains { !$0.passed && $0.name.contains("timeline") })
    #expect(verdict.failureReasons.contains { $0.contains("0.75") })
}

@Test func passingGatesAreStillReported() {
    let verdict = BenchmarkReporter.evaluate(passingRun())
    #expect(verdict.gates.allSatisfy { $0.passed })
    #expect(verdict.gates.count >= 5)
    #expect(verdict.failureReasons.isEmpty)
}

// MARK: - Rendering and redaction

@Test func reportsDoNotContainTokensOrMessageBodies() throws {
    let reporter = BenchmarkReporter(sensitiveValues: ["secret-token", "private body"])
    let run = passingRun()
    let markdown = reporter.markdown(for: run, verdict: BenchmarkReporter.evaluate(run))
    let json = try reporter.json(for: run, verdict: BenchmarkReporter.evaluate(run))

    #expect(!markdown.contains("secret-token"))
    #expect(!markdown.contains("private body"))
    #expect(!String(decoding: json, as: UTF8.self).contains("secret-token"))
}

@Test func sensitiveValuesAppearingInAReportAreRedacted() {
    // "abc123" is the fixture's lock checksum, so it genuinely appears before redaction.
    let run = passingRun()
    let plain = BenchmarkReporter().markdown(for: run, verdict: BenchmarkReporter.evaluate(run))
    #expect(plain.contains("abc123"))

    let reporter = BenchmarkReporter(sensitiveValues: ["abc123"])
    let redacted = reporter.markdown(for: run, verdict: BenchmarkReporter.evaluate(run))
    #expect(!redacted.contains("abc123"))
    #expect(redacted.contains("[redacted]"))
}

@Test func markdownStatesTheDecisionAndEveryGate() {
    let run = passingRun()
    let markdown = BenchmarkReporter().markdown(for: run, verdict: BenchmarkReporter.evaluate(run))
    #expect(markdown.contains("Retain SQLite provisionally"))
    #expect(markdown.contains("p95"))
    #expect(markdown.contains("Reconciliation"))
}

@Test func markdownStatesTheFailingDecisionVerbatim() {
    let run = passingRun(missingEvents: 1)
    let markdown = BenchmarkReporter().markdown(for: run, verdict: BenchmarkReporter.evaluate(run))
    #expect(markdown.contains("Require PostgreSQL"))
}

@Test func jsonRetainsEveryRawSample() throws {
    let run = passingRun()
    let data = try BenchmarkReporter().json(for: run, verdict: BenchmarkReporter.evaluate(run))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(BenchmarkReport.self, from: data)
    let warmTimelineReads = decoded.run.samples.warmTimelineReads
    #expect(warmTimelineReads == run.samples.warmTimelineReads)
    #expect(decoded.verdict.decision == .retainSQLiteProvisionally)
}

@Test func writingProducesBothArtifactsAtomically() throws {
    let directory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Library/Caches", isDirectory: true)
        .appendingPathComponent("InboxPlusReporterTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let run = passingRun()
    let artifacts = try BenchmarkReporter().write(
        run,
        verdict: BenchmarkReporter.evaluate(run),
        to: directory,
        name: "reduced"
    )

    #expect(FileManager.default.fileExists(atPath: artifacts.jsonURL.path))
    #expect(FileManager.default.fileExists(atPath: artifacts.markdownURL.path))
    let residue = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasPrefix(".") }
    #expect(residue.isEmpty)
}

// MARK: - Fixtures

private func passingRun(
    warmTimelineSeconds: [Double] = Array(repeating: 0.010, count: 20),
    visibilitySeconds: [Double] = Array(repeating: 0.050, count: 20),
    heartbeatSeconds: [Double] = Array(repeating: 0.002, count: 20),
    missingEvents: Int = 0,
    duplicateEvents: Int = 0,
    failures: Int = 0,
    integrity: String = "ok",
    recoveryVerified: Bool = true
) -> BenchmarkRun {
    var samples = LatencySamples()
    samples.warmTimelineReads = warmTimelineSeconds
    samples.committedEventVisibility = visibilitySeconds
    samples.heartbeatDelays = heartbeatSeconds
    samples.imports = Array(repeating: 0.005, count: 100)

    return BenchmarkRun(
        workload: .reduced(seed: 42, rooms: 20, messages: 1_000, importWorkers: 3),
        samples: samples,
        reconciliation: BenchmarkReconciliation(
            expectedEventCount: 1_000,
            observedEventCount: 1_000 - missingEvents,
            missingEventIDs: (0..<missingEvents).map { "$missing-\($0)" },
            duplicateEventIDs: (0..<duplicateEvents).map { "$duplicate-\($0)" },
            missingRoomIDs: []
        ),
        importPartitionSizes: [7, 7, 6],
        importedEventCount: 1_000,
        liveTrafficEventCount: 10,
        unrecoverableFailureCount: failures,
        elapsedSeconds: 12.5,
        environment: BenchmarkEnvironment(
            hardwareModel: "Mac16,10",
            architecture: "arm64",
            physicalMemoryBytes: 17_179_869_184,
            operatingSystem: "macOS 15.0",
            swiftVersion: "6.2",
            pythonVersion: "3.12.7",
            synapseVersion: "1.158.0",
            requirementsLockSHA256: "abc123",
            databaseBytes: 1_048_576,
            peakResidentBytes: 268_435_456,
            cpuSeconds: 30.0
        ),
        sqliteIntegrity: integrity,
        recoveryVerified: recoveryVerified
    )
}
