import CryptoKit
import Foundation

/// Copies only software from the app into a private profile. Account data is created separately.
public struct BundledRuntime: Sendable {
    public let packageRoot: URL

    public init(packageRoot: URL) { self.packageRoot = packageRoot }

    public var pythonDirectory: URL { packageRoot.appendingPathComponent("Runtime/Python") }
    public var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: pythonDirectory.appendingPathComponent("bin/python3.12").path)
    }

    @discardableResult
    public func install(paths: RuntimePaths) throws -> PreparedRuntimeReceipt {
        let fm = FileManager.default
        let manifest = try RuntimeManifest.load(from: packageRoot.appendingPathComponent("Runtime/Synapse/runtime-manifest.json"))
        let requirements = try Data(contentsOf: packageRoot.appendingPathComponent("Runtime/Synapse/requirements.lock"))
        let hash = SHA256.hash(data: requirements).map { String(format: "%02x", $0) }.joined()
        guard hash == manifest.requirementsLockSHA256 else {
            throw RuntimeManifestError.preparedRuntimeMismatch("bundled requirements checksum mismatch")
        }
        let expected = try RuntimeBootstrapper.parsePinnedPackages(requirements)
        let receiptURL = paths.runtime.appendingPathComponent(RuntimeBootstrapper.receiptName)
        if fm.fileExists(atPath: paths.runtime.path) {
            let receipt = try manifest.validatePreparedRuntime(at: receiptURL)
            guard receipt.installedPackages == expected else {
                throw RuntimeManifestError.preparedRuntimeMismatch("installed packages differ from the lock")
            }
            return receipt
        }
        guard isAvailable else {
            throw RuntimeManifestError.preparedRuntimeMismatch("the app is missing its bundled Python runtime; rebuild or reinstall Inbox+")
        }
        let stage = paths.profile.appendingPathComponent(".runtime-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let pythonRoot = stage.appendingPathComponent("venv")
        try fm.copyItem(at: pythonDirectory, to: pythonRoot)
        // Portable Python uses relative links internally; reject links escaping the copied tree.
        if let enumerator = fm.enumerator(at: pythonRoot, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let item as URL in enumerator {
                if try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    guard item.resolvingSymlinksInPath().path.hasPrefix(pythonRoot.path + "/") else {
                        throw RuntimeManifestError.preparedRuntimeMismatch("runtime link escapes its installation")
                    }
                }
            }
        }
        let python = pythonRoot.appendingPathComponent("bin/python3.12")
        let process = Process()
        process.executableURL = python
        process.arguments = ["-I", "-c", """
        import importlib.metadata as m, json, platform, re
        import synapse, synapse.synapse_rust
        packages = {re.sub(r'[._-]+', '-', d.metadata['Name'].lower()): d.version for d in m.distributions()}
        print(json.dumps({'version': platform.python_version(), 'packages': packages}))
        """]
        process.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        struct Inventory: Decodable { let version: String; let packages: [String: String] }
        guard process.terminationStatus == 0, let inventory = try? JSONDecoder().decode(Inventory.self, from: data),
              inventory.packages == expected else {
            throw RuntimeManifestError.preparedRuntimeMismatch("bundled runtime cannot load the pinned Synapse packages")
        }
        let receipt = PreparedRuntimeReceipt(
            pythonExecutable: paths.runtime.appendingPathComponent("venv/bin/python3.12").path,
            pythonVersion: inventory.version,
            synapseVersion: manifest.synapseVersion,
            requirementsLockSHA256: hash,
            installedPackages: inventory.packages,
            createdAt: Date()
        )
        try requirements.write(to: stage.appendingPathComponent("requirements.lock"), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.appendingPathComponent("requirements.lock").path)
        let receiptData = try JSONEncoder().encode(receipt)
        _ = try manifest.validatePreparedRuntime(data: receiptData)
        try receiptData.write(to: stage.appendingPathComponent(RuntimeBootstrapper.receiptName), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.appendingPathComponent(RuntimeBootstrapper.receiptName).path)
        try fm.moveItem(at: stage, to: paths.runtime)
        return receipt
    }
}
