import Darwin
import Foundation

/// Records the machine and runtime facts that make a benchmark result reproducible.
public struct BenchmarkEnvironmentCollector: Sendable {
    public init() {}

    public func collect(
        receipt: PreparedRuntimeReceipt,
        manifest: RuntimeManifest,
        databaseURL: URL
    ) -> BenchmarkEnvironment {
        BenchmarkEnvironment(
            hardwareModel: Self.sysctlString("hw.model") ?? "unknown",
            architecture: Self.sysctlString("hw.machine") ?? "unknown",
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            swiftVersion: Self.swiftVersion,
            pythonVersion: receipt.pythonVersion,
            synapseVersion: receipt.synapseVersion,
            requirementsLockSHA256: manifest.requirementsLockSHA256,
            databaseBytes: Self.fileSize(at: databaseURL),
            peakResidentBytes: Self.peakResidentBytes(),
            cpuSeconds: Self.cpuSeconds()
        )
    }

    private static var swiftVersion: String {
        #if swift(>=6.2)
        "6.2"
        #else
        "unknown"
        #endif
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    static func fileSize(at url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Peak resident set size of this process, reported by the kernel in bytes.
    static func peakResidentBytes() -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return UInt64(usage.ru_maxrss)
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }
}
