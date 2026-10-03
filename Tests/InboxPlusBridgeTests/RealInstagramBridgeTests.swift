import Foundation
import Testing
@testable import InboxPlusBridge
@testable import InboxPlusBridgeService
@testable import InboxPlusRuntime

/// These exercise the genuine `mautrix-instagram` binary against a genuine Synapse, so they need a
/// Python interpreter and network access. Opt in exactly as the Phase 2 and Phase 3 live tests do:
///
///     INBOXPLUS_RUNTIME_PYTHON=/opt/homebrew/opt/python@3.12/bin/python3.12 swift test
///
/// Nothing here touches a real Instagram account: the login flow is read and the first step is
/// requested, which is as far as anything can go without credentials.
private enum LiveBridgeEnvironment {
    static var python: URL? {
        guard let path = ProcessInfo.processInfo.environment["INBOXPLUS_RUNTIME_PYTHON"],
              !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Under the repository rather than the system temporary directory, which lives beneath the
    /// `/var` symlink that `RuntimePaths` refuses.
    static func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/InboxPlusLiveBridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            // The bootstrapper insists the runtime root be user-only, as it is in production.
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }
}

@Test(.timeLimit(.minutes(10)))
func realInstagramBridgeInstallsConfiguresRegistersAndServesItsLoginFlow() async throws {
    guard let python = LiveBridgeEnvironment.python else { return }

    let root = try LiveBridgeEnvironment.makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = try RuntimePaths(root: root, profileName: "livebridge")
    let service = RuntimeProfileService(
        paths: paths,
        packageRoot: RuntimeProfileService.resolvedPackageRoot()
    )
    try await service.bootstrap(python: python)

    let state = try #require(try service.loadState())
    let ownerUserID = "@inboxplus:\(state.serverName)"
    let runtime = BridgeRuntime(paths: paths)
    let descriptor = try BridgeCatalog.require(.instagram)

    // Preparing must happen while the homeserver is stopped: Synapse reads
    // `app_service_config_files` once, at startup.
    let record = try await runtime.prepare(
        descriptor,
        serverName: state.serverName,
        homeserverPort: 8_008,
        ownerUserID: ownerUserID
    )

    #expect(record.sha256 == descriptor.artifact?.sha256, "the pinned checksum must be what ran")
    #expect(FileManager.default.isExecutableFile(atPath: record.executable))
    // The prebuilt binaries link @rpath/libolm.3.dylib, which no current macOS supplies.
    let bridgeDirectory = URL(fileURLWithPath: record.executable).deletingLastPathComponent()
    #expect(
        FileManager.default.fileExists(
            atPath: bridgeDirectory.appendingPathComponent(LibolmProvisioner.libraryName).path
        ),
        "libolm must be installed beside the binary or the bridge cannot even load"
    )

    // The bridge generated its own registration, and Synapse can see it.
    let published = runtime.appServiceDirectory
        .appendingPathComponent("\(descriptor.id).yaml", isDirectory: false)
    #expect(FileManager.default.fileExists(atPath: published.path))
    let tokens = try BridgeAppserviceTokens.read(
        fromRegistrationAt: URL(fileURLWithPath: record.registrationFile)
    )
    #expect(tokens.asToken.count >= 32)
    #expect(tokens.hsToken.count >= 32)
    #expect(tokens.asToken != tokens.hsToken)

    // The config carries the tokens back, or the bridge refuses to start.
    let configuration = try String(
        contentsOf: URL(fileURLWithPath: record.configurationFile),
        encoding: .utf8
    )
    #expect(configuration.contains("as_token: '\(tokens.asToken)'"))

    try await service.withRunningRuntime { _, context in
        try runtime.rebindToHomeserver(port: context.port)
        let supervisor = try runtime.makeSupervisor(for: record)
        let snapshot = try await supervisor.start()
        #expect(snapshot.phase == .healthy, "the bridge must reach an authenticated health check")

        let client = try runtime.provisioningClient(for: record)
        let flows = try await client.loginFlows()
        #expect(flows.map(\.id) == ["instagram"])
        try runtime.detectFlowDrift(descriptor, advertised: flows)

        // The first real step: what Inbox+'s cookie view will be asked to render.
        let step = try await client.startLogin(flowID: "instagram")
        #expect(step.type == .cookies)
        #expect(step.loginID?.isEmpty == false, "a login attempt must be identifiable")
        #expect(step.cookies?.url.hasPrefix("https://www.instagram.com/") == true)
        #expect(
            Set(step.cookies?.requiredFieldIDs ?? [])
                == ["sessionid", "csrftoken", "ds_user_id", "mid", "ig_did"]
        )
        #expect(step.cookies?.waitForURLPattern?.isEmpty == false)

        // An incomplete cookie set is refused, and Inbox+ catches it before it ever gets this far.
        #expect(throws: (any Error).self) { try step.validate(["sessionid": "x"]) }

        _ = try? await supervisor.stop()
    }
}

@Test(.timeLimit(.minutes(10)))
func aBridgeWithoutItsProvisioningSecretIsReportedDegradedRatherThanHealthy() async throws {
    guard let python = LiveBridgeEnvironment.python else { return }

    let root = try LiveBridgeEnvironment.makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = try RuntimePaths(root: root, profileName: "livebridgeauth")
    let service = RuntimeProfileService(
        paths: paths,
        packageRoot: RuntimeProfileService.resolvedPackageRoot()
    )
    try await service.bootstrap(python: python)

    let state = try #require(try service.loadState())
    let runtime = BridgeRuntime(paths: paths)
    let descriptor = try BridgeCatalog.require(.instagram)
    let record = try await runtime.prepare(
        descriptor,
        serverName: state.serverName,
        homeserverPort: 8_008,
        ownerUserID: "@inboxplus:\(state.serverName)"
    )

    try await service.withRunningRuntime { _, context in
        try runtime.rebindToHomeserver(port: context.port)
        let supervisor = try runtime.makeSupervisor(for: record)
        let snapshot = try await supervisor.start()

        // A live socket is not health: a bridge whose secret no longer matches is useless to Inbox+,
        // and a liveness ping would call it healthy.
        let wrongSecret = try BridgeHealthChecker(
            provisioningBaseURL: record.provisioningBaseURL,
            provisioningSecret: "0000000000000000000000000000000000000000",
            userID: record.ownerUserID
        )
        let result = await wrongSecret.check(snapshot: snapshot)
        guard case let .degraded(failure) = result else {
            Issue.record("expected degraded, got \(result)")
            _ = try? await supervisor.stop()
            return
        }
        #expect(failure == .matrixRequestFailed(status: 401))

        _ = try? await supervisor.stop()
    }
}
