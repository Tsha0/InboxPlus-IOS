import Foundation
import Testing
@testable import InboxPlusRuntime

@Test func manifestRequiresPinnedSynapseAndPythonMinor() throws {
    let manifest = try RuntimeManifest.load(from: fixture("valid-runtime-manifest.json"))
    #expect(manifest.pythonMinor == "3.12")
    #expect(manifest.synapseVersion == "1.158.0")
}

@Test func shippedManifestMatchesTheCheckedInRequirementsLock() throws {
    let manifest = try RuntimeManifest.load(from: runtimeArtifact("runtime-manifest.json"))
    #expect(try sha256(of: runtimeArtifact("requirements.lock")) == manifest.requirementsLockSHA256)
}

@Test func preparedRuntimeReceiptMatchesTheManifest() throws {
    let manifest = try RuntimeManifest.load(from: runtimeArtifact("runtime-manifest.json"))
    let receipt = try manifest.validatePreparedRuntime(at: receiptFixture(
        pythonVersion: "3.12.7",
        synapseVersion: manifest.synapseVersion,
        requirementsLockSHA256: manifest.requirementsLockSHA256
    ))
    #expect(receipt.pythonVersion == "3.12.7")
}

@Test(arguments: ["3.11.7", "3.12.", "3.12.dev"])
func preparedRuntimeReceiptRequiresNumericPythonPatch(_ pythonVersion: String) throws {
    let manifest = try RuntimeManifest.load(from: runtimeArtifact("runtime-manifest.json"))
    #expect(throws: RuntimeManifestError.self) {
        try manifest.validatePreparedRuntime(at: receiptFixture(
            pythonVersion: pythonVersion,
            synapseVersion: manifest.synapseVersion,
            requirementsLockSHA256: manifest.requirementsLockSHA256
        ))
    }
}

private func fixture(_ name: String) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("InboxPlusRuntimeTests", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let url = directory.appendingPathComponent(name)
    let contents = """
    {"schemaVersion":1,"pythonMinor":"3.12","synapseVersion":"1.158.0","requirementsLockSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
    """
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func runtimeArtifact(_ name: String) -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("Runtime/Synapse/\(name)")
}

private func receiptFixture(
    pythonVersion: String,
    synapseVersion: String,
    requirementsLockSHA256: String
) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("InboxPlusRuntimeTests", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let url = directory.appendingPathComponent("runtime-receipt-\(UUID().uuidString).json")
    let contents = """
    {"pythonExecutable":"/opt/homebrew/opt/python@3.12/bin/python3.12","pythonVersion":"\(pythonVersion)","synapseVersion":"\(synapseVersion)","requirementsLockSHA256":"\(requirementsLockSHA256)","installedPackages":{"matrix-synapse":"1.158.0"},"createdAt":0}
    """
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func sha256(of url: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    process.arguments = ["-a", "256", url.path]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw RuntimeManifestTestError.checksumFailed
    }
    guard let checksum = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .split(whereSeparator: \.isWhitespace)
        .first
    else {
        throw RuntimeManifestTestError.missingChecksum
    }
    return String(checksum)
}

private enum RuntimeManifestTestError: Error {
    case checksumFailed
    case missingChecksum
}
