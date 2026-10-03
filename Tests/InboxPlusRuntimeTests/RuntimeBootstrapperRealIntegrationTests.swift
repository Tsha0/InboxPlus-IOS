import Darwin
import Foundation
import Testing
@testable import InboxPlusRuntime

@Test(.enabled(if: ProcessInfo.processInfo.environment["INBOXPLUS_RUNTIME_PYTHON"] != nil))
func realBootstrapCreatesAndVerifiesPinnedSynapseRuntime() async throws {
    // Break caught: mocked command boundaries hide incompatibility with the concrete lock or real Synapse packaging.
    let pythonPath = try #require(ProcessInfo.processInfo.environment["INBOXPLUS_RUNTIME_PYTHON"])
    let cacheDirectory = try darwinUserCacheDirectory()
    let testRoot = cacheDirectory.appendingPathComponent("InboxPlusRuntimeTests", isDirectory: true)
    let canonicalTestRoot = try canonicalFileURL(cacheDirectory)
        .appendingPathComponent("InboxPlusRuntimeTests", isDirectory: true)
    let disposableProfile = testRoot.appendingPathComponent("bootstrap-real", isDirectory: true)
    try? FileManager.default.removeItem(at: disposableProfile)
    defer { try? FileManager.default.removeItem(at: disposableProfile) }

    let paths = try RuntimePaths(root: canonicalTestRoot, profileName: "bootstrap-real")
    let sourceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let manifest = try RuntimeManifest.load(
        from: sourceRoot.appendingPathComponent("Runtime/Synapse/runtime-manifest.json")
    )
    let requirementsLock = sourceRoot.appendingPathComponent("Runtime/Synapse/requirements.lock")

    let receipt = try await RuntimeBootstrapper(requirementsLock: requirementsLock).bootstrap(
        python: URL(fileURLWithPath: pythonPath),
        manifest: manifest,
        paths: paths
    )
    let verifiedReceipt = try await RuntimeBootstrapper(requirementsLock: requirementsLock).bootstrap(
        python: URL(fileURLWithPath: pythonPath),
        manifest: manifest,
        paths: paths
    )

    #expect(receipt.pythonVersion.hasPrefix("3.12."))
    #expect(receipt.synapseVersion == "1.158.0")
    #expect(receipt.requirementsLockSHA256 == manifest.requirementsLockSHA256)
    #expect(receipt.installedPackages["matrix-synapse"] == "1.158.0")
    #expect(verifiedReceipt == receipt)
}

private func canonicalFileURL(_ url: URL) throws -> URL {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard Darwin.realpath(url.path, &buffer) != nil else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let pathBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    let canonicalPath = String(decoding: pathBytes, as: UTF8.self)
    let physicalDataVolumeURL = URL(
        fileURLWithPath: "/System/Volumes/Data" + canonicalPath,
        isDirectory: true
    )
    guard FileManager.default.fileExists(atPath: physicalDataVolumeURL.path) else {
        throw RealBootstrapTestError.missingPhysicalCacheDirectory(physicalDataVolumeURL)
    }
    return physicalDataVolumeURL
}

private func darwinUserCacheDirectory() throws -> URL {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/getconf")
    process.arguments = ["DARWIN_USER_CACHE_DIR"]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          let path = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !path.isEmpty
    else {
        throw RealBootstrapTestError.missingDarwinUserCacheDirectory
    }
    return URL(fileURLWithPath: path, isDirectory: true)
}

private enum RealBootstrapTestError: Error {
    case missingDarwinUserCacheDirectory
    case missingPhysicalCacheDirectory(URL)
}
