import Foundation
import Testing
@testable import InboxPlusRuntime

@Test func bootstrapRecordsInterpreterAndExactPackages() async throws {
    // Break caught: bootstrap records unverified interpreter/package metadata or fails to normalize package names.
    let fixture = try BootstrapFixture()
    defer { fixture.remove() }

    let receipt = try await fixture.bootstrapper.bootstrap(
        python: fixture.basePython,
        manifest: fixture.manifest,
        paths: fixture.paths
    )

    #expect(receipt.pythonExecutable == fixture.cellarPython.path)
    #expect(receipt.pythonVersion == "3.12.7")
    #expect(receipt.synapseVersion == "1.158.0")
    #expect(receipt.requirementsLockSHA256 == fixture.manifest.requirementsLockSHA256)
    #expect(receipt.installedPackages == [
        "matrix-synapse": "1.158.0",
        "pip": "24.2",
        "setuptools": "75.1.0",
    ])

    let receiptURL = fixture.paths.runtime.appendingPathComponent("prepared-runtime.json")
    #expect(try fixture.manifest.validatePreparedRuntime(at: receiptURL) == receipt)
    #expect(try permissions(of: fixture.paths.root) == 0o700)
    #expect(try permissions(of: fixture.paths.profile) == 0o700)
    #expect(try permissions(of: fixture.paths.runtime) == 0o700)
    #expect(try permissions(of: receiptURL) == 0o600)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.paths.runtime.path)
        .filter { $0.hasPrefix(".prepared-runtime.json.") }
        .isEmpty)
}

@Test func runtimeProvenanceAcceptsCanonicalProfileAliasFromAnchoredWorkingDirectory() async throws {
    // Break caught: an equivalent physical runtime prefix is rejected because the child reports a filesystem alias.
    let fixture = try BootstrapFixture(runtimeReportsPrefixAlias: true)
    defer { fixture.remove() }

    let receipt = try await fixture.runBootstrap()

    #expect(receipt.pythonVersion == "3.12.7")
}

@Test func bootstrapRejectsPythonOutsideThePinnedMinorBeforeCreatingAProfile() async throws {
    // Break caught: an incompatible interpreter is allowed to create a partially prepared profile.
    let fixture = try BootstrapFixture(pythonVersion: "3.13.1")
    defer { fixture.remove() }

    await #expect(throws: RuntimeBootstrapError.unsupportedPythonVersion("3.13.1", requiredMinor: "3.12")) {
        try await fixture.bootstrapper.bootstrap(
            python: fixture.basePython,
            manifest: fixture.manifest,
            paths: fixture.paths
        )
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.paths.profile.path))
}

@Test func bootstrapRejectsAnExecutableThatClaimsPythonButIsNotCPython() async throws {
    // Break caught: an executable shell/script can pass bootstrap by printing a plausible Python version string.
    let fixture = try BootstrapFixture(pythonImplementation: "posix-shell")
    defer { fixture.remove() }

    await #expect(throws: RuntimeBootstrapError.unsupportedPythonImplementation("posix-shell")) {
        try await fixture.bootstrapper.bootstrap(
            python: fixture.basePython,
            manifest: fixture.manifest,
            paths: fixture.paths
        )
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.paths.profile.path))
}

@Test func bootstrapRejectsAShellAtAHomebrewLookingPathBeforeTrustingItsFacts() async throws {
    // Break caught: candidate-emitted CPython JSON allows a shell under a forged Cellar-looking path to bootstrap.
    let fixture = try BootstrapFixture(candidateFormat: .shell)
    defer { fixture.remove() }

    await #expect(throws: RuntimeBootstrapError.invalidPythonExecutable(fixture.cellarPython)) {
        try await fixture.runBootstrap()
    }
    #expect(!fixture.candidateWasExecuted)
}

@Test func bootstrapExecutesTheValidatedPythonDescriptorAfterPathReplacement() async throws {
    // Break caught: bootstrap validates one Python file, closes it, then executes spoofing replacement bytes through the original path.
    let fixture = try BootstrapFixture()
    defer { fixture.remove() }
    fixture.replacePythonAfterValidation = true

    let receipt = try await fixture.runBootstrap()

    #expect(receipt.pythonVersion == "3.12.7")
    #expect(fixture.validatedCandidateDescriptorWasRetained)
}

@Test func bootstrapRetainsValidatedExecutableResourcesThroughSystemSpawn() async throws {
    // Break caught: release optimization destroys a descriptor owner after only its raw value enters an async spawn request.
    let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(".build/RuntimeBootstrapperLifetimeTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let homebrew = directory.appendingPathComponent("homebrew", isDirectory: true)
    let cellarVersion = homebrew.appendingPathComponent("Cellar/python@3.12/3.12.7", isDirectory: true)
    let cellarPython = cellarVersion.appendingPathComponent("bin/python3.12")
    try FileManager.default.createDirectory(at: cellarPython.deletingLastPathComponent(), withIntermediateDirectories: true)
    let opt = homebrew.appendingPathComponent("opt", isDirectory: true)
    try FileManager.default.createDirectory(at: opt, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: opt.appendingPathComponent("python@3.12", isDirectory: true),
        withDestinationURL: cellarVersion
    )
    let selectedPython = opt.appendingPathComponent("python@3.12/bin/python3.12")
    let paths = try RuntimePaths(
        root: directory.appendingPathComponent("profiles", isDirectory: true),
        profileName: "primary"
    )
    let virtualEnvironment = paths.runtime.appendingPathComponent("venv", isDirectory: true)
    let virtualenvPython = virtualEnvironment.appendingPathComponent("bin/python")

    let baseFacts = """
    {"implementation":"cpython","version":"3.12.7","executable":"\(selectedPython.path)","executableRealPath":"\(cellarPython.path)","prefix":"\(cellarVersion.path)","basePrefix":"\(cellarVersion.path)"}
    """
    let runtimeFacts = """
    {"implementation":"cpython","version":"3.12.7","executable":"\(virtualenvPython.path)","executableRealPath":"\(cellarPython.path)","prefix":"\(virtualEnvironment.path)","basePrefix":"\(cellarVersion.path)"}
    """
    func cLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
    let source = directory.appendingPathComponent("python-shim.c")
    let sourceText = """
    #include <errno.h>
    #include <fcntl.h>
    #include <stdio.h>
    #include <string.h>
    #include <sys/stat.h>
    #include <unistd.h>

    int main(int argc, char **argv) {
        if (argc == 2 && strcmp(argv[1], "--version") == 0) {
            fputs("Synapse 1.158.0\\n", stdout);
            return 0;
        }
        if (argc == 5 && strcmp(argv[1], "-I") == 0 && strcmp(argv[2], "-S") == 0) {
            fputs("\(cLiteral(baseFacts))\\n", stdout);
            return 0;
        }
        if (argc == 5 && strcmp(argv[1], "-I") == 0 && strcmp(argv[2], "-m") == 0
            && strcmp(argv[3], "venv") == 0) {
            if (mkdir("venv", 0700) != 0 && errno != EEXIST) return 90;
            if (mkdir("venv/bin", 0700) != 0 && errno != EEXIST) return 91;
            if (link("\(cLiteral(cellarPython.path))", "venv/bin/python") != 0 && errno != EEXIST) return 92;
            if (link("\(cLiteral(cellarPython.path))", "venv/bin/synapse_homeserver") != 0 && errno != EEXIST) return 93;
            return 0;
        }
        if (argc == 4 && strcmp(argv[1], "-I") == 0 && strcmp(argv[2], "-c") == 0
            && strstr(argv[3], "sys.implementation.name") != NULL) {
            fputs("\(cLiteral(runtimeFacts))\\n", stdout);
            return 0;
        }
        if (argc == 9 && strcmp(argv[1], "-I") == 0 && strcmp(argv[2], "-m") == 0
            && strcmp(argv[3], "pip") == 0 && strcmp(argv[4], "install") == 0) {
            int descriptor = open(argv[8], O_RDONLY);
            if (descriptor < 0) return 94;
            char contents[512] = {0};
            ssize_t count = read(descriptor, contents, sizeof(contents) - 1);
            close(descriptor);
            if (count < 0 || strstr(contents, "matrix_synapse==1.158.0") == NULL) return 95;
            return 0;
        }
        if (argc == 6 && strcmp(argv[1], "-I") == 0 && strcmp(argv[2], "-m") == 0
            && strcmp(argv[3], "pip") == 0 && strcmp(argv[4], "freeze") == 0) {
            fputs("\(cLiteral(BootstrapFixture.lockContents))", stdout);
            return 0;
        }
        if (argc == 4 && strcmp(argv[1], "-I") == 0 && strcmp(argv[2], "-c") == 0
            && strstr(argv[3], "synapse.__version__") != NULL) {
            fputs("1.158.0\\n", stdout);
            return 0;
        }
        return 99;
    }
    """
    try Data(sourceText.utf8)
        .write(to: source)
    let compiler = Process()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
    compiler.arguments = [source.path, "-o", cellarPython.path]
    try compiler.run()
    compiler.waitUntilExit()
    #expect(compiler.terminationStatus == 0)

    let brew = directory.appendingPathComponent("brew")
    let brewScript = "#!/bin/sh\nprintf '%s\\n' '\(opt.appendingPathComponent("python@3.12").path)'\n"
    try Data(brewScript.utf8).write(to: brew)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)

    let lock = directory.appendingPathComponent("requirements.lock")
    try Data(BootstrapFixture.lockContents.utf8).write(to: lock)
    let manifest = RuntimeManifest(
        schemaVersion: 1,
        pythonMinor: "3.12",
        synapseVersion: "1.158.0",
        requirementsLockSHA256: BootstrapFixture.lockSHA256
    )
    let bootstrapper = RuntimeBootstrapper(
        requirementsLock: lock,
        brewExecutable: brew,
        hostEnvironment: ["HOME": directory.path, "TMPDIR": directory.path],
        processRunner: RuntimeBootstrapper.runSystemProcess,
        now: { Date(timeIntervalSinceReferenceDate: 1234) }
    )

    let receipt = try await bootstrapper.bootstrap(
        python: selectedPython,
        manifest: manifest,
        paths: paths
    )

    #expect(receipt.pythonExecutable == cellarPython.path)
    #expect(receipt.installedPackages["matrix-synapse"] == "1.158.0")
}

@Test func bootstrapRejectsPackageExtrasInsteadOfWeakeningTheLock() async throws {
    // Break caught: bootstrap accepts an unpinned transitive package merely because every locked package is present.
    let fixture = try BootstrapFixture(
        frozenPackages: "matrix-synapse==1.158.0\npip==24.2\nsetuptools==75.1.0\nwheel==0.45.1\n"
    )
    defer { fixture.remove() }

    await #expect(throws: RuntimeBootstrapError.packageDrift(
        expected: [
            "matrix-synapse": "1.158.0",
            "pip": "24.2",
            "setuptools": "75.1.0",
        ],
        actual: [
            "matrix-synapse": "1.158.0",
            "pip": "24.2",
            "setuptools": "75.1.0",
            "wheel": "0.45.1",
        ]
    )) {
        try await fixture.bootstrapper.bootstrap(
            python: fixture.basePython,
            manifest: fixture.manifest,
            paths: fixture.paths
        )
    }
}

@Test func existingPackageDriftIsReportedWithoutRepair() async throws {
    // Break caught: a second bootstrap silently reinstalls packages when an existing prepared runtime has drifted.
    let fixture = try BootstrapFixture()
    defer { fixture.remove() }
    _ = try await fixture.bootstrapper.bootstrap(
        python: fixture.basePython,
        manifest: fixture.manifest,
        paths: fixture.paths
    )
    fixture.frozenPackages = "matrix-synapse==1.158.0\npip==24.2\nsetuptools==75.1.0\nwheel==0.45.1\n"
    fixture.rejectMutationCommands = true

    await #expect(throws: RuntimeBootstrapError.packageDrift(
        expected: [
            "matrix-synapse": "1.158.0",
            "pip": "24.2",
            "setuptools": "75.1.0",
        ],
        actual: [
            "matrix-synapse": "1.158.0",
            "pip": "24.2",
            "setuptools": "75.1.0",
            "wheel": "0.45.1",
        ]
    )) {
        try await fixture.bootstrapper.bootstrap(
            python: fixture.basePython,
            manifest: fixture.manifest,
            paths: fixture.paths
        )
    }
}

@Test func validExistingRuntimeReturnsItsOriginalReceiptWithoutReinstalling() async throws {
    // Break caught: idempotent bootstrap mutates or replaces an already verified runtime and receipt.
    let fixture = try BootstrapFixture()
    defer { fixture.remove() }
    let first = try await fixture.bootstrapper.bootstrap(
        python: fixture.basePython,
        manifest: fixture.manifest,
        paths: fixture.paths
    )
    fixture.rejectMutationCommands = true

    let second = try await fixture.bootstrapper.bootstrap(
        python: fixture.basePython,
        manifest: fixture.manifest,
        paths: fixture.paths
    )

    #expect(second == first)
}

@Test func bootstrapVerifiesInstalledModuleWhenSynapseExecutableHasNoVersionFlag() async throws {
    // Break caught: the real Synapse 1.158 executable's unsupported --version flag makes a correctly pinned install unverifiable.
    let fixture = try BootstrapFixture(synapseVersionFlagSupported: false)
    defer { fixture.remove() }

    let receipt = try await fixture.bootstrapper.bootstrap(
        python: fixture.basePython,
        manifest: fixture.manifest,
        paths: fixture.paths
    )

    #expect(receipt.synapseVersion == "1.158.0")
}

@Test func bootstrapRejectsNearMatchForUnsupportedSynapseVersionFlag() async throws {
    // Break caught: a loosely matched argparse error enables module fallback for an unrecognized failure variation.
    let nearMatch = BootstrapFixture.knownUnsupportedVersionStderr
        .replacingOccurrences(of: "unrecognized arguments: --version", with: "unrecognized arguments: --version --other")
    let fixture = try BootstrapFixture(
        synapseVersionFlagSupported: false,
        synapseVersionError: nearMatch
    )
    defer { fixture.remove() }

    await #expect(throws: RuntimeBootstrapError.commandFailed(
        executable: fixture.synapseExecutable.path,
        arguments: ["--version"],
        status: 2,
        standardError: nearMatch
    )) {
        try await fixture.bootstrapper.bootstrap(
            python: fixture.basePython,
            manifest: fixture.manifest,
            paths: fixture.paths
        )
    }
}

@Test func bootstrapRejectsSynapseFallbackForAnotherManifestVersion() async throws {
    // Break caught: the 1.158.0-only compatibility path silently applies to future Synapse releases.
    let fixture = try BootstrapFixture(
        synapseVersion: "1.159.0",
        synapseVersionFlagSupported: false
    )
    defer { fixture.remove() }

    await #expect(throws: RuntimeBootstrapError.commandFailed(
        executable: fixture.synapseExecutable.path,
        arguments: ["--version"],
        status: 2,
        standardError: BootstrapFixture.knownUnsupportedVersionStderr
    )) {
        try await fixture.bootstrapper.bootstrap(
            python: fixture.basePython,
            manifest: fixture.manifest,
            paths: fixture.paths
        )
    }
}

@Test func existingRuntimeRejectsDirectoryPermissionDriftWithoutRepair() async throws {
    // Break caught: idempotent verification accepts or silently chmods a world-traversable profile.
    let fixture = try BootstrapFixture()
    defer { fixture.remove() }
    _ = try await fixture.runBootstrap()
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.paths.profile.path)
    fixture.rejectMutationCommands = true

    await #expect(throws: RuntimeBootstrapError.insecurePermissions(
        fixture.paths.profile,
        expected: 0o700,
        actual: 0o755
    )) {
        try await fixture.runBootstrap()
    }
    #expect(try permissions(of: fixture.paths.profile) == 0o755)
}

@Test func bootstrapRejectsPreexistingInsecureRootBeforeReceiptWithoutRepair() async throws {
    // Break caught: bootstrap silently chmods a preexisting 0755 profile root before a receipt exists.
    let fixture = try BootstrapFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(at: fixture.paths.root, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.paths.root.path)

    await #expect(throws: RuntimeBootstrapError.insecurePermissions(
        fixture.paths.root,
        expected: 0o700,
        actual: 0o755
    )) {
        try await fixture.runBootstrap()
    }
    #expect(try permissions(of: fixture.paths.root) == 0o755)
}

@Test func bootstrapRejectsPreexistingInsecureProfileBeforeReceiptWithoutRepair() async throws {
    // Break caught: bootstrap silently chmods a preexisting 0755 profile before a receipt exists.
    let fixture = try BootstrapFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(at: fixture.paths.profile, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.paths.root.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.paths.profile.path)

    await #expect(throws: RuntimeBootstrapError.insecurePermissions(
        fixture.paths.profile,
        expected: 0o700,
        actual: 0o755
    )) {
        try await fixture.runBootstrap()
    }
    #expect(try permissions(of: fixture.paths.profile) == 0o755)
}

@Test func existingRuntimeRejectsReceiptPermissionDriftWithoutRepair() async throws {
    // Break caught: idempotent verification reads a receipt visible to other local users or silently repairs it.
    let fixture = try BootstrapFixture()
    defer { fixture.remove() }
    _ = try await fixture.runBootstrap()
    let receipt = fixture.paths.runtime.appendingPathComponent("prepared-runtime.json")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: receipt.path)
    fixture.rejectMutationCommands = true

    await #expect(throws: RuntimeBootstrapError.insecurePermissions(
        receipt,
        expected: 0o600,
        actual: 0o644
    )) {
        try await fixture.runBootstrap()
    }
    #expect(try permissions(of: receipt) == 0o644)
}

@Test func verifiedLockBytesAreTheOnlyRequirementsConsumedByPip() async throws {
    // Break caught: replacing the repository lock after checksum verification changes the packages pip consumes.
    let fixture = try BootstrapFixture(replaceSourceLockDuringVenvCreation: true)
    defer { fixture.remove() }

    let receipt = try await fixture.runBootstrap()

    #expect(receipt.installedPackages["matrix-synapse"] == "1.158.0")
    #expect(try String(contentsOf: fixture.runtimeLock, encoding: .utf8) == BootstrapFixture.lockContents)
    #expect(try permissions(of: fixture.runtimeLock) == 0o600)
}

@Test func pipConsumesAuthenticatedLockDescriptorAfterPathReplacement() async throws {
    // Break caught: pip reopens the profile requirements path after authentication instead of consuming the held descriptor.
    let fixture = try BootstrapFixture(replaceRuntimeLockImmediatelyBeforePip: true)
    defer { fixture.remove() }

    let receipt = try await fixture.runBootstrap()

    #expect(receipt.installedPackages["matrix-synapse"] == "1.158.0")
    #expect(fixture.pipReadInheritedLock == BootstrapFixture.lockContents)
}

@Test func ancestorSwapCannotRedirectReceiptPublication() async throws {
    // Break caught: replacing the profile ancestor after validation publishes a trusted receipt outside the profile.
    let fixture = try BootstrapFixture(swapProfileAfterVenvCreation: true)
    defer { fixture.remove() }

    await #expect(throws: RuntimeBootstrapError.runtimePathIdentityChanged(fixture.paths.profile)) {
        try await fixture.runBootstrap()
    }
    #expect(!FileManager.default.fileExists(
        atPath: fixture.outsideDirectory.appendingPathComponent("runtime/prepared-runtime.json").path
    ))
}

@Test func ancestorSwapImmediatelyBeforeVenvCannotCreateAnAttackerArtifact() async throws {
    // Break caught: venv receives an absolute profile path and writes into an attacker replacement before drift is detected.
    let fixture = try BootstrapFixture(swapRuntimeImmediatelyBeforeVenv: true)
    defer { fixture.remove() }

    await #expect(throws: RuntimeBootstrapError.runtimePathIdentityChanged(fixture.paths.runtime)) {
        try await fixture.runBootstrap()
    }
    #expect(!FileManager.default.fileExists(
        atPath: fixture.outsideDirectory.appendingPathComponent("venv/attacker-marker").path
    ))
}

@Test func existingReceiptSwapAfterOpenIsRejectedByDescriptorIdentity() async throws {
    // Break caught: receipt validation fstats one pathname identity and then decodes a replacement opened by path.
    let fixture = try BootstrapFixture()
    defer { fixture.remove() }
    _ = try await fixture.runBootstrap()
    fixture.swapReceiptAfterOpen = true

    await #expect(throws: RuntimeBootstrapError.runtimeFileIdentityChanged(
        fixture.paths.runtime.appendingPathComponent("prepared-runtime.json")
    )) {
        try await fixture.runBootstrap()
    }
}

@Test func finalReceiptValidationRejectsRuntimePathSwapBeforeReturn() async throws {
    // Break caught: fresh bootstrap returns a validated receipt after its runtime pathname is redirected by the receipt-open seam.
    let fixture = try BootstrapFixture()
    defer { fixture.remove() }
    fixture.swapRuntimeAtReceiptOpen = true

    await #expect(throws: RuntimeBootstrapError.runtimePathIdentityChanged(fixture.paths.runtime)) {
        try await fixture.runBootstrap()
    }
    #expect(!FileManager.default.fileExists(
        atPath: fixture.outsideDirectory.appendingPathComponent("prepared-runtime.json").path
    ))
}

@Test func subprocessRequestsExcludeHostilePythonAndPipEnvironment() async throws {
    // Break caught: inherited Python/pip variables or an ambient working directory can shadow modules or alter installation.
    let fixture = try BootstrapFixture(hostEnvironment: [
        "HOME": "/safe-home",
        "TMPDIR": "/safe-tmp",
        "PATH": "/hostile-bin",
        "PYTHONPATH": "/attacker/python",
        "PYTHONHOME": "/attacker/home",
        "PIP_INDEX_URL": "https://attacker.invalid/simple",
        "PIP_CONFIG_FILE": "/attacker/pip.conf",
    ])
    defer { fixture.remove() }

    let receipt = try await fixture.runBootstrap()

    #expect(receipt.synapseVersion == "1.158.0")
}

@Test func explicitRequirementsLockIsIndependentOfAmbientWorkingDirectory() throws {
    // Break caught: proving CWD independence mutates process-global state and races other tests in the parent process.
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let alternateWorkingDirectory = packageRoot
        .appendingPathComponent(".build/RuntimeBootstrapperAlternateCWD-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: alternateWorkingDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: alternateWorkingDirectory) }
    let fixture = try BootstrapFixture()
    defer { fixture.remove() }

    let harnessSource = alternateWorkingDirectory.appendingPathComponent("AlternateCWDHarness.swift")
    let harnessExecutable = alternateWorkingDirectory.appendingPathComponent("alternate-cwd-harness")
    let sourceText = #"""
    import Darwin
    import Foundation

    @main
    struct AlternateCWDHarness {
        enum HarnessError: Error {
            case bootstrapUnexpectedlySucceeded
            case explicitLockChanged
            case packageRootIsCurrentDirectory
            case unexpectedCommand(String, [String])
        }

        static func main() async {
            do {
                try await run()
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                fputs("alternate-CWD harness failed: \(error)\n", stderr)
                Darwin.exit(EXIT_FAILURE)
            }
        }

        static func run() async throws {
            guard CommandLine.arguments.count == 7 else { throw POSIXError(.EINVAL) }
            let explicitLock = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
            let selectedPython = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
            let brew = URL(fileURLWithPath: CommandLine.arguments[3]).standardizedFileURL
            let brewPrefix = URL(fileURLWithPath: CommandLine.arguments[4]).standardizedFileURL
            let profileRoot = URL(fileURLWithPath: CommandLine.arguments[5], isDirectory: true)
            let packageRoot = URL(fileURLWithPath: CommandLine.arguments[6], isDirectory: true)
                .standardizedFileURL
            let currentDirectory = URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            ).standardizedFileURL
            guard currentDirectory != packageRoot else { throw HarnessError.packageRootIsCurrentDirectory }

            let cellarPython = selectedPython.resolvingSymlinksInPath()
            let cellarVersion = cellarPython
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let invalidChecksum = String(repeating: "0", count: 64)
            let manifest = RuntimeManifest(
                schemaVersion: 1,
                pythonMinor: "3.12",
                synapseVersion: "1.158.0",
                requirementsLockSHA256: invalidChecksum
            )
            let paths = try RuntimePaths(
                root: profileRoot,
                profileName: "alternate-cwd"
            )
            let processRunner: RuntimeProcessRunner = { request in
                if request.executable == brew,
                   request.arguments == ["--prefix", "python@3.12"] {
                    return RuntimeProcessOutput(
                        status: 0,
                        standardOutput: brewPrefix.path + "\n",
                        standardError: ""
                    )
                }
                if request.executable.standardizedFileURL == selectedPython.standardizedFileURL,
                   request.arguments.count == 4,
                   Array(request.arguments.prefix(3)) == ["-I", "-S", "-c"] {
                    let facts = """
                    {"implementation":"cpython","version":"3.12.7","executable":"\(selectedPython.path)","executableRealPath":"\(cellarPython.path)","prefix":"\(cellarVersion.path)","basePrefix":"\(cellarVersion.path)"}
                    """
                    return RuntimeProcessOutput(status: 0, standardOutput: facts, standardError: "")
                }
                throw HarnessError.unexpectedCommand(request.executable.path, request.arguments)
            }
            let bootstrapper = RuntimeBootstrapper(requirementsLock: explicitLock)
                .withTestDependencies(
                    brewExecutable: brew,
                    hostEnvironment: ["HOME": currentDirectory.path, "TMPDIR": currentDirectory.path],
                    processRunner: processRunner,
                    filesystemEvent: { _ in },
                    now: { Date(timeIntervalSinceReferenceDate: 1234) }
                )

            do {
                _ = try await bootstrapper.bootstrap(
                    python: selectedPython,
                    manifest: manifest,
                    paths: paths
                )
                throw HarnessError.bootstrapUnexpectedlySucceeded
            } catch RuntimeBootstrapError.lockChecksumMismatch(let expected, _) {
                guard expected == invalidChecksum else { throw HarnessError.explicitLockChanged }
                guard bootstrapper.requirementsLock == explicitLock else {
                    throw HarnessError.explicitLockChanged
                }
            }
        }
    }
    """#
    try Data(sourceText.utf8).write(to: harnessSource)

    let runtimeSources = try FileManager.default.contentsOfDirectory(
        at: packageRoot.appendingPathComponent("Sources/InboxPlusRuntime", isDirectory: true),
        includingPropertiesForKeys: nil
    )
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let compile = try runIsolatedTestProcess(
        executable: URL(fileURLWithPath: "/usr/bin/swiftc"),
        arguments: [
            "-parse-as-library",
            "-swift-version", "6",
            "-module-name", "InboxPlusRuntimeAlternateCWDHarness",
        ] + runtimeSources.map(\.path) + [
            harnessSource.path,
            "-o", harnessExecutable.path,
        ],
        currentDirectory: packageRoot,
        outputDirectory: alternateWorkingDirectory
    )
    guard compile.status == 0 else {
        Issue.record("Alternate-CWD harness compilation failed:\n\(compile.output)")
        return
    }

    let run = try runIsolatedTestProcess(
        executable: harnessExecutable,
        arguments: [
            fixture.lock.path,
            fixture.basePython.path,
            fixture.brewExecutable.path,
            fixture.homebrewPrefix.appendingPathComponent("opt/python@3.12").path,
            fixture.paths.root.path,
            packageRoot.path,
        ],
        currentDirectory: alternateWorkingDirectory,
        outputDirectory: alternateWorkingDirectory
    )

    #expect(run.status == 0, "Alternate-CWD harness output:\n\(run.output)")
}

private func runIsolatedTestProcess(
    executable: URL,
    arguments: [String],
    currentDirectory: URL,
    outputDirectory: URL
) throws -> (status: Int32, output: String) {
    let outputURL = outputDirectory.appendingPathComponent("process-output-\(UUID().uuidString).log")
    try Data().write(to: outputURL, options: .withoutOverwriting)
    defer { try? FileManager.default.removeItem(at: outputURL) }
    let output = try FileHandle(forWritingTo: outputURL)
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    process.standardOutput = output
    process.standardError = output

    do {
        try process.run()
        process.waitUntilExit()
        try output.synchronize()
        try output.close()
        return (
            process.terminationStatus,
            try String(contentsOf: outputURL, encoding: .utf8)
        )
    } catch {
        try? output.close()
        throw error
    }
}

private final class BootstrapFixture: @unchecked Sendable {
    enum CandidateFormat { case machO, shell }
    static let lockContents = "matrix_synapse==1.158.0\npip==24.2\nsetuptools==75.1.0\n"
    static let lockSHA256 = "27ad29ab8d275b356ead8720ef071f8fb8abeb82c9facd9b5d0f045e3694d5a2"

    static let knownUnsupportedVersionStderr = """
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

    let directory: URL
    let brewExecutable = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
    let homebrewPrefix: URL
    let cellarVersion: URL
    let cellarPython: URL
    let basePython: URL
    let lock: URL
    let paths: RuntimePaths
    let manifest: RuntimeManifest
    lazy var bootstrapper = RuntimeBootstrapper(
        requirementsLock: lock,
        brewExecutable: brewExecutable,
        hostEnvironment: hostEnvironment,
        processRunner: process,
        filesystemEvent: handleFilesystemEvent,
        now: { Date(timeIntervalSinceReferenceDate: 1234) }
    )
    let pythonVersion: String
    let pythonImplementation: String
    let synapseVersionFlagSupported: Bool
    let synapseVersionError: String
    let replaceSourceLockDuringVenvCreation: Bool
    let swapProfileAfterVenvCreation: Bool
    let hostEnvironment: [String: String]
    let candidateFormat: CandidateFormat
    let runtimeReportsPrefixAlias: Bool
    var frozenPackages: String
    var rejectMutationCommands = false
    var candidateWasExecuted = false
    var pipReadInheritedLock: String?
    var replaceRuntimeLockImmediatelyBeforePip = false
    var swapRuntimeImmediatelyBeforeVenv = false
    var swapReceiptAfterOpen = false
    var swapRuntimeAtReceiptOpen = false
    var replacePythonAfterValidation = false
    var validatedCandidateDescriptorWasRetained = false

    var virtualEnvironment: URL { paths.runtime.appendingPathComponent("venv", isDirectory: true) }
    var virtualenvPython: URL { virtualEnvironment.appendingPathComponent("bin/python") }
    var synapseExecutable: URL { virtualEnvironment.appendingPathComponent("bin/synapse_homeserver") }
    var runtimeLock: URL { paths.runtime.appendingPathComponent("requirements.lock") }
    var outsideDirectory: URL { directory.appendingPathComponent("outside", isDirectory: true) }

    init(
        pythonVersion: String = "3.12.7",
        pythonImplementation: String = "cpython",
        synapseVersion: String = "1.158.0",
        frozenPackages: String = "setuptools==75.1.0\nmatrix-synapse==1.158.0\npip==24.2\n",
        synapseVersionFlagSupported: Bool = true,
        synapseVersionError: String = BootstrapFixture.knownUnsupportedVersionStderr,
        replaceSourceLockDuringVenvCreation: Bool = false,
        swapProfileAfterVenvCreation: Bool = false,
        replaceRuntimeLockImmediatelyBeforePip: Bool = false,
        swapRuntimeImmediatelyBeforeVenv: Bool = false,
        candidateFormat: CandidateFormat = .machO,
        runtimeReportsPrefixAlias: Bool = false,
        hostEnvironment: [String: String] = ["HOME": "/safe-home", "TMPDIR": "/safe-tmp"]
    ) throws {
        directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/RuntimeBootstrapperTests-\(UUID().uuidString)", isDirectory: true)
        homebrewPrefix = directory.appendingPathComponent("homebrew", isDirectory: true)
        cellarVersion = homebrewPrefix.appendingPathComponent("Cellar/python@3.12/3.12.7", isDirectory: true)
        cellarPython = cellarVersion.appendingPathComponent("bin/python3.12")
        basePython = homebrewPrefix.appendingPathComponent("opt/python@3.12/bin/python3.12")
        lock = directory.appendingPathComponent("requirements.lock")
        paths = try RuntimePaths(
            root: directory.appendingPathComponent("profiles", isDirectory: true),
            profileName: "primary"
        )
        manifest = RuntimeManifest(
            schemaVersion: 1,
            pythonMinor: "3.12",
            synapseVersion: synapseVersion,
            requirementsLockSHA256: Self.lockSHA256
        )
        self.pythonVersion = pythonVersion
        self.pythonImplementation = pythonImplementation
        self.frozenPackages = frozenPackages
        self.synapseVersionFlagSupported = synapseVersionFlagSupported
        self.synapseVersionError = synapseVersionError
        self.replaceSourceLockDuringVenvCreation = replaceSourceLockDuringVenvCreation
        self.swapProfileAfterVenvCreation = swapProfileAfterVenvCreation
        self.replaceRuntimeLockImmediatelyBeforePip = replaceRuntimeLockImmediatelyBeforePip
        self.swapRuntimeImmediatelyBeforeVenv = swapRuntimeImmediatelyBeforeVenv
        self.candidateFormat = candidateFormat
        self.runtimeReportsPrefixAlias = runtimeReportsPrefixAlias
        self.hostEnvironment = hostEnvironment

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.lockContents.write(to: lock, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: cellarPython.deletingLastPathComponent(), withIntermediateDirectories: true)
        let candidateData: Data
        switch candidateFormat {
        case .machO:
            candidateData = Data([0xcf, 0xfa, 0xed, 0xfe, 0, 0, 0, 0])
        case .shell:
            candidateData = Data("#!/bin/sh\nexit 0\n".utf8)
        }
        try candidateData.write(to: cellarPython)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cellarPython.path)
        let optDirectory = homebrewPrefix.appendingPathComponent("opt", isDirectory: true)
        try FileManager.default.createDirectory(at: optDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: optDirectory.appendingPathComponent("python@3.12", isDirectory: true),
            withDestinationURL: cellarVersion
        )

    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func runBootstrap() async throws -> PreparedRuntimeReceipt {
        try await bootstrapper.bootstrap(python: basePython, manifest: manifest, paths: paths)
    }

    lazy var process: RuntimeProcessRunner = { [weak self] request in
        guard let self else { throw FixtureError.deallocated }
        return try self.run(request)
    }

    lazy var handleFilesystemEvent: RuntimeFilesystemEventHandler = { [weak self] event in
        guard let self else { throw FixtureError.deallocated }
        if event == .pythonValidated, self.replacePythonAfterValidation {
            self.replacePythonAfterValidation = false
            try FileManager.default.removeItem(at: self.cellarPython)
            let spoof = """
            #!/bin/sh
            printf '%s\\n' '{"implementation":"cpython","version":"3.12.7","executable":"\(self.basePython.path)","executableRealPath":"\(self.cellarPython.path)","prefix":"\(self.cellarVersion.path)","basePrefix":"\(self.cellarVersion.path)"}'
            """
            try Data(spoof.utf8).write(to: self.cellarPython)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: self.cellarPython.path)
        }
        if event == .receiptOpened, self.swapRuntimeAtReceiptOpen {
            self.swapRuntimeAtReceiptOpen = false
            let relocated = self.directory.appendingPathComponent("receipt-open-runtime", isDirectory: true)
            try FileManager.default.moveItem(at: self.paths.runtime, to: relocated)
            try FileManager.default.createDirectory(at: self.outsideDirectory, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: self.paths.runtime, withDestinationURL: self.outsideDirectory)
        }
        if event == .receiptOpened, self.swapReceiptAfterOpen {
            self.swapReceiptAfterOpen = false
            let receipt = self.paths.runtime.appendingPathComponent("prepared-runtime.json")
            let replacement = self.paths.runtime.appendingPathComponent("replacement-receipt.json")
            try Data("{}".utf8).write(to: replacement)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: replacement.path)
            try FileManager.default.removeItem(at: receipt)
            try FileManager.default.moveItem(at: replacement, to: receipt)
        }
    }

    private func run(_ request: RuntimeProcessRequest) throws -> RuntimeProcessOutput {
        try validateIsolation(request)
        let executable = request.executable
        let arguments = request.arguments
        if executable == brewExecutable, arguments == ["--prefix", "python@3.12"] {
            return .init(status: 0, standardOutput: homebrewPrefix.appendingPathComponent("opt/python@3.12").path + "\n", standardError: "")
        }
        if executable.standardizedFileURL == basePython.standardizedFileURL,
           arguments.count == 4,
           Array(arguments.prefix(3)) == ["-I", "-S", "-c"]
        {
            if replacePythonAfterValidation == false,
               let validatedExecutable = request.expectedExecutableIdentity
            {
                var magic = [UInt8](repeating: 0, count: 4)
                let count = Darwin.pread(validatedExecutable, &magic, magic.count, 0)
                validatedCandidateDescriptorWasRetained = count == magic.count
                    && magic == [0xcf, 0xfa, 0xed, 0xfe]
            }
            candidateWasExecuted = true
            return .init(status: 0, standardOutput: pythonFacts(runtime: false), standardError: "")
        }
        if executable.standardizedFileURL == basePython.standardizedFileURL,
           arguments == ["-I", "-m", "venv", "venv"]
        {
            guard !rejectMutationCommands else { throw FixtureError.unexpectedMutation }
            if swapRuntimeImmediatelyBeforeVenv {
                let relocated = directory.appendingPathComponent("relocated-runtime", isDirectory: true)
                try FileManager.default.moveItem(at: paths.runtime, to: relocated)
                try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: paths.runtime, withDestinationURL: outsideDirectory)
            }
            try createVirtualEnvironment(at: request.workingDirectoryDescriptor)
            if replaceSourceLockDuringVenvCreation {
                try "matrix-synapse==9.9.9\n".write(to: lock, atomically: true, encoding: .utf8)
            }
            if swapProfileAfterVenvCreation {
                let relocated = directory.appendingPathComponent("relocated-profile", isDirectory: true)
                try FileManager.default.moveItem(at: paths.profile, to: relocated)
                try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: paths.profile, withDestinationURL: outsideDirectory)
            }
            return .success
        }

        if executable == virtualenvPython,
           arguments.count == 3,
           Array(arguments.prefix(2)) == ["-I", "-c"],
           arguments[2].contains("sys.implementation.name")
        {
            return .init(status: 0, standardOutput: pythonFacts(runtime: true), standardError: "")
        }
        if executable == virtualenvPython,
           arguments.prefix(7) == ["-I", "-m", "pip", "install", "--disable-pip-version-check", "--no-input", "--requirement"],
           arguments.count == 8,
           arguments[7] == "authenticated-lock-descriptor"
        {
            guard !rejectMutationCommands else { throw FixtureError.unexpectedMutation }
            if replaceRuntimeLockImmediatelyBeforePip {
                try FileManager.default.removeItem(at: runtimeLock)
                try Data("matrix-synapse==9.9.9\n".utf8).write(to: runtimeLock)
            }
            let inherited = try #require(request.inheritedDescriptors.first(where: {
                $0.destination == .argument(7)
            }))
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.pread(inherited.source, &bytes, bytes.count, 0)
            guard count >= 0 else { throw POSIXError(.EIO) }
            pipReadInheritedLock = String(decoding: bytes.prefix(Int(count)), as: UTF8.self)
            guard pipReadInheritedLock == Self.lockContents else {
                throw FixtureError.unverifiedLockConsumed
            }
            return .success
        }
        if executable == virtualenvPython,
           arguments == ["-I", "-m", "pip", "freeze", "--all"]
        {
            return .init(status: 0, standardOutput: frozenPackages, standardError: "")
        }
        if executable == virtualenvPython,
           arguments == ["-I", "-c", "import synapse; print(synapse.__version__)"]
        {
            return .init(status: 0, standardOutput: "1.158.0\n", standardError: "")
        }
        if executable == paths.runtime.appendingPathComponent("venv/bin/synapse_homeserver"),
           arguments == ["--version"]
        {
            if synapseVersionFlagSupported {
                return .init(status: 0, standardOutput: "Synapse 1.158.0\n", standardError: "")
            }
            return .init(status: 2, standardOutput: "", standardError: synapseVersionError)
        }
        throw FixtureError.unexpectedCommand(executable.path, arguments)
    }

    private func pythonFacts(runtime: Bool) -> String {
        let runtimePrefix = runtimeReportsPrefixAlias
            ? "/System/Volumes/Data" + canonicalPath(paths.runtime) + "/venv"
            : virtualEnvironment.path
        let prefix = runtime ? runtimePrefix : cellarVersion.path
        let executable = runtime ? virtualenvPython.path : basePython.path
        let basePrefix = runtime
            ? homebrewPrefix.appendingPathComponent("opt/python@3.12", isDirectory: true).path
            : cellarVersion.path
        return """
        {"implementation":"\(pythonImplementation)","version":"\(pythonVersion)","executable":"\(executable)","executableRealPath":"\(cellarPython.path)","prefix":"\(prefix)","basePrefix":"\(basePrefix)"}
        """
    }

    private func createVirtualEnvironment(at runtimeDescriptor: Int32) throws {
        guard Darwin.mkdirat(runtimeDescriptor, "venv", 0o700) == 0 || errno == EEXIST else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let venv = Darwin.openat(runtimeDescriptor, "venv", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard venv >= 0 else { throw POSIXError(.EIO) }
        defer { _ = Darwin.close(venv) }
        guard Darwin.mkdirat(venv, "bin", 0o700) == 0 || errno == EEXIST else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let bin = Darwin.openat(venv, "bin", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard bin >= 0 else { throw POSIXError(.EIO) }
        defer { _ = Darwin.close(bin) }
        guard Darwin.symlinkat(cellarPython.path, bin, "python") == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let synapse = Darwin.openat(bin, "synapse_homeserver", O_WRONLY | O_CREAT | O_EXCL, 0o755)
        guard synapse >= 0 else { throw POSIXError(.EIO) }
        _ = Darwin.close(synapse)
        if swapRuntimeImmediatelyBeforeVenv {
            let marker = Darwin.openat(venv, "attacker-marker", O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard marker >= 0 else { throw POSIXError(.EIO) }
            _ = Darwin.close(marker)
        }
    }

    private func canonicalPath(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard Darwin.realpath(url.path, &buffer) != nil else { return url.path }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func validateIsolation(_ request: RuntimeProcessRequest) throws {
        let forbidden = request.environment.keys.filter {
            $0 == "PYTHONPATH" || $0 == "PYTHONHOME" || $0.hasPrefix("PIP_")
        }
        guard forbidden.isEmpty else {
            throw FixtureError.hostileEnvironmentLeaked(forbidden.sorted())
        }
        guard request.environment["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
              request.workingDirectoryDescriptor >= 0
        else {
            throw FixtureError.unsanitizedRequest
        }
    }

    enum FixtureError: Error {
        case deallocated
        case unexpectedMutation
        case unverifiedLockConsumed
        case hostileEnvironmentLeaked([String])
        case unsanitizedRequest
        case unexpectedCommand(String, [String])
    }
}

private func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    return permissions.intValue & 0o777
}
