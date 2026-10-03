import Foundation
import InboxPlusRuntime

public struct BenchmarkCLIOptions: Equatable, Sendable {
    public static let defaultSeed: UInt64 = 20_260_813
    public static let defaultRooms = 2_000
    public static let defaultMessages = 100_000
    public static let defaultImportWorkers = 3

    public let seed: UInt64
    public let rooms: Int
    public let messages: Int
    public let importWorkers: Int

    public init(seed: UInt64, rooms: Int, messages: Int, importWorkers: Int) {
        self.seed = seed
        self.rooms = rooms
        self.messages = messages
        self.importWorkers = importWorkers
    }
}

public struct VerifyCLIOptions: Equatable, Sendable {
    public let fixtureRooms: Int?
    public let simulateDataLoss: Bool
    public let restoreBackup: String?
    public let reportName: String?

    public init(
        fixtureRooms: Int?,
        simulateDataLoss: Bool,
        restoreBackup: String?,
        reportName: String?
    ) {
        self.fixtureRooms = fixtureRooms
        self.simulateDataLoss = simulateDataLoss
        self.restoreBackup = restoreBackup
        self.reportName = reportName
    }
}

public enum BridgeCLIAction: String, Equatable, Sendable, CaseIterable {
    /// Download and checksum-verify the binary, and build the libolm it links against.
    case install
    /// Install, then configure and register the bridge with this profile's homeserver.
    case prepare
    /// Start the homeserver and the bridge, and print the login flows the bridge really advertises.
    case flows
    /// List what is prepared for this profile.
    case list
}

public enum RuntimeCommand: Equatable, Sendable {
    case bridge(profile: String, action: BridgeCLIAction, network: String?)
    case bootstrap(profile: String, python: String)
    case start(profile: String, exitWithParent: Bool)
    case status(profile: String)
    case stop(profile: String)
    case benchmark(profile: String, options: BenchmarkCLIOptions)
    case backup(profile: String, name: String)
    case restore(profile: String, backup: String)
    case verify(profile: String, options: VerifyCLIOptions)
    case remove(profile: String, confirmation: String, exportReport: String?)
    /// Emits the software bill of materials. Describes what Inbox+ ships, so it needs no profile.
    case sbom(output: String?)
    /// Exports a redacted diagnostics bundle a user can safely attach to a bug report.
    case diagnostics(profile: String, output: String)

    /// `nil` for commands that do not act on a profile.
    public var profile: String? {
        switch self {
        case .sbom:
            nil
        case let .bootstrap(profile, _),
             let .start(profile, _),
             let .status(profile),
             let .stop(profile),
             let .benchmark(profile, _),
             let .backup(profile, _),
             let .restore(profile, _),
             let .verify(profile, _),
             let .remove(profile, _, _),
             let .bridge(profile, _, _),
             let .diagnostics(profile, _):
            profile
        }
    }

    /// True when the command only reads runtime state and must not take the exclusive profile lock.
    public var observesOnly: Bool {
        if case .status = self { return true }
        if case .diagnostics = self { return true }
        if case let .bridge(_, action, _) = self { return action == .list }
        return false
    }

    public static let usage = """
    Usage: InboxPlusRuntimeCLI <command> [options]

    Commands:
      bootstrap --profile <name> --python <path>
          Prepare the pinned profile-local Synapse runtime.
      start --profile <name> [--exit-with-parent]
          Launch the supervised loopback-only Synapse process and every prepared bridge.
          --exit-with-parent also stops when the launching process goes away, which is how
          the app takes its runtime down with it even if the app is killed outright.
      status --profile <name>
          Report the persisted lifecycle phase and health.
      stop --profile <name>
          Gracefully stop the supervised process and verify the listener is gone.
      benchmark --profile <name> [--seed <n>] [--rooms <n>] [--messages <n>] [--import-workers <n>]
          Run the representative concurrent workload and write a redacted report.
      backup --profile <name> --name <backup>
          Create an offline, checksummed backup of a stopped profile.
      restore --profile <name> --backup <backup>
          Restore a verified backup into an empty profile.
      verify --profile <name> [--fixture-rooms <n>] [--simulate-data-loss] [--restore <backup>] [--report <name>]
          Verify the prepared runtime, fixtures, reports, or destructive recovery.
      remove --profile <name> --confirm <name> [--export-report <path>]
          Stop and remove exactly one contained profile after confirmation.
      bridge --profile <name> --action <install|prepare|flows|list> [--network <platform>]
          Install, configure, or interrogate a network bridge for this profile.
          Networks: instagram, facebookMessenger, whatsApp, telegram, iMessage,
          googleMessages, googleVoice.
      diagnostics --profile <name> --output <path>
          Export a redacted diagnostics bundle that is safe to attach to a bug report.
      sbom [--output <path>]
          Emit the CycloneDX software bill of materials.
    """

    public static func parse(_ arguments: [String]) throws -> RuntimeCommand {
        guard let name = arguments.first else { throw RuntimeCommandError.missingCommand }
        let tokens = Array(arguments.dropFirst())

        switch name {
        case "bootstrap":
            let options = try Options(tokens, valued: ["--profile", "--python"], flags: [])
            return .bootstrap(
                profile: try options.require("--profile"),
                python: try options.require("--python")
            )
        case "start":
            let options = try Options(tokens, valued: ["--profile"], flags: ["--exit-with-parent"])
            return .start(
                profile: try options.require("--profile"),
                exitWithParent: options.flag("--exit-with-parent")
            )
        case "status":
            let options = try Options(tokens, valued: ["--profile"], flags: [])
            return .status(profile: try options.require("--profile"))
        case "stop":
            let options = try Options(tokens, valued: ["--profile"], flags: [])
            return .stop(profile: try options.require("--profile"))
        case "benchmark":
            let options = try Options(
                tokens,
                valued: ["--profile", "--seed", "--rooms", "--messages", "--import-workers"],
                flags: []
            )
            return .benchmark(
                profile: try options.require("--profile"),
                options: BenchmarkCLIOptions(
                    seed: try options.unsignedInteger("--seed", default: BenchmarkCLIOptions.defaultSeed),
                    rooms: try options.positiveInteger("--rooms", default: BenchmarkCLIOptions.defaultRooms),
                    messages: try options.positiveInteger(
                        "--messages",
                        default: BenchmarkCLIOptions.defaultMessages
                    ),
                    importWorkers: try options.positiveInteger(
                        "--import-workers",
                        default: BenchmarkCLIOptions.defaultImportWorkers
                    )
                )
            )
        case "backup":
            let options = try Options(tokens, valued: ["--profile", "--name"], flags: [])
            return .backup(
                profile: try options.require("--profile"),
                name: try options.require("--name")
            )
        case "restore":
            let options = try Options(tokens, valued: ["--profile", "--backup"], flags: [])
            return .restore(
                profile: try options.require("--profile"),
                backup: try options.require("--backup")
            )
        case "verify":
            let options = try Options(
                tokens,
                valued: ["--profile", "--fixture-rooms", "--restore", "--report"],
                flags: ["--simulate-data-loss"]
            )
            return .verify(
                profile: try options.require("--profile"),
                options: VerifyCLIOptions(
                    fixtureRooms: try options.optionalPositiveInteger("--fixture-rooms"),
                    simulateDataLoss: options.flag("--simulate-data-loss"),
                    restoreBackup: options.value("--restore"),
                    reportName: options.value("--report")
                )
            )
        case "bridge":
            let options = try Options(
                tokens,
                valued: ["--profile", "--action", "--network"],
                flags: []
            )
            let raw = try options.require("--action")
            guard let action = BridgeCLIAction(rawValue: raw) else {
                throw RuntimeCommandError.invalidValue(option: "--action", value: raw)
            }
            let network = options.value("--network")
            if action != .list, network == nil {
                throw RuntimeCommandError.missingOption("--network")
            }
            return .bridge(
                profile: try options.require("--profile"),
                action: action,
                network: network
            )
        case "diagnostics":
            let options = try Options(tokens, valued: ["--profile", "--output"], flags: [])
            return .diagnostics(
                profile: try options.require("--profile"),
                output: try options.require("--output")
            )
        case "sbom":
            let options = try Options(tokens, valued: ["--output"], flags: [])
            return .sbom(output: options.value("--output"))
        case "remove":
            let options = try Options(
                tokens,
                valued: ["--profile", "--confirm", "--export-report"],
                flags: []
            )
            return .remove(
                profile: try options.require("--profile"),
                confirmation: try options.require("--confirm"),
                exportReport: options.value("--export-report")
            )
        default:
            throw RuntimeCommandError.unknownCommand(name)
        }
    }
}

private struct Options {
    private var values: [String: String] = [:]
    private var presentFlags: Set<String> = []

    init(_ tokens: [String], valued: Set<String>, flags: Set<String>) throws {
        var seen: Set<String> = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            guard token.hasPrefix("--") else {
                throw RuntimeCommandError.unexpectedArgument(token)
            }
            if flags.contains(token) {
                guard seen.insert(token).inserted else {
                    throw RuntimeCommandError.duplicateOption(token)
                }
                presentFlags.insert(token)
                index += 1
                continue
            }
            guard valued.contains(token) else {
                throw RuntimeCommandError.unknownOption(token)
            }
            guard seen.insert(token).inserted else {
                throw RuntimeCommandError.duplicateOption(token)
            }
            guard index + 1 < tokens.count else {
                throw RuntimeCommandError.missingValue(token)
            }
            let value = tokens[index + 1]
            guard !value.hasPrefix("--") else {
                throw RuntimeCommandError.missingValue(token)
            }
            values[token] = value
            index += 2
        }
    }

    func value(_ option: String) -> String? { values[option] }

    func flag(_ option: String) -> Bool { presentFlags.contains(option) }

    func require(_ option: String) throws -> String {
        guard let value = values[option] else {
            throw RuntimeCommandError.missingOption(option)
        }
        return value
    }

    func positiveInteger(_ option: String, default fallback: Int) throws -> Int {
        guard let raw = values[option] else { return fallback }
        guard let parsed = Int(raw), parsed > 0 else {
            throw RuntimeCommandError.invalidValue(option: option, value: raw)
        }
        return parsed
    }

    func optionalPositiveInteger(_ option: String) throws -> Int? {
        guard let raw = values[option] else { return nil }
        guard let parsed = Int(raw), parsed > 0 else {
            throw RuntimeCommandError.invalidValue(option: option, value: raw)
        }
        return parsed
    }

    func unsignedInteger(_ option: String, default fallback: UInt64) throws -> UInt64 {
        guard let raw = values[option] else { return fallback }
        guard let parsed = UInt64(raw) else {
            throw RuntimeCommandError.invalidValue(option: option, value: raw)
        }
        return parsed
    }
}

public enum RuntimeCommandError: Error, Equatable, Sendable {
    case missingCommand
    case unknownCommand(String)
    case missingOption(String)
    case missingValue(String)
    case unknownOption(String)
    case duplicateOption(String)
    case invalidValue(option: String, value: String)
    case unexpectedArgument(String)

    public var diagnostic: String {
        switch self {
        case .missingCommand:
            "no command given"
        case let .unknownCommand(name):
            "unknown command '\(name)'"
        case let .missingOption(option):
            "missing required option \(option)"
        case let .missingValue(option):
            "option \(option) requires a value"
        case let .unknownOption(option):
            "unknown option \(option)"
        case let .duplicateOption(option):
            "option \(option) was given more than once"
        case let .invalidValue(option, value):
            "option \(option) rejected the value '\(value)'"
        case let .unexpectedArgument(argument):
            "unexpected argument '\(argument)'"
        }
    }
}
