import Foundation

public struct GateResult: Codable, Sendable, Equatable {
    public let name: String
    public let measured: Double
    public let threshold: Double
    public let unit: String
    public let passed: Bool

    public init(name: String, measured: Double, threshold: Double, unit: String, passed: Bool) {
        self.name = name
        self.measured = measured
        self.threshold = threshold
        self.unit = unit
        self.passed = passed
    }
}

public struct BenchmarkVerdict: Codable, Sendable, Equatable {
    public let decision: DatabaseDecision
    public let gates: [GateResult]
    public let failureReasons: [String]

    public init(decision: DatabaseDecision, gates: [GateResult], failureReasons: [String]) {
        self.decision = decision
        self.gates = gates
        self.failureReasons = failureReasons
    }
}

/// The exact document written to disk, so raw samples stay reproducible.
public struct BenchmarkReport: Codable, Sendable, Equatable {
    public let run: BenchmarkRun
    public let verdict: BenchmarkVerdict
    public let generatedAt: Date

    public init(run: BenchmarkRun, verdict: BenchmarkVerdict, generatedAt: Date) {
        self.run = run
        self.verdict = verdict
        self.generatedAt = generatedAt
    }
}

public struct ReportArtifacts: Sendable, Equatable {
    public let jsonURL: URL
    public let markdownURL: URL
}

public enum BenchmarkReportError: Error, Equatable, Sendable {
    case cannotWrite(URL)
}

/// Calculates gates, decides the database verdict, and renders redacted reports.
public struct BenchmarkReporter: Sendable {
    /// Approved Phase 2 gates. A run fails at the threshold, not merely beyond it.
    public static let warmTimelineThresholdSeconds = 0.5
    public static let committedEventThresholdSeconds = 2.0
    public static let heartbeatThresholdSeconds = 0.016_67

    private let sensitiveValues: [String]
    private let now: @Sendable () -> Date

    public init(sensitiveValues: [String] = [], now: @escaping @Sendable () -> Date = Date.init) {
        self.sensitiveValues = sensitiveValues.filter { !$0.isEmpty }
        self.now = now
    }

    /// Nearest-rank percentile: the smallest sample at or above the requested rank.
    public static func percentile(_ values: [Double], percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((percentile * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    public static func evaluate(_ run: BenchmarkRun) -> BenchmarkVerdict {
        let warmTimeline = percentile(run.samples.warmTimelineReads, percentile: 0.95)
        let visibility = percentile(run.samples.committedEventVisibility, percentile: 0.95)
        let heartbeat = run.samples.heartbeatDelays.max() ?? 0

        var gates = [
            GateResult(
                name: "warm timeline read p95",
                measured: warmTimeline,
                threshold: warmTimelineThresholdSeconds,
                unit: "s",
                passed: warmTimeline < warmTimelineThresholdSeconds
            ),
            GateResult(
                name: "committed event visibility p95",
                measured: visibility,
                threshold: committedEventThresholdSeconds,
                unit: "s",
                passed: visibility < committedEventThresholdSeconds
            ),
            GateResult(
                name: "main executor heartbeat delay",
                measured: heartbeat,
                threshold: heartbeatThresholdSeconds,
                unit: "s",
                passed: heartbeat <= heartbeatThresholdSeconds
            ),
            GateResult(
                name: "event reconciliation",
                measured: Double(
                    run.reconciliation.missingEventIDs.count
                        + run.reconciliation.duplicateEventIDs.count
                        + run.reconciliation.missingRoomIDs.count
                ),
                threshold: 0,
                unit: "discrepancies",
                passed: run.reconciliation.isExact
            ),
            GateResult(
                name: "unrecoverable requests",
                measured: Double(run.unrecoverableFailureCount),
                threshold: 0,
                unit: "requests",
                passed: run.unrecoverableFailureCount == 0
            ),
        ]

        let integrity = run.sqliteIntegrity ?? "unverified"
        gates.append(
            GateResult(
                name: "sqlite integrity",
                measured: integrity == "ok" ? 0 : 1,
                threshold: 0,
                unit: "failures",
                passed: integrity == "ok"
            )
        )
        gates.append(
            GateResult(
                name: "recovery verified",
                measured: run.recoveryVerified == true ? 0 : 1,
                threshold: 0,
                unit: "failures",
                passed: run.recoveryVerified == true
            )
        )

        let failureReasons = gates.filter { !$0.passed }.map { gate in
            "\(gate.name) measured \(format(gate.measured)) \(gate.unit) against a \(format(gate.threshold)) \(gate.unit) limit"
        }
        return BenchmarkVerdict(
            decision: failureReasons.isEmpty ? .retainSQLiteProvisionally : .requirePostgreSQL,
            gates: gates,
            failureReasons: failureReasons
        )
    }

    public func json(for run: BenchmarkRun, verdict: BenchmarkVerdict) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            BenchmarkReport(run: run, verdict: verdict, generatedAt: now())
        )
        return Data(redact(String(decoding: data, as: UTF8.self)).utf8)
    }

    public func markdown(for run: BenchmarkRun, verdict: BenchmarkVerdict) -> String {
        let decision = verdict.decision == .retainSQLiteProvisionally
            ? "Retain SQLite provisionally"
            : "Require PostgreSQL"

        var lines: [String] = [
            "# Phase 2 SQLite benchmark",
            "",
            "**Decision: \(decision)**",
            "",
            "## Workload",
            "",
            "| Dimension | Value |",
            "| --- | --- |",
            "| Seed | \(run.workload.seed) |",
            "| Rooms | \(run.workload.roomCount) |",
            "| Messages | \(run.workload.messageCount) |",
            "| Import workers | \(run.workload.importWorkerCount) |",
            "| Import partitions | \(run.importPartitionSizes.map(String.init).joined(separator: ", ")) |",
            "| Live traffic events | \(run.liveTrafficEventCount) |",
            "| Elapsed | \(format(run.elapsedSeconds)) s |",
            "",
            "## Gates",
            "",
            "| Gate | Measured | Limit | Result |",
            "| --- | --- | --- | --- |",
        ]
        for gate in verdict.gates {
            lines.append(
                "| \(gate.name) | \(format(gate.measured)) \(gate.unit) | \(format(gate.threshold)) \(gate.unit) | \(gate.passed ? "pass" : "FAIL") |"
            )
        }

        lines.append(contentsOf: [
            "",
            "## Latency summary",
            "",
            "| Series | p50 | p95 | p99 | Samples |",
            "| --- | --- | --- | --- | --- |",
            summaryRow("Imports", run.samples.imports),
            summaryRow("Warm timeline reads", run.samples.warmTimelineReads),
            summaryRow("Committed event visibility", run.samples.committedEventVisibility),
            summaryRow("Searches", run.samples.searches),
            summaryRow("Media metadata", run.samples.mediaMetadata),
            summaryRow("Heartbeat delays", run.samples.heartbeatDelays),
            "",
            "The heartbeat probe runs on the main executor at user-initiated priority, standing in",
            "for an app's UI main thread. The gate uses the worst observed sample, not a percentile.",
            "",
            "## Reconciliation",
            "",
            "| Measure | Value |",
            "| --- | --- |",
            "| Expected events | \(run.reconciliation.expectedEventCount) |",
            "| Observed events | \(run.reconciliation.observedEventCount) |",
            "| Missing events | \(run.reconciliation.missingEventIDs.count) |",
            "| Duplicate events | \(run.reconciliation.duplicateEventIDs.count) |",
            "| Missing rooms | \(run.reconciliation.missingRoomIDs.count) |",
            "| Unrecoverable requests | \(run.unrecoverableFailureCount) |",
            "| SQLite integrity | \(run.sqliteIntegrity ?? "unverified") |",
            "| Recovery verified | \(run.recoveryVerified.map(String.init) ?? "unverified") |",
        ])

        if let environment = run.environment {
            lines.append(contentsOf: [
                "",
                "## Environment",
                "",
                "| Property | Value |",
                "| --- | --- |",
                "| Hardware | \(environment.hardwareModel) (\(environment.architecture)) |",
                "| Memory | \(environment.physicalMemoryBytes) bytes |",
                "| OS | \(environment.operatingSystem) |",
                "| Swift | \(environment.swiftVersion) |",
                "| Python | \(environment.pythonVersion) |",
                "| Synapse | \(environment.synapseVersion) |",
                "| Dependency lock SHA-256 | \(environment.requirementsLockSHA256) |",
                "| Database size | \(environment.databaseBytes) bytes |",
                "| Peak resident memory | \(environment.peakResidentBytes) bytes |",
                "| CPU time | \(format(environment.cpuSeconds)) s |",
            ])
        }

        if !verdict.failureReasons.isEmpty {
            lines.append(contentsOf: ["", "## Failing gates", ""])
            lines.append(contentsOf: verdict.failureReasons.map { "- \($0)" })
        }

        return redact(lines.joined(separator: "\n") + "\n")
    }

    public func write(
        _ run: BenchmarkRun,
        verdict: BenchmarkVerdict,
        to directory: URL,
        name: String
    ) throws -> ReportArtifacts {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let jsonURL = directory.appendingPathComponent("\(name).json")
        let markdownURL = directory.appendingPathComponent("\(name).md")
        try writeAtomically(try json(for: run, verdict: verdict), to: jsonURL)
        try writeAtomically(Data(markdown(for: run, verdict: verdict).utf8), to: markdownURL)
        return ReportArtifacts(jsonURL: jsonURL, markdownURL: markdownURL)
    }

    // MARK: - Helpers

    private func writeAtomically(_ data: Data, to url: URL) throws {
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: staging.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw BenchmarkReportError.cannotWrite(url)
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private func summaryRow(_ label: String, _ values: [Double]) -> String {
        "| \(label) | \(format(Self.percentile(values, percentile: 0.5))) | \(format(Self.percentile(values, percentile: 0.95))) | \(format(Self.percentile(values, percentile: 0.99))) | \(values.count) |"
    }

    private func redact(_ text: String) -> String {
        sensitiveValues.reduce(text) { $0.replacingOccurrences(of: $1, with: "[redacted]") }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6g", value)
    }

    private func format(_ value: Double) -> String { Self.format(value) }
}
