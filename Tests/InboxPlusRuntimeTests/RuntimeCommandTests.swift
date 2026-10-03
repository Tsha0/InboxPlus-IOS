import Foundation
import Testing
@testable import InboxPlusRuntime
@testable import InboxPlusRuntimeCLI

@Test func removeRequiresMatchingConfirmation() throws {
    let command = try RuntimeCommand.parse(["remove", "--profile", "alpha", "--confirm", "alpha"])
    #expect(command == .remove(profile: "alpha", confirmation: "alpha", exportReport: nil))
}

@Test func missingProfileIsUsageError() {
    #expect(throws: RuntimeCommandError.missingOption("--profile")) {
        try RuntimeCommand.parse(["start"])
    }
}

@Test func removeCarriesAnExplicitExportDestination() throws {
    let command = try RuntimeCommand.parse([
        "remove", "--profile", "alpha", "--confirm", "alpha",
        "--export-report", "docs/benchmarks/phase-2/",
    ])
    #expect(
        command == .remove(
            profile: "alpha",
            confirmation: "alpha",
            exportReport: "docs/benchmarks/phase-2/"
        )
    )
}

@Test func removeWithoutConfirmationIsUsageError() {
    #expect(throws: RuntimeCommandError.missingOption("--confirm")) {
        try RuntimeCommand.parse(["remove", "--profile", "alpha"])
    }
}

@Test func bootstrapRequiresAnExplicitInterpreter() {
    #expect(throws: RuntimeCommandError.missingOption("--python")) {
        try RuntimeCommand.parse(["bootstrap", "--profile", "alpha"])
    }
}

@Test func bootstrapParsesProfileAndInterpreter() throws {
    let command = try RuntimeCommand.parse([
        "bootstrap", "--profile", "alpha", "--python", "/opt/homebrew/bin/python3.12",
    ])
    #expect(command == .bootstrap(profile: "alpha", python: "/opt/homebrew/bin/python3.12"))
}

@Test(arguments: [
    (["start", "--profile", "alpha"], RuntimeCommand.start(profile: "alpha", exitWithParent: false)),
    // The app passes this so its runtime does not outlive it; a shell session leaves it off.
    (
        ["start", "--profile", "alpha", "--exit-with-parent"],
        RuntimeCommand.start(profile: "alpha", exitWithParent: true)
    ),
    (["status", "--profile", "alpha"], RuntimeCommand.status(profile: "alpha")),
    (["stop", "--profile", "alpha"], RuntimeCommand.stop(profile: "alpha")),
])
func lifecycleCommandsParseTheirProfile(_ arguments: [String], _ expected: RuntimeCommand) throws {
    #expect(try RuntimeCommand.parse(arguments) == expected)
}

@Test func benchmarkUsesRepresentativeDefaults() throws {
    let command = try RuntimeCommand.parse(["benchmark", "--profile", "alpha"])
    #expect(
        command == .benchmark(
            profile: "alpha",
            options: BenchmarkCLIOptions(
                seed: BenchmarkCLIOptions.defaultSeed,
                rooms: 2_000,
                messages: 100_000,
                importWorkers: 3
            )
        )
    )
}

@Test func benchmarkOverridesEveryWorkloadDimension() throws {
    let command = try RuntimeCommand.parse([
        "benchmark", "--profile", "alpha",
        "--seed", "20260813", "--rooms", "20", "--messages", "1000", "--import-workers", "2",
    ])
    #expect(
        command == .benchmark(
            profile: "alpha",
            options: BenchmarkCLIOptions(seed: 20_260_813, rooms: 20, messages: 1_000, importWorkers: 2)
        )
    )
}

@Test(arguments: ["0", "-1", "abc", "", "3.5"])
func benchmarkRejectsNonPositiveRoomCounts(_ value: String) {
    #expect(throws: RuntimeCommandError.invalidValue(option: "--rooms", value: value)) {
        try RuntimeCommand.parse(["benchmark", "--profile", "alpha", "--rooms", value])
    }
}

@Test func benchmarkRejectsANonNumericSeed() {
    #expect(throws: RuntimeCommandError.invalidValue(option: "--seed", value: "seed")) {
        try RuntimeCommand.parse(["benchmark", "--profile", "alpha", "--seed", "seed"])
    }
}

@Test func backupRequiresAName() {
    #expect(throws: RuntimeCommandError.missingOption("--name")) {
        try RuntimeCommand.parse(["backup", "--profile", "alpha"])
    }
}

@Test func backupParsesItsName() throws {
    let command = try RuntimeCommand.parse(["backup", "--profile", "alpha", "--name", "before-damage"])
    #expect(command == .backup(profile: "alpha", name: "before-damage"))
}

@Test func restoreRequiresABackupName() {
    #expect(throws: RuntimeCommandError.missingOption("--backup")) {
        try RuntimeCommand.parse(["restore", "--profile", "alpha"])
    }
}

@Test func verifyDefaultsToAPlainIntegrityCheck() throws {
    let command = try RuntimeCommand.parse(["verify", "--profile", "alpha"])
    #expect(
        command == .verify(
            profile: "alpha",
            options: VerifyCLIOptions(
                fixtureRooms: nil,
                simulateDataLoss: false,
                restoreBackup: nil,
                reportName: nil
            )
        )
    )
}

@Test func verifyParsesTheDestructiveRecoveryExercise() throws {
    let command = try RuntimeCommand.parse([
        "verify", "--profile", "alpha", "--simulate-data-loss", "--restore", "acceptance",
    ])
    #expect(
        command == .verify(
            profile: "alpha",
            options: VerifyCLIOptions(
                fixtureRooms: nil,
                simulateDataLoss: true,
                restoreBackup: "acceptance",
                reportName: nil
            )
        )
    )
}

@Test func verifyParsesFixtureRoomsAndReportSelector() throws {
    let command = try RuntimeCommand.parse([
        "verify", "--profile", "alpha", "--fixture-rooms", "10", "--report", "latest",
    ])
    #expect(
        command == .verify(
            profile: "alpha",
            options: VerifyCLIOptions(
                fixtureRooms: 10,
                simulateDataLoss: false,
                restoreBackup: nil,
                reportName: "latest"
            )
        )
    )
}

@Test func unknownCommandIsRejected() {
    #expect(throws: RuntimeCommandError.unknownCommand("destroy")) {
        try RuntimeCommand.parse(["destroy", "--profile", "alpha"])
    }
}

@Test func emptyArgumentsAreRejected() {
    #expect(throws: RuntimeCommandError.missingCommand) {
        try RuntimeCommand.parse([])
    }
}

@Test func unknownOptionIsRejected() {
    #expect(throws: RuntimeCommandError.unknownOption("--force")) {
        try RuntimeCommand.parse(["start", "--profile", "alpha", "--force"])
    }
}

@Test func optionWithoutAValueIsRejected() {
    #expect(throws: RuntimeCommandError.missingValue("--profile")) {
        try RuntimeCommand.parse(["start", "--profile"])
    }
}

@Test func repeatedOptionIsRejected() {
    #expect(throws: RuntimeCommandError.duplicateOption("--profile")) {
        try RuntimeCommand.parse(["start", "--profile", "alpha", "--profile", "beta"])
    }
}

@Test func aProfileNamedLikeAnOptionIsRejected() {
    #expect(throws: RuntimeCommandError.missingValue("--profile")) {
        try RuntimeCommand.parse(["start", "--profile", "--confirm"])
    }
}

@Test func positionalArgumentsAreRejected() {
    #expect(throws: RuntimeCommandError.unexpectedArgument("alpha")) {
        try RuntimeCommand.parse(["start", "alpha"])
    }
}

@Test func everyExitCodeIsDistinctAndStable() {
    let codes = RuntimeExitCode.allCases.map(\.rawValue)
    #expect(Set(codes).count == codes.count)
    #expect(RuntimeExitCode.success.rawValue == 0)
    #expect(RuntimeExitCode.usage.rawValue == 10)
    #expect(RuntimeExitCode.invalidTransition.rawValue == 20)
    #expect(RuntimeExitCode.unprepared.rawValue == 21)
    #expect(RuntimeExitCode.unavailableDependency.rawValue == 25)
    #expect(RuntimeExitCode.healthFailure.rawValue == 26)
    #expect(RuntimeExitCode.integrityFailure.rawValue == 27)
    #expect(RuntimeExitCode.benchmarkFailure.rawValue == 28)
    #expect(RuntimeExitCode.unsafePath.rawValue == 29)
}

@Test func usageErrorsAllMapToTheUsageExitCode() {
    let usageErrors: [RuntimeCommandError] = [
        .missingCommand,
        .unknownCommand("destroy"),
        .missingOption("--profile"),
        .missingValue("--profile"),
        .unknownOption("--force"),
        .duplicateOption("--profile"),
        .invalidValue(option: "--rooms", value: "0"),
        .unexpectedArgument("alpha"),
    ]
    for error in usageErrors {
        #expect(RuntimeExitCode(for: error) == .usage)
    }
}

@Test func runtimePathErrorsMapToTheUnsafePathExitCode() {
    #expect(RuntimeExitCode(for: RuntimePathError.escapesRoot(URL(fileURLWithPath: "/tmp"))) == .unsafePath)
    #expect(RuntimeExitCode(for: RuntimePathError.invalidProfileName("../escape")) == .unsafePath)
    #expect(
        RuntimeExitCode(for: RuntimePathError.symlinkedAncestor(URL(fileURLWithPath: "/tmp"))) == .unsafePath
    )
}

@Test func runtimeStateErrorsMapToTheirDocumentedExitCodes() {
    #expect(
        RuntimeExitCode(for: RuntimeStateError.invalidTransition(from: .healthy, to: .starting))
            == .invalidTransition
    )
    #expect(
        RuntimeExitCode(for: RuntimeStateError.shutdownIncomplete(processAlive: true, listenerPresence: .present))
            == .shutdownIncomplete
    )
}

@Test func bootstrapAndHealthFailuresMapToTheirDocumentedExitCodes() {
    #expect(
        RuntimeExitCode(
            for: RuntimeBootstrapError.unsupportedPythonVersion("3.13.1", requiredMinor: "3.12")
        ) == .unavailableDependency
    )
    #expect(
        RuntimeExitCode(
            for: SynapseSupervisorError.startupHealthTimeout(.versionsRequestFailed(status: 500))
        ) == .healthFailure
    )
    #expect(RuntimeExitCode(for: SynapseSupervisorError.healthCheckReportedStopped) == .healthFailure)
}

@Test func usageTextNamesEveryCommand() {
    let usage = RuntimeCommand.usage
    for command in ["bootstrap", "start", "status", "stop", "benchmark", "backup", "restore", "verify", "remove"] {
        #expect(usage.contains(command))
    }
}
