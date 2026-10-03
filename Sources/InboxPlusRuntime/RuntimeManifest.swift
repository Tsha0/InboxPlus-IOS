import Foundation

public struct RuntimeManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let pythonMinor: String
    public let synapseVersion: String
    public let requirementsLockSHA256: String

    public static func load(from url: URL) throws -> RuntimeManifest {
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url.standardizedFileURL))
        try manifest.validate()
        return manifest
    }

    public func validatePreparedRuntime(at url: URL) throws -> PreparedRuntimeReceipt {
        try validatePreparedRuntime(data: Data(contentsOf: url.standardizedFileURL))
    }

    public func validatePreparedRuntime(data: Data) throws -> PreparedRuntimeReceipt {
        let receipt = try JSONDecoder().decode(PreparedRuntimeReceipt.self, from: data)

        let pythonVersionComponents = receipt.pythonVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard pythonVersionComponents.count == 3,
              pythonVersionComponents[0] == "3",
              pythonVersionComponents[1] == "12",
              !pythonVersionComponents[2].isEmpty,
              pythonVersionComponents[2].allSatisfy({ $0.isASCII && $0.isNumber })
        else {
            throw RuntimeManifestError.preparedRuntimeMismatch("Python \(receipt.pythonVersion) is not on the \(pythonMinor) line")
        }
        guard receipt.synapseVersion == synapseVersion else {
            throw RuntimeManifestError.preparedRuntimeMismatch("Synapse \(receipt.synapseVersion) does not match \(synapseVersion)")
        }
        guard receipt.requirementsLockSHA256 == requirementsLockSHA256 else {
            throw RuntimeManifestError.preparedRuntimeMismatch("requirements.lock checksum does not match the manifest")
        }
        return receipt
    }

    private func validate() throws {
        guard schemaVersion == 1 else {
            throw RuntimeManifestError.unsupportedSchemaVersion(schemaVersion)
        }
        guard pythonMinor == "3.12" else {
            throw RuntimeManifestError.unsupportedPythonMinor(pythonMinor)
        }
        guard synapseVersion == "1.158.0" else {
            throw RuntimeManifestError.unsupportedSynapseVersion(synapseVersion)
        }
        guard requirementsLockSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw RuntimeManifestError.invalidRequirementsLockSHA256(requirementsLockSHA256)
        }
    }
}

public struct PreparedRuntimeReceipt: Codable, Sendable, Equatable {
    public let pythonExecutable: String
    public let pythonVersion: String
    public let synapseVersion: String
    public let requirementsLockSHA256: String
    public let installedPackages: [String: String]
    public let createdAt: Date

    public init(
        pythonExecutable: String,
        pythonVersion: String,
        synapseVersion: String,
        requirementsLockSHA256: String,
        installedPackages: [String: String],
        createdAt: Date
    ) {
        self.pythonExecutable = pythonExecutable
        self.pythonVersion = pythonVersion
        self.synapseVersion = synapseVersion
        self.requirementsLockSHA256 = requirementsLockSHA256
        self.installedPackages = installedPackages
        self.createdAt = createdAt
    }
}

public enum RuntimeManifestError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case unsupportedPythonMinor(String)
    case unsupportedSynapseVersion(String)
    case invalidRequirementsLockSHA256(String)
    case preparedRuntimeMismatch(String)
}
