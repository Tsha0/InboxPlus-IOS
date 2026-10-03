import CryptoKit
import Darwin
import Foundation

@_silgen_name("posix_spawn_file_actions_addfchdir_np")
private func inboxplus_spawn_file_actions_addfchdir(
    _ actions: UnsafeMutablePointer<posix_spawn_file_actions_t?>,
    _ descriptor: Int32
) -> Int32

struct RuntimeProcessRequest: Sendable, Equatable {
    struct InheritedDescriptor: Sendable, Equatable {
        enum Destination: Sendable, Equatable {
            case argument(Int)
        }

        let source: Int32
        let preferredTarget: Int32
        let destination: Destination
    }

    let executable: URL
    let relativeExecutable: String?
    let arguments: [String]
    let environment: [String: String]
    let workingDirectoryDescriptor: Int32
    let expectedExecutableIdentity: Int32?
    let inheritedDescriptors: [InheritedDescriptor]

    init(
        executable: URL,
        relativeExecutable: String?,
        arguments: [String],
        environment: [String: String],
        workingDirectoryDescriptor: Int32,
        expectedExecutableIdentity: Int32? = nil,
        inheritedDescriptors: [InheritedDescriptor]
    ) {
        self.executable = executable
        self.relativeExecutable = relativeExecutable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryDescriptor = workingDirectoryDescriptor
        self.expectedExecutableIdentity = expectedExecutableIdentity
        self.inheritedDescriptors = inheritedDescriptors
    }
}

struct RuntimeProcessOutput: Sendable, Equatable {
    let status: Int32
    let standardOutput: String
    let standardError: String

    static let success = RuntimeProcessOutput(status: 0, standardOutput: "", standardError: "")
}

typealias RuntimeProcessRunner = @Sendable (RuntimeProcessRequest) async throws -> RuntimeProcessOutput
enum RuntimeFilesystemEvent: Sendable, Equatable { case pythonValidated, receiptOpened }
typealias RuntimeFilesystemEventHandler = @Sendable (RuntimeFilesystemEvent) throws -> Void

struct RuntimeWaitAttempt: Sendable, Equatable {
    let result: pid_t
    let status: Int32
    let error: Int32
}

enum RuntimeChildWaiter {
    static func wait(
        for child: pid_t,
        wait: (pid_t) -> RuntimeWaitAttempt,
        terminate: (pid_t, Int32) -> Int32
    ) throws -> Int32 {
        while true {
            let attempt = wait(child)
            if attempt.result == child { return attempt.status }
            if attempt.result == -1, attempt.error == EINTR { continue }

            let originalError = attempt.error == 0 ? EIO : attempt.error
            _ = terminate(child, SIGKILL)
            while true {
                let reap = wait(child)
                if reap.result == child || (reap.result == -1 && reap.error == ECHILD) {
                    break
                }
                if reap.result == -1, reap.error == EINTR { continue }
                break
            }
            throw POSIXError(POSIXErrorCode(rawValue: originalError) ?? .EIO)
        }
    }
}

public struct RuntimeBootstrapper: Sendable {
    public static let directoryPermissions = 0o700
    public static let receiptPermissions = 0o600

    fileprivate static let runtimeLockName = "requirements.lock"
    public static let receiptName = "prepared-runtime.json"
    private static let pythonFactsScript = """
    import json, pathlib, sys
    print(json.dumps({
        "implementation": sys.implementation.name,
        "version": ".".join(map(str, sys.version_info[:3])),
        "executable": sys.executable,
        "executableRealPath": str(pathlib.Path(sys.executable).resolve()),
        "prefix": sys.prefix,
        "basePrefix": sys.base_prefix,
    }, sort_keys=True))
    """
    private static let knownSynapse1158UnsupportedVersionStderr = """
    usage: synapse_homeserver [-h] [-c CONFIG_FILE] [--no-secrets-in-config]
                              [--generate-config | --generate-missing-configs | --generate-missing-and-run]
                              [-H SERVER_NAME] [--report-stats {yes,no}]
                              [--config-directory DIRECTORY]
                              [--data-directory DIRECTORY] [--open-private-ports]
                              [--enable-metrics] [-D] [--print-pidfile]
                              [--manhole PORT] [-d SQLITE_DATABASE_PATH] [-n]
                              [--enable-registration]
    synapse_homeserver: error: unrecognized arguments: --version
    """

    public let requirementsLock: URL
    private let brewExecutable: URL
    private let environment: [String: String]
    private let processRunner: RuntimeProcessRunner
    private let filesystemEvent: RuntimeFilesystemEventHandler
    private let now: @Sendable () -> Date

    public init(requirementsLock: URL) {
        self.init(
            requirementsLock: requirementsLock,
            brewExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            hostEnvironment: ProcessInfo.processInfo.environment,
            processRunner: Self.runSystemProcess,
            filesystemEvent: { _ in },
            now: Date.init
        )
    }

    init(
        requirementsLock: URL,
        brewExecutable: URL,
        hostEnvironment: [String: String],
        processRunner: @escaping RuntimeProcessRunner,
        filesystemEvent: @escaping RuntimeFilesystemEventHandler = { _ in },
        now: @escaping @Sendable () -> Date
    ) {
        self.requirementsLock = requirementsLock.standardizedFileURL
        self.brewExecutable = brewExecutable.standardizedFileURL
        environment = Self.sanitizedEnvironment(from: hostEnvironment)
        self.processRunner = processRunner
        self.filesystemEvent = filesystemEvent
        self.now = now
    }

    func withTestDependencies(
        brewExecutable: URL,
        hostEnvironment: [String: String],
        processRunner: @escaping RuntimeProcessRunner,
        filesystemEvent: @escaping RuntimeFilesystemEventHandler,
        now: @escaping @Sendable () -> Date
    ) -> RuntimeBootstrapper {
        RuntimeBootstrapper(
            requirementsLock: requirementsLock,
            brewExecutable: brewExecutable,
            hostEnvironment: hostEnvironment,
            processRunner: processRunner,
            filesystemEvent: filesystemEvent,
            now: now
        )
    }

    public func bootstrap(
        python: URL,
        manifest: RuntimeManifest,
        paths: RuntimePaths
    ) async throws -> PreparedRuntimeReceipt {
        let python = python.standardizedFileURL
        guard python.isFileURL, FileManager.default.isExecutableFile(atPath: python.path) else {
            throw RuntimeBootstrapError.pythonNotExecutable(python)
        }
        guard requirementsLock.isFileURL else {
            throw RuntimeBootstrapError.nonFileRequirementsLock(requirementsLock)
        }

        let bootstrapDirectory = try OwnedDescriptor.openDirectory(
            requirementsLock.deletingLastPathComponent()
        )
        let homebrewPrefix = try await trustedHomebrewPythonPrefix(
            workingDirectoryDescriptor: bootstrapDirectory.rawValue,
            resourceLifetime: RuntimeProcessResourceLifetime([bootstrapDirectory])
        )
        let validatedPython = try Self.validateTrustedPythonExecutable(
            python,
            beneath: homebrewPrefix
        )
        try filesystemEvent(.pythonValidated)
        let baseFacts = try await inspectBasePython(
            python,
            validatedPython: validatedPython,
            manifest: manifest
        )
        let lockData = try Self.readRegularFileNoFollow(at: requirementsLock)
        let actualLockSHA256 = Self.sha256(lockData)
        guard actualLockSHA256 == manifest.requirementsLockSHA256 else {
            throw RuntimeBootstrapError.lockChecksumMismatch(
                expected: manifest.requirementsLockSHA256,
                actual: actualLockSHA256
            )
        }
        let expectedPackages = try Self.parsePinnedPackages(lockData)

        let filesystem = try SecureRuntimeFilesystem.openOrCreate(paths: paths)
        if filesystem.receiptExists {
            let receipt = try filesystem.readAndValidateReceipt(
                manifest: manifest,
                event: filesystemEvent
            )
            try filesystem.validateRuntimeLock(expected: lockData)
            return try await verifyExistingRuntime(
                baseFacts: baseFacts,
                receipt: receipt,
                manifest: manifest,
                expectedPackages: expectedPackages,
                filesystem: filesystem
            )
        }
        guard filesystem.runtimeWasCreated else {
            throw RuntimeBootstrapError.existingRuntimeDrift("runtime directory exists without a prepared-runtime receipt")
        }

        try filesystem.writeRuntimeLock(lockData)
        let authenticatedRuntimeLock = try filesystem.openRuntimeLock(expected: lockData)
        try filesystem.validateIdentity()

        let virtualEnvironment = paths.runtime.appendingPathComponent("venv", isDirectory: true)
        let runtimeBootstrapPython = try validatedPython.snapshot.link(
            into: filesystem.runtimeDirectoryDescriptor
        )
        try await runChecked(
            executable: python,
            relativeExecutable: runtimeBootstrapPython.name,
            arguments: ["-I", "-m", "venv", "venv"],
            workingDirectoryDescriptor: filesystem.runtimeDirectoryDescriptor,
            inheritedDescriptors: [],
            expectedExecutableIdentity: validatedPython.descriptor.rawValue,
            resourceLifetime: RuntimeProcessResourceLifetime([
                validatedPython.descriptor,
                runtimeBootstrapPython,
            ]),
            filesystem: filesystem
        )

        let virtualenvPython = virtualEnvironment.appendingPathComponent("bin/python", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: virtualenvPython.path) else {
            throw RuntimeBootstrapError.missingRuntimeExecutable(virtualenvPython)
        }
        let runtimeFacts = try await inspectRuntimePython(
            virtualenvPython,
            virtualEnvironment: virtualEnvironment,
            baseFacts: baseFacts,
            filesystem: filesystem
        )
        guard runtimeFacts.version == baseFacts.version else {
            throw RuntimeBootstrapError.existingRuntimeDrift(
                "virtualenv Python \(runtimeFacts.version) does not match bootstrap Python \(baseFacts.version)"
            )
        }

        try await runChecked(
            executable: virtualenvPython,
            relativeExecutable: "venv/bin/python",
            arguments: [
                "-I", "-m", "pip", "install",
                "--disable-pip-version-check",
                "--no-input",
                "--requirement", "authenticated-lock-descriptor",
            ],
            workingDirectoryDescriptor: filesystem.runtimeDirectoryDescriptor,
            inheritedDescriptors: [
                .init(
                    source: authenticatedRuntimeLock.rawValue,
                    preferredTarget: 20,
                    destination: .argument(7)
                ),
            ],
            resourceLifetime: RuntimeProcessResourceLifetime([authenticatedRuntimeLock]),
            filesystem: filesystem
        )

        let installedPackages = try await frozenPackages(
            using: virtualenvPython,
            filesystem: filesystem
        )
        guard installedPackages == expectedPackages else {
            throw RuntimeBootstrapError.packageDrift(expected: expectedPackages, actual: installedPackages)
        }

        let synapseExecutable = virtualEnvironment.appendingPathComponent("bin/synapse_homeserver", isDirectory: false)
        try await verifySynapse(
            executable: synapseExecutable,
            using: virtualenvPython,
            expectedVersion: manifest.synapseVersion,
            filesystem: filesystem
        )

        let receipt = PreparedRuntimeReceipt(
            pythonExecutable: baseFacts.executableRealPath,
            pythonVersion: baseFacts.version,
            synapseVersion: manifest.synapseVersion,
            requirementsLockSHA256: manifest.requirementsLockSHA256,
            installedPackages: installedPackages,
            createdAt: now()
        )
        try filesystem.validateIdentity()
        try filesystem.writeReceipt(receipt)
        try filesystem.validateIdentity()
        let validatedReceipt = try filesystem.readAndValidateReceipt(
            manifest: manifest,
            event: filesystemEvent
        )
        try filesystem.validateIdentity()
        guard validatedReceipt == receipt else {
            throw RuntimeBootstrapError.existingRuntimeDrift("published receipt did not round-trip exactly")
        }
        return validatedReceipt
    }

    private func verifyExistingRuntime(
        baseFacts: PythonFacts,
        receipt: PreparedRuntimeReceipt,
        manifest: RuntimeManifest,
        expectedPackages: [String: String],
        filesystem: SecureRuntimeFilesystem
    ) async throws -> PreparedRuntimeReceipt {
        try filesystem.validateIdentity()
        guard receipt.pythonExecutable == baseFacts.executableRealPath else {
            throw RuntimeBootstrapError.existingRuntimeDrift(
                "receipt interpreter \(receipt.pythonExecutable) does not match canonical interpreter \(baseFacts.executableRealPath)"
            )
        }
        guard receipt.pythonVersion == baseFacts.version else {
            throw RuntimeBootstrapError.existingRuntimeDrift(
                "receipt Python \(receipt.pythonVersion) does not match interpreter Python \(baseFacts.version)"
            )
        }
        guard receipt.installedPackages == expectedPackages else {
            throw RuntimeBootstrapError.packageDrift(expected: expectedPackages, actual: receipt.installedPackages)
        }

        let virtualEnvironment = filesystem.paths.runtime.appendingPathComponent("venv", isDirectory: true)
        let virtualenvPython = virtualEnvironment.appendingPathComponent("bin/python", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: virtualenvPython.path) else {
            throw RuntimeBootstrapError.missingRuntimeExecutable(virtualenvPython)
        }
        let runtimeFacts = try await inspectRuntimePython(
            virtualenvPython,
            virtualEnvironment: virtualEnvironment,
            baseFacts: baseFacts,
            filesystem: filesystem
        )
        guard runtimeFacts.version == receipt.pythonVersion else {
            throw RuntimeBootstrapError.existingRuntimeDrift(
                "runtime Python \(runtimeFacts.version) does not match receipt Python \(receipt.pythonVersion)"
            )
        }

        let installedPackages = try await frozenPackages(using: virtualenvPython, filesystem: filesystem)
        guard installedPackages == expectedPackages else {
            throw RuntimeBootstrapError.packageDrift(expected: expectedPackages, actual: installedPackages)
        }
        guard installedPackages == receipt.installedPackages else {
            throw RuntimeBootstrapError.packageDrift(expected: receipt.installedPackages, actual: installedPackages)
        }

        let synapseExecutable = virtualEnvironment.appendingPathComponent("bin/synapse_homeserver", isDirectory: false)
        try await verifySynapse(
            executable: synapseExecutable,
            using: virtualenvPython,
            expectedVersion: receipt.synapseVersion,
            filesystem: filesystem
        )
        try filesystem.validateIdentity()
        return receipt
    }

    private func trustedHomebrewPythonPrefix(
        workingDirectoryDescriptor: Int32,
        resourceLifetime: RuntimeProcessResourceLifetime
    ) async throws -> URL {
        let output = try await runChecked(
            executable: brewExecutable,
            relativeExecutable: nil,
            arguments: ["--prefix", "python@3.12"],
            workingDirectoryDescriptor: workingDirectoryDescriptor,
            inheritedDescriptors: [],
            resourceLifetime: resourceLifetime,
            filesystem: nil
        )
        let path = output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else {
            throw RuntimeBootstrapError.invalidHomebrewPrefix(path)
        }
        return try Self.canonicalExistingURL(URL(fileURLWithPath: path, isDirectory: true))
    }

    private func inspectBasePython(
        _ executable: URL,
        validatedPython: ValidatedPython,
        manifest: RuntimeManifest
    ) async throws -> PythonFacts {
        let facts = try await inspectPython(
            executable,
            relativeExecutable: validatedPython.snapshot.name,
            omitSite: true,
            workingDirectoryDescriptor: validatedPython.snapshot.directoryDescriptor,
            expectedExecutableIdentity: validatedPython.descriptor.rawValue,
            resourceLifetime: RuntimeProcessResourceLifetime([
                validatedPython.descriptor,
                validatedPython.snapshot,
            ]),
            filesystem: nil
        )
        guard facts.implementation == "cpython" else {
            throw RuntimeBootstrapError.unsupportedPythonImplementation(facts.implementation)
        }
        try Self.validateVersion(facts.version, requiredMinor: manifest.pythonMinor)

        return PythonFacts(
            implementation: facts.implementation,
            version: facts.version,
            executable: facts.executable,
            executableRealPath: validatedPython.canonicalURL.path,
            prefix: facts.prefix,
            basePrefix: facts.basePrefix
        )
    }

    private func inspectRuntimePython(
        _ executable: URL,
        virtualEnvironment: URL,
        baseFacts: PythonFacts,
        filesystem: SecureRuntimeFilesystem
    ) async throws -> PythonFacts {
        let facts = try await inspectPython(
            executable,
            relativeExecutable: "venv/bin/python",
            omitSite: false,
            workingDirectoryDescriptor: filesystem.runtimeDirectoryDescriptor,
            expectedExecutableIdentity: nil,
            filesystem: filesystem
        )
        guard facts.implementation == "cpython" else {
            throw RuntimeBootstrapError.unsupportedPythonImplementation(facts.implementation)
        }
        let runtimeBasePrefix = try Self.canonicalExistingURL(URL(fileURLWithPath: facts.basePrefix))
        let expectedBasePrefix = try Self.canonicalExistingURL(URL(fileURLWithPath: baseFacts.basePrefix))
        guard runtimeBasePrefix == expectedBasePrefix,
              try Self.sameExistingFile(
                URL(fileURLWithPath: facts.prefix, isDirectory: true),
                virtualEnvironment
              ),
              facts.executableRealPath == baseFacts.executableRealPath
        else {
            throw RuntimeBootstrapError.invalidPythonProvenance("virtualenv provenance does not match the Homebrew base interpreter")
        }
        return facts
    }

    private func inspectPython(
        _ executable: URL,
        relativeExecutable: String?,
        omitSite: Bool,
        workingDirectoryDescriptor: Int32,
        expectedExecutableIdentity: Int32?,
        resourceLifetime: RuntimeProcessResourceLifetime? = nil,
        filesystem: SecureRuntimeFilesystem?
    ) async throws -> PythonFacts {
        let arguments = omitSite
            ? ["-I", "-S", "-c", Self.pythonFactsScript]
            : ["-I", "-c", Self.pythonFactsScript]
        let output = try await runChecked(
            executable: executable,
            relativeExecutable: relativeExecutable,
            arguments: arguments,
            workingDirectoryDescriptor: workingDirectoryDescriptor,
            inheritedDescriptors: [],
            expectedExecutableIdentity: expectedExecutableIdentity,
            resourceLifetime: resourceLifetime,
            filesystem: filesystem
        )
        do {
            return try JSONDecoder().decode(PythonFacts.self, from: Data(output.standardOutput.utf8))
        } catch {
            throw RuntimeBootstrapError.invalidPythonProvenance(
                output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private func frozenPackages(
        using python: URL,
        filesystem: SecureRuntimeFilesystem
    ) async throws -> [String: String] {
        let output = try await runChecked(
            executable: python,
            relativeExecutable: "venv/bin/python",
            arguments: ["-I", "-m", "pip", "freeze", "--all"],
            workingDirectoryDescriptor: filesystem.runtimeDirectoryDescriptor,
            inheritedDescriptors: [],
            filesystem: filesystem
        )
        return try Self.parsePinnedPackages(Data(output.standardOutput.utf8))
    }

    private func verifySynapse(
        executable: URL,
        using python: URL,
        expectedVersion: String,
        filesystem: SecureRuntimeFilesystem
    ) async throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw RuntimeBootstrapError.missingRuntimeExecutable(executable)
        }
        let probe = try await runRaw(
            executable: executable,
            relativeExecutable: "venv/bin/synapse_homeserver",
            arguments: ["--version"],
            workingDirectoryDescriptor: filesystem.runtimeDirectoryDescriptor,
            inheritedDescriptors: [],
            filesystem: filesystem
        )
        let output: RuntimeProcessOutput
        if probe.status == 0 {
            output = probe
        } else if expectedVersion == "1.158.0",
                  probe.status == 2,
                  Self.normalizedDiagnostic(probe.standardError)
                    == Self.normalizedDiagnostic(Self.knownSynapse1158UnsupportedVersionStderr)
        {
            output = try await runChecked(
                executable: python,
                relativeExecutable: "venv/bin/python",
                arguments: ["-I", "-c", "import synapse; print(synapse.__version__)"],
                workingDirectoryDescriptor: filesystem.runtimeDirectoryDescriptor,
                inheritedDescriptors: [],
                filesystem: filesystem
            )
        } else {
            throw RuntimeBootstrapError.commandFailed(
                executable: executable.path,
                arguments: ["--version"],
                status: probe.status,
                standardError: probe.standardError
            )
        }

        let text = Self.combinedOutput(output).trimmingCharacters(in: .whitespacesAndNewlines)
        let punctuation = CharacterSet(charactersIn: "(),:[]")
        let versions = text.split(whereSeparator: \.isWhitespace).compactMap { token -> String? in
            let candidate = String(token).trimmingCharacters(in: punctuation)
            guard candidate.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil else {
                return nil
            }
            return candidate
        }
        guard versions == [expectedVersion] else {
            throw RuntimeBootstrapError.synapseVersionMismatch(expected: expectedVersion, output: text)
        }
    }

    @discardableResult
    private func runChecked(
        executable: URL,
        relativeExecutable: String?,
        arguments: [String],
        workingDirectoryDescriptor: Int32,
        inheritedDescriptors: [RuntimeProcessRequest.InheritedDescriptor],
        expectedExecutableIdentity: Int32? = nil,
        resourceLifetime: RuntimeProcessResourceLifetime? = nil,
        filesystem: SecureRuntimeFilesystem?
    ) async throws -> RuntimeProcessOutput {
        let output = try await runRaw(
            executable: executable,
            relativeExecutable: relativeExecutable,
            arguments: arguments,
            workingDirectoryDescriptor: workingDirectoryDescriptor,
            inheritedDescriptors: inheritedDescriptors,
            expectedExecutableIdentity: expectedExecutableIdentity,
            resourceLifetime: resourceLifetime,
            filesystem: filesystem
        )
        guard output.status == 0 else {
            throw RuntimeBootstrapError.commandFailed(
                executable: executable.path,
                arguments: arguments,
                status: output.status,
                standardError: output.standardError
            )
        }
        return output
    }

    private func runRaw(
        executable: URL,
        relativeExecutable: String?,
        arguments: [String],
        workingDirectoryDescriptor: Int32,
        inheritedDescriptors: [RuntimeProcessRequest.InheritedDescriptor],
        expectedExecutableIdentity: Int32? = nil,
        resourceLifetime: RuntimeProcessResourceLifetime? = nil,
        filesystem: SecureRuntimeFilesystem?
    ) async throws -> RuntimeProcessOutput {
        defer { resourceLifetime?.keepAliveThroughProcessCompletion() }
        try filesystem?.validateIdentity()
        for inherited in inheritedDescriptors {
            guard Darwin.lseek(inherited.source, 0, SEEK_SET) >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        let output = try await processRunner(RuntimeProcessRequest(
            executable: executable,
            relativeExecutable: relativeExecutable,
            arguments: arguments,
            environment: environment,
            workingDirectoryDescriptor: workingDirectoryDescriptor,
            expectedExecutableIdentity: expectedExecutableIdentity,
            inheritedDescriptors: inheritedDescriptors
        ))
        try filesystem?.validateIdentity()
        return output
    }

    private static func validateVersion(_ version: String, requiredMinor: String) throws {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } })
        else {
            throw RuntimeBootstrapError.malformedPythonVersion(version)
        }
        guard version.hasPrefix(requiredMinor + ".") else {
            throw RuntimeBootstrapError.unsupportedPythonVersion(version, requiredMinor: requiredMinor)
        }
    }

    private static func sanitizedEnvironment(from host: [String: String]) -> [String: String] {
        var sanitized = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
        ]
        for key in ["HOME", "TMPDIR"] {
            if let value = host[key], value.hasPrefix("/") {
                sanitized[key] = value
            }
        }
        return sanitized
    }

    private static func readRegularFileNoFollow(at url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            let code = errno == 0 ? EINVAL : errno
            _ = Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            let data = try handle.readToEnd() ?? Data()
            try handle.close()
            return data
        } catch {
            try? handle.close()
            throw error
        }
    }

    static func parsePinnedPackages(_ data: Data) throws -> [String: String] {
        guard let contents = String(data: data, encoding: .utf8) else {
            throw RuntimeBootstrapError.invalidPackageListing("package listing is not UTF-8")
        }
        var packages: [String: String] = [:]
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let components = line.components(separatedBy: "==")
            guard components.count == 2,
                  !components[0].isEmpty,
                  !components[1].isEmpty,
                  components[0].range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
                  components[1].rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            else {
                throw RuntimeBootstrapError.invalidPackageListing(line)
            }
            let name = components[0]
                .lowercased()
                .replacingOccurrences(of: "[._-]+", with: "-", options: .regularExpression)
            guard packages.updateValue(components[1], forKey: name) == nil else {
                throw RuntimeBootstrapError.invalidPackageListing("duplicate normalized package \(name)")
            }
        }
        return packages
    }

    private static func normalizedDiagnostic(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalExistingURL(_ url: URL) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard Darwin.realpath(url.path, &buffer) != nil else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
    }

    private static func sameExistingFile(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let leftDescriptor = Darwin.open(lhs.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard leftDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(leftDescriptor) }
        var leftMetadata = stat()
        guard Darwin.fstat(leftDescriptor, &leftMetadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let rightDescriptor = Darwin.open(rhs.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rightDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(rightDescriptor) }
        var rightMetadata = stat()
        guard Darwin.fstat(rightDescriptor, &rightMetadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return leftMetadata.st_dev == rightMetadata.st_dev
            && leftMetadata.st_ino == rightMetadata.st_ino
    }

    private static func validateTrustedPythonExecutable(
        _ selected: URL,
        beneath homebrewPrefix: URL
    ) throws -> ValidatedPython {
        let canonical = try canonicalExistingURL(selected)
        guard isContained(canonical, by: homebrewPrefix) else {
            throw RuntimeBootstrapError.pythonNotFromHomebrew312(selected)
        }
        let descriptor = Darwin.open(canonical.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw RuntimeBootstrapError.invalidPythonExecutable(canonical)
        }
        let ownedDescriptor = OwnedDescriptor(descriptor)

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == 0 || metadata.st_uid == Darwin.geteuid(),
              metadata.st_mode & 0o022 == 0,
              metadata.st_mode & 0o111 != 0
        else {
            throw RuntimeBootstrapError.invalidPythonExecutable(canonical)
        }
        var magic = [UInt8](repeating: 0, count: 4)
        guard Darwin.pread(descriptor, &magic, magic.count, 0) == magic.count,
              [
                  [0xfe, 0xed, 0xfa, 0xce], [0xce, 0xfa, 0xed, 0xfe],
                  [0xfe, 0xed, 0xfa, 0xcf], [0xcf, 0xfa, 0xed, 0xfe],
                  [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
                  [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca],
              ].contains(magic)
        else {
            throw RuntimeBootstrapError.invalidPythonExecutable(canonical)
        }
        let snapshot = try ValidatedExecutableSnapshot.create(
            from: canonical,
            expectedIdentity: ownedDescriptor.rawValue
        )
        return ValidatedPython(
            canonicalURL: canonical,
            descriptor: ownedDescriptor,
            snapshot: snapshot
        )
    }

    private static func isContained(_ child: URL, by root: URL) -> Bool {
        let child = child.standardizedFileURL.path
        let root = root.standardizedFileURL.path
        return child == root || child.hasPrefix(root + "/")
    }

    private static func combinedOutput(_ output: RuntimeProcessOutput) -> String {
        if output.standardOutput.isEmpty { return output.standardError }
        if output.standardError.isEmpty { return output.standardOutput }
        return output.standardOutput + "\n" + output.standardError
    }

    static func runSystemProcess(_ request: RuntimeProcessRequest) async throws -> RuntimeProcessOutput {
        let anchoredExecutable = try request.expectedExecutableIdentity.map { expectedDescriptor in
            guard let relativeExecutable = request.relativeExecutable else { throw POSIXError(.EINVAL) }
            return try OwnedDescriptor.openMatchingExecutable(
                parent: request.workingDirectoryDescriptor,
                name: relativeExecutable,
                expected: expectedDescriptor
            )
        }
        defer { _ = anchoredExecutable }
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let stdoutURL = temporaryDirectory.appendingPathComponent("inboxplus-runtime-stdout-\(UUID().uuidString)")
        let stderrURL = temporaryDirectory.appendingPathComponent("inboxplus-runtime-stderr-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }
        try Data().write(to: stdoutURL, options: .withoutOverwriting)
        try Data().write(to: stderrURL, options: .withoutOverwriting)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let stableSources = try request.inheritedDescriptors.map {
            try OwnedDescriptor.duplicate($0.source, minimum: 64)
        }
        let childReservations = try request.inheritedDescriptors.map {
            try OwnedDescriptor.reserveChildDescriptor(preferredMinimum: $0.preferredTarget)
        }
        defer {
            withExtendedLifetime(stableSources) {}
            withExtendedLifetime(childReservations) {}
        }
        var childArguments = request.arguments
        for (inherited, reservation) in zip(request.inheritedDescriptors, childReservations) {
            let childPath = "/dev/fd/\(reservation.rawValue)"
            switch inherited.destination {
            case let .argument(index):
                guard childArguments.indices.contains(index) else { throw POSIXError(.EINVAL) }
                childArguments[index] = childPath
            }
        }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw POSIXError(.EIO)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw POSIXError(.EIO)
        }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
            throw POSIXError(.EIO)
        }
        guard inboxplus_spawn_file_actions_addfchdir(&actions, request.workingDirectoryDescriptor) == 0,
              posix_spawn_file_actions_adddup2(&actions, stdout.fileDescriptor, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stderr.fileDescriptor, STDERR_FILENO) == 0
        else {
            throw POSIXError(.EIO)
        }
        for (stableSource, reservation) in zip(stableSources, childReservations) {
            guard posix_spawn_file_actions_adddup2(
                &actions,
                stableSource.rawValue,
                reservation.rawValue
            ) == 0 else {
                throw POSIXError(.EIO)
            }
        }

        let launchedExecutable: String
        let arguments: [String]
        if let relativeExecutable = request.relativeExecutable {
            launchedExecutable = "./" + relativeExecutable
            arguments = [request.executable.path] + childArguments
        } else {
            launchedExecutable = request.executable.path
            arguments = [launchedExecutable] + childArguments
        }
        let environment = request.environment
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
        var processIdentifier = pid_t()
        let spawnResult = try withMutableCStringArray(arguments) { argumentVector in
            try withMutableCStringArray(environment) { environmentVector in
                posix_spawn(
                    &processIdentifier,
                    launchedExecutable,
                    &actions,
                    &attributes,
                    argumentVector,
                    environmentVector
                )
            }
        }
        guard spawnResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: spawnResult) ?? .EIO)
        }
        let waitStatus = try RuntimeChildWaiter.wait(
            for: processIdentifier,
            wait: { child in
                var status = Int32()
                errno = 0
                let result = Darwin.waitpid(child, &status, 0)
                return RuntimeWaitAttempt(result: result, status: status, error: result == -1 ? errno : 0)
            },
            terminate: { child, signal in Darwin.kill(child, signal) }
        )
        try stdout.synchronize()
        try stderr.synchronize()
        let terminationStatus: Int32
        if waitStatus & 0x7f == 0 {
            terminationStatus = (waitStatus >> 8) & 0xff
        } else {
            terminationStatus = 128 + (waitStatus & 0x7f)
        }
        return RuntimeProcessOutput(
            status: terminationStatus,
            standardOutput: String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self),
            standardError: String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)
        )
    }

    private static func withMutableCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) throws -> Result {
        let storage: [UnsafeMutablePointer<CChar>] = strings.map { strdup($0)! }
        defer { storage.forEach { free($0) } }
        var pointers: [UnsafeMutablePointer<CChar>?] = storage.map { $0 }
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }
}

private struct PythonFacts: Codable, Sendable, Equatable {
    let implementation: String
    let version: String
    let executable: String
    let executableRealPath: String
    let prefix: String
    let basePrefix: String
}

private final class RuntimeProcessResourceLifetime: @unchecked Sendable {
    private let resources: [AnyObject]

    init(_ resources: [AnyObject]) {
        self.resources = resources
    }

    func keepAliveThroughProcessCompletion() {
        withExtendedLifetime(resources) {}
    }
}

private struct ValidatedPython: @unchecked Sendable {
    let canonicalURL: URL
    let descriptor: OwnedDescriptor
    let snapshot: ValidatedExecutableSnapshot
}

private final class OwnedDescriptor: @unchecked Sendable {
    let rawValue: Int32

    init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }

    deinit {
        _ = Darwin.close(rawValue)
    }

    static func openDirectory(_ url: URL) throws -> OwnedDescriptor {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return OwnedDescriptor(descriptor)
    }

    static func duplicate(_ source: Int32, minimum: Int32) throws -> OwnedDescriptor {
        let descriptor = Darwin.fcntl(source, F_DUPFD_CLOEXEC, minimum)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return OwnedDescriptor(descriptor)
    }

    static func reserveChildDescriptor(preferredMinimum: Int32) throws -> OwnedDescriptor {
        let nullDescriptor = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard nullDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(nullDescriptor) }
        return try duplicate(nullDescriptor, minimum: max(3, preferredMinimum))
    }

    static func openMatchingExecutable(parent: Int32, name: String, expected: Int32) throws -> OwnedDescriptor {
        let descriptor = Darwin.openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let owned = OwnedDescriptor(descriptor)
        var actualMetadata = stat()
        var expectedMetadata = stat()
        guard Darwin.fstat(descriptor, &actualMetadata) == 0,
              Darwin.fstat(expected, &expectedMetadata) == 0,
              actualMetadata.st_mode & S_IFMT == S_IFREG,
              actualMetadata.st_mode & 0o111 != 0,
              actualMetadata.st_dev == expectedMetadata.st_dev,
              actualMetadata.st_ino == expectedMetadata.st_ino
        else {
            throw POSIXError(.EACCES)
        }
        return owned
    }
}

private final class ValidatedExecutableSnapshot: @unchecked Sendable {
    let directoryURL: URL
    let directory: OwnedDescriptor
    let name: String
    var directoryDescriptor: Int32 { directory.rawValue }

    private init(directoryURL: URL, directory: OwnedDescriptor, name: String) {
        self.directoryURL = directoryURL
        self.directory = directory
        self.name = name
    }

    deinit {
        _ = Darwin.unlinkat(directory.rawValue, name, 0)
        _ = Darwin.rmdir(directoryURL.path)
    }

    static func create(from source: URL, expectedIdentity: Int32) throws -> ValidatedExecutableSnapshot {
        let template = FileManager.default.temporaryDirectory
            .appendingPathComponent("inboxplus-validated-python.XXXXXX", isDirectory: true)
            .path
        var templateBytes = Array(template.utf8CString)
        guard templateBytes.withUnsafeMutableBufferPointer({ Darwin.mkdtemp($0.baseAddress) }) != nil else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let directoryPath = String(
            decoding: templateBytes.dropLast().map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        do {
            let directory = try OwnedDescriptor.openDirectory(directoryURL)
            let name = "python3.12"
            guard Darwin.linkat(AT_FDCWD, source.path, directory.rawValue, name, 0) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            do {
                _ = try OwnedDescriptor.openMatchingExecutable(
                    parent: directory.rawValue,
                    name: name,
                    expected: expectedIdentity
                )
                return ValidatedExecutableSnapshot(
                    directoryURL: directoryURL,
                    directory: directory,
                    name: name
                )
            } catch {
                _ = Darwin.unlinkat(directory.rawValue, name, 0)
                throw error
            }
        } catch {
            _ = Darwin.rmdir(directoryURL.path)
            throw error
        }
    }

    func link(into targetDirectory: Int32) throws -> AnchoredExecutableLink {
        let targetName = ".inboxplus-bootstrap-python-\(UUID().uuidString)"
        guard Darwin.linkat(directory.rawValue, name, targetDirectory, targetName, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return AnchoredExecutableLink(parent: targetDirectory, name: targetName)
    }
}

private final class AnchoredExecutableLink: @unchecked Sendable {
    let parent: Int32
    let name: String

    init(parent: Int32, name: String) {
        self.parent = parent
        self.name = name
    }

    deinit {
        _ = Darwin.unlinkat(parent, name, 0)
    }
}

private final class SecureRuntimeFilesystem: @unchecked Sendable {
    let paths: RuntimePaths
    let rootWasCreated: Bool
    let profileWasCreated: Bool
    let runtimeWasCreated: Bool
    let receiptExists: Bool
    var runtimeDirectoryDescriptor: Int32 { runtimeDescriptor }

    private let rootDescriptor: Int32
    private let profileDescriptor: Int32
    private let runtimeDescriptor: Int32

    private init(
        paths: RuntimePaths,
        rootDescriptor: Int32,
        profileDescriptor: Int32,
        runtimeDescriptor: Int32,
        rootWasCreated: Bool,
        profileWasCreated: Bool,
        runtimeWasCreated: Bool,
        receiptExists: Bool
    ) {
        self.paths = paths
        self.rootDescriptor = rootDescriptor
        self.profileDescriptor = profileDescriptor
        self.runtimeDescriptor = runtimeDescriptor
        self.rootWasCreated = rootWasCreated
        self.profileWasCreated = profileWasCreated
        self.runtimeWasCreated = runtimeWasCreated
        self.receiptExists = receiptExists
    }

    deinit {
        _ = Darwin.close(runtimeDescriptor)
        _ = Darwin.close(profileDescriptor)
        _ = Darwin.close(rootDescriptor)
    }

    static func openOrCreate(paths: RuntimePaths) throws -> SecureRuntimeFilesystem {
        let (rootDescriptor, rootCreated) = try openOrCreateAbsoluteDirectory(paths.root)
        do {
            try configureDirectory(
                rootDescriptor,
                url: paths.root,
                created: rootCreated
            )
            let (profileDescriptor, profileCreated) = try openOrCreateChild(
                parent: rootDescriptor,
                name: paths.profile.lastPathComponent
            )
            do {
                try configureDirectory(
                    profileDescriptor,
                    url: paths.profile,
                    created: profileCreated
                )
                let (runtimeDescriptor, runtimeCreated) = try openOrCreateChild(
                    parent: profileDescriptor,
                    name: paths.runtime.lastPathComponent
                )
                try configureDirectory(
                    runtimeDescriptor,
                    url: paths.runtime,
                    created: runtimeCreated
                )
                let receiptExists = try entryExists(
                    parent: runtimeDescriptor,
                    name: RuntimeBootstrapper.receiptName
                )
                return SecureRuntimeFilesystem(
                    paths: paths,
                    rootDescriptor: rootDescriptor,
                    profileDescriptor: profileDescriptor,
                    runtimeDescriptor: runtimeDescriptor,
                    rootWasCreated: rootCreated,
                    profileWasCreated: profileCreated,
                    runtimeWasCreated: runtimeCreated,
                    receiptExists: receiptExists
                )
            } catch {
                _ = Darwin.close(profileDescriptor)
                throw error
            }
        } catch {
            _ = Darwin.close(rootDescriptor)
            throw error
        }
    }

    func validateRuntimeLock(expected data: Data) throws {
        _ = try openRuntimeLock(expected: data)
    }

    func writeRuntimeLock(_ data: Data) throws {
        try writeExclusive(
            data,
            name: RuntimeBootstrapper.runtimeLockName,
            permissions: RuntimeBootstrapper.receiptPermissions
        )
    }

    func writeReceipt(_ receipt: PreparedRuntimeReceipt) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)
        let temporaryName = ".prepared-runtime.json.\(UUID().uuidString).tmp"
        try writeExclusive(data, name: temporaryName, permissions: RuntimeBootstrapper.receiptPermissions)
        var published = false
        defer {
            if !published {
                _ = Darwin.unlinkat(runtimeDescriptor, temporaryName, 0)
            }
        }
        guard Darwin.renameat(
            runtimeDescriptor,
            temporaryName,
            runtimeDescriptor,
            RuntimeBootstrapper.receiptName
        ) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.fsync(runtimeDescriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        published = true
    }

    func readAndValidateReceipt(
        manifest: RuntimeManifest,
        event: RuntimeFilesystemEventHandler
    ) throws -> PreparedRuntimeReceipt {
        let name = RuntimeBootstrapper.receiptName
        let url = paths.runtime.appendingPathComponent(name)
        let file = try openRegularEntry(
            name: name,
            url: url,
            expected: RuntimeBootstrapper.receiptPermissions
        )
        var openedMetadata = stat()
        guard Darwin.fstat(file.rawValue, &openedMetadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try event(.receiptOpened)
        guard Darwin.lseek(file.rawValue, 0, SEEK_SET) >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: file.rawValue, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        try compareEntryIdentity(name: name, url: url, opened: openedMetadata)
        return try manifest.validatePreparedRuntime(data: data)
    }

    func openRuntimeLock(expected data: Data) throws -> OwnedDescriptor {
        let name = RuntimeBootstrapper.runtimeLockName
        let url = paths.runtime.appendingPathComponent(name)
        let file = try openRegularEntry(
            name: name,
            url: url,
            expected: RuntimeBootstrapper.receiptPermissions
        )
        var openedMetadata = stat()
        guard Darwin.fstat(file.rawValue, &openedMetadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: file.rawValue, closeOnDealloc: false)
        let actual = try handle.readToEnd() ?? Data()
        try compareEntryIdentity(name: name, url: url, opened: openedMetadata)
        guard actual == data else {
            throw RuntimeBootstrapError.existingRuntimeDrift("profile requirements.lock differs from the authenticated lock")
        }
        guard Darwin.lseek(file.rawValue, 0, SEEK_SET) >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return file
    }

    func validateIdentity() throws {
        try compareIdentity(rootDescriptor, url: paths.root)
        try compareIdentity(profileDescriptor, url: paths.profile)
        try compareIdentity(runtimeDescriptor, url: paths.runtime)
    }

    private func writeExclusive(_ data: Data, name: String, permissions: Int) throws {
        let descriptor = Darwin.openat(
            runtimeDescriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(permissions)
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            guard Darwin.fchmod(descriptor, mode_t(permissions)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    private func openRegularEntry(name: String, url: URL, expected: Int) throws -> OwnedDescriptor {
        let descriptor = Darwin.openat(runtimeDescriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            _ = Darwin.close(descriptor)
            throw RuntimeBootstrapError.notRegularFile(url)
        }
        let actual = Int(metadata.st_mode & 0o777)
        guard actual == expected else {
            _ = Darwin.close(descriptor)
            throw RuntimeBootstrapError.insecurePermissions(url, expected: expected, actual: actual)
        }
        return OwnedDescriptor(descriptor)
    }

    private static func openOrCreateAbsoluteDirectory(_ url: URL) throws -> (Int32, Bool) {
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var finalCreated = false
        let components = Array(url.standardizedFileURL.pathComponents.dropFirst())
        for (index, component) in components.enumerated() {
            do {
                let (next, created) = try openOrCreateChild(parent: descriptor, name: component)
                if created {
                    guard Darwin.fchmod(next, mode_t(RuntimeBootstrapper.directoryPermissions)) == 0 else {
                        let code = errno
                        _ = Darwin.close(next)
                        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                    }
                }
                _ = Darwin.close(descriptor)
                descriptor = next
                if index == components.indices.last {
                    finalCreated = created
                }
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
        }
        return (descriptor, finalCreated)
    }

    private static func openOrCreateChild(parent: Int32, name: String) throws -> (Int32, Bool) {
        let created: Bool
        if Darwin.mkdirat(parent, name, mode_t(RuntimeBootstrapper.directoryPermissions)) == 0 {
            created = true
        } else if errno == EEXIST {
            created = false
        } else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let descriptor = Darwin.openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (descriptor, created)
    }

    private static func entryExists(parent: Int32, name: String) throws -> Bool {
        var metadata = stat()
        if Darwin.fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        if errno == ENOENT { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func configureDirectory(_ descriptor: Int32, url: URL, created: Bool) throws {
        if created {
            guard Darwin.fchmod(descriptor, mode_t(RuntimeBootstrapper.directoryPermissions)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        try validateDirectory(descriptor, url: url, expected: RuntimeBootstrapper.directoryPermissions)
    }

    private static func validateDirectory(_ descriptor: Int32, url: URL, expected: Int) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
            throw RuntimeBootstrapError.runtimePathIdentityChanged(url)
        }
        let actual = Int(metadata.st_mode & 0o777)
        guard actual == expected else {
            throw RuntimeBootstrapError.insecurePermissions(url, expected: expected, actual: actual)
        }
    }

    private func compareIdentity(_ descriptor: Int32, url: URL) throws {
        var anchored = stat()
        var path = stat()
        guard Darwin.fstat(descriptor, &anchored) == 0,
              Darwin.lstat(url.path, &path) == 0,
              path.st_mode & S_IFMT == S_IFDIR,
              anchored.st_dev == path.st_dev,
              anchored.st_ino == path.st_ino
        else {
            throw RuntimeBootstrapError.runtimePathIdentityChanged(url)
        }
    }

    private func compareEntryIdentity(name: String, url: URL, opened: stat) throws {
        var path = stat()
        guard Darwin.fstatat(runtimeDescriptor, name, &path, AT_SYMLINK_NOFOLLOW) == 0,
              path.st_mode & S_IFMT == S_IFREG,
              opened.st_dev == path.st_dev,
              opened.st_ino == path.st_ino
        else {
            throw RuntimeBootstrapError.runtimeFileIdentityChanged(url)
        }
    }
}

public enum RuntimeBootstrapError: Error, Equatable, Sendable {
    case pythonNotExecutable(URL)
    case invalidPythonExecutable(URL)
    case invalidHomebrewPrefix(String)
    case nonFileRequirementsLock(URL)
    case malformedPythonVersion(String)
    case unsupportedPythonVersion(String, requiredMinor: String)
    case unsupportedPythonImplementation(String)
    case invalidPythonProvenance(String)
    case pythonNotFromHomebrew312(URL)
    case lockChecksumMismatch(expected: String, actual: String)
    case invalidPackageListing(String)
    case packageDrift(expected: [String: String], actual: [String: String])
    case missingRuntimeExecutable(URL)
    case synapseVersionMismatch(expected: String, output: String)
    case commandFailed(executable: String, arguments: [String], status: Int32, standardError: String)
    case existingRuntimeDrift(String)
    case insecurePermissions(URL, expected: Int, actual: Int)
    case notRegularFile(URL)
    case runtimePathIdentityChanged(URL)
    case runtimeFileIdentityChanged(URL)
}
