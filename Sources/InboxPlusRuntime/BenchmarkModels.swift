import Foundation

/// The exact shape of one benchmark run, deterministic from its seed.
public struct BenchmarkWorkload: Codable, Sendable, Equatable {
    public let seed: UInt64
    public let roomCount: Int
    public let messageCount: Int
    public let importWorkerCount: Int
    public let liveTrafficCount: Int
    public let timelineReadCount: Int
    public let searchCount: Int
    public let mediaMetadataCount: Int

    public init(
        seed: UInt64,
        roomCount: Int,
        messageCount: Int,
        importWorkerCount: Int,
        liveTrafficCount: Int,
        timelineReadCount: Int,
        searchCount: Int,
        mediaMetadataCount: Int
    ) {
        self.seed = seed
        self.roomCount = roomCount
        self.messageCount = messageCount
        self.importWorkerCount = importWorkerCount
        self.liveTrafficCount = liveTrafficCount
        self.timelineReadCount = timelineReadCount
        self.searchCount = searchCount
        self.mediaMetadataCount = mediaMetadataCount
    }

    /// The approved Phase 2 shape: 100,000 messages across 2,000 rooms, three import workers.
    public static func representative(seed: UInt64) -> BenchmarkWorkload {
        reduced(seed: seed, rooms: 2_000, messages: 100_000, importWorkers: 3)
    }

    /// Scales the secondary dimensions with the primary ones so reduced runs stay representative.
    public static func reduced(
        seed: UInt64,
        rooms: Int,
        messages: Int,
        importWorkers: Int
    ) -> BenchmarkWorkload {
        BenchmarkWorkload(
            seed: seed,
            roomCount: rooms,
            messageCount: messages,
            importWorkerCount: importWorkers,
            liveTrafficCount: max(1, messages / 100),
            timelineReadCount: max(1, rooms / 10),
            searchCount: max(1, rooms / 100),
            mediaMetadataCount: max(1, rooms / 20)
        )
    }

    var messagesPerRoom: Int { max(1, messageCount / max(1, roomCount)) }
}

public struct LatencySamples: Codable, Sendable, Equatable {
    public var imports: [Double] = []
    public var warmTimelineReads: [Double] = []
    public var committedEventVisibility: [Double] = []
    public var searches: [Double] = []
    public var mediaMetadata: [Double] = []
    public var heartbeatDelays: [Double] = []

    public init() {}
}

public struct BenchmarkReconciliation: Codable, Sendable, Equatable {
    public let expectedEventCount: Int
    public let observedEventCount: Int
    public let missingEventIDs: [String]
    public let duplicateEventIDs: [String]
    public let missingRoomIDs: [String]

    public init(
        expectedEventCount: Int,
        observedEventCount: Int,
        missingEventIDs: [String],
        duplicateEventIDs: [String],
        missingRoomIDs: [String]
    ) {
        self.expectedEventCount = expectedEventCount
        self.observedEventCount = observedEventCount
        self.missingEventIDs = missingEventIDs
        self.duplicateEventIDs = duplicateEventIDs
        self.missingRoomIDs = missingRoomIDs
    }

    public var isExact: Bool {
        missingEventIDs.isEmpty && duplicateEventIDs.isEmpty && missingRoomIDs.isEmpty
    }
}

public struct BenchmarkEnvironment: Codable, Sendable, Equatable {
    public let hardwareModel: String
    public let architecture: String
    public let physicalMemoryBytes: UInt64
    public let operatingSystem: String
    public let swiftVersion: String
    public let pythonVersion: String
    public let synapseVersion: String
    public let requirementsLockSHA256: String
    public let databaseBytes: UInt64
    public let peakResidentBytes: UInt64
    public let cpuSeconds: Double

    public init(
        hardwareModel: String,
        architecture: String,
        physicalMemoryBytes: UInt64,
        operatingSystem: String,
        swiftVersion: String,
        pythonVersion: String,
        synapseVersion: String,
        requirementsLockSHA256: String,
        databaseBytes: UInt64,
        peakResidentBytes: UInt64,
        cpuSeconds: Double
    ) {
        self.hardwareModel = hardwareModel
        self.architecture = architecture
        self.physicalMemoryBytes = physicalMemoryBytes
        self.operatingSystem = operatingSystem
        self.swiftVersion = swiftVersion
        self.pythonVersion = pythonVersion
        self.synapseVersion = synapseVersion
        self.requirementsLockSHA256 = requirementsLockSHA256
        self.databaseBytes = databaseBytes
        self.peakResidentBytes = peakResidentBytes
        self.cpuSeconds = cpuSeconds
    }
}

public struct BenchmarkRun: Codable, Sendable, Equatable {
    public let workload: BenchmarkWorkload
    public let samples: LatencySamples
    public let reconciliation: BenchmarkReconciliation
    public let importPartitionSizes: [Int]
    public let importedEventCount: Int
    public let liveTrafficEventCount: Int
    public let unrecoverableFailureCount: Int
    public let elapsedSeconds: Double
    public var environment: BenchmarkEnvironment?
    public var sqliteIntegrity: String?
    public var recoveryVerified: Bool?

    public init(
        workload: BenchmarkWorkload,
        samples: LatencySamples,
        reconciliation: BenchmarkReconciliation,
        importPartitionSizes: [Int],
        importedEventCount: Int,
        liveTrafficEventCount: Int,
        unrecoverableFailureCount: Int,
        elapsedSeconds: Double,
        environment: BenchmarkEnvironment? = nil,
        sqliteIntegrity: String? = nil,
        recoveryVerified: Bool? = nil
    ) {
        self.workload = workload
        self.samples = samples
        self.reconciliation = reconciliation
        self.importPartitionSizes = importPartitionSizes
        self.importedEventCount = importedEventCount
        self.liveTrafficEventCount = liveTrafficEventCount
        self.unrecoverableFailureCount = unrecoverableFailureCount
        self.elapsedSeconds = elapsedSeconds
        self.environment = environment
        self.sqliteIntegrity = sqliteIntegrity
        self.recoveryVerified = recoveryVerified
    }
}

public enum DatabaseDecision: String, Codable, Sendable {
    case retainSQLiteProvisionally
    case requirePostgreSQL
}
