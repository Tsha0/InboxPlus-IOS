import Darwin
import Foundation
import Testing
@testable import InboxPlusRuntime

@Test(.enabled(if: ProcessInfo.processInfo.environment["INBOXPLUS_RUNTIME_PYTHON"] != nil))
func realSupervisorReachesAuthenticatedHealthAndStopsWithoutResidue() async throws {
    // Break caught: unit doubles hide an incompatible Synapse launch, shared-secret registration, or shutdown route.
    let pythonPath = try #require(ProcessInfo.processInfo.environment["INBOXPLUS_RUNTIME_PYTHON"])
    let cache = try realSupervisorDarwinCacheDirectory()
    let root = try realSupervisorCanonicalFileURL(cache)
        .appendingPathComponent("InboxPlusRuntimeTests", isDirectory: true)
    let profileName = "supervisor-real"
    let profile = root.appendingPathComponent(profileName, isDirectory: true)
    try? FileManager.default.removeItem(at: profile)
    defer { try? FileManager.default.removeItem(at: profile) }

    let paths = try RuntimePaths(root: root, profileName: profileName)
    let sourceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let manifest = try RuntimeManifest.load(
        from: sourceRoot.appendingPathComponent("Runtime/Synapse/runtime-manifest.json")
    )
    _ = try await RuntimeBootstrapper(
        requirementsLock: sourceRoot.appendingPathComponent("Runtime/Synapse/requirements.lock")
    ).bootstrap(
        python: URL(fileURLWithPath: pythonPath),
        manifest: manifest,
        paths: paths
    )

    let port = try allocateDisposableLoopbackPort()
    let registrationSecret = UUID().uuidString + UUID().uuidString
    let synapseConfiguration = SynapseConfiguration(
        profile: paths,
        port: port,
        credentials: SynapseCredentials(registrationSecret: registrationSecret)
    )
    let configurationFile = try synapseConfiguration.write()
    let virtualPython = paths.runtime.appendingPathComponent("venv/bin/python")
    try generateSynapseKeys(python: virtualPython, configurationFile: configurationFile)
    let stablePythonExecutable = try stablePythonApplicationExecutable(virtualPython: virtualPython)

    let healthChecker = try SynapseHealthChecker(
        baseURL: URL(string: "http://127.0.0.1:\(port)")!,
        serverName: synapseConfiguration.serverName,
        registrationSecret: registrationSecret,
        credentialStore: try SynapseProbeCredentialStore(profileRoot: paths.profile)
    )
    let processConfiguration = ManagedProcessConfiguration(
        executable: stablePythonExecutable,
        arguments: [
            "-m", "synapse.app.homeserver",
            "--config-path", configurationFile.path,
        ],
        environment: [
            "PATH": paths.runtime.appendingPathComponent("venv/bin").path + ":/usr/bin:/bin",
            "PYTHONUNBUFFERED": "1",
            "__PYVENV_LAUNCHER__": virtualPython.path,
        ],
        workingDirectory: paths.profile,
        profileRoot: paths.profile,
        logsDirectory: paths.logs,
        standardOutputLog: paths.logs.appendingPathComponent("stdout.log"),
        standardErrorLog: paths.logs.appendingPathComponent("stderr.log"),
        sensitiveLogValues: [registrationSecret]
    )
    let supervisor = SynapseSupervisor(
        configuration: processConfiguration,
        loopbackPort: port,
        healthChecker: healthChecker
    )

    do {
        let healthy = try await supervisor.start()
        #expect(healthy.phase == .healthy)
        #expect(healthy.processIdentity != nil)
        guard case .healthy = await healthChecker.check(snapshot: healthy) else {
            Issue.record("authenticated probe health did not remain healthy")
            _ = try? await supervisor.stop()
            return
        }
        let credential = try SynapseProbeCredentialStore(profileRoot: paths.profile).load()
        #expect(credential?.userID == "@inboxplus_probe:inboxplus.localhost")
        #expect(try SynapseProbeCredentialStore(profileRoot: paths.profile).fileMode() == 0o600)

        let stopped = try await supervisor.stop()
        #expect(stopped.phase == .stopped)
        #expect(await SystemLoopbackListenerChecker().presence(on: port) == .absent)

        let secretValues = [registrationSecret, credential?.accessToken].compactMap { $0 }
        for log in ["stdout.log", "stderr.log"] {
            let url = paths.logs.appendingPathComponent(log)
            let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for secret in secretValues { #expect(!contents.contains(secret)) }
        }
    } catch {
        _ = try? await supervisor.stop()
        throw error
    }

    try FileManager.default.removeItem(at: paths.profile)
    #expect(!FileManager.default.fileExists(atPath: paths.profile.path))
}

private func generateSynapseKeys(python: URL, configurationFile: URL) throws {
    let process = Process()
    process.executableURL = python
    process.arguments = [
        "-m", "synapse.app.homeserver",
        "--config-path", configurationFile.path,
        "--generate-keys",
    ]
    process.environment = [
        "PATH": python.deletingLastPathComponent().path + ":/usr/bin:/bin",
    ]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw RealSupervisorTestError.keyGenerationFailed(process.terminationStatus)
    }
}

private func stablePythonApplicationExecutable(virtualPython: URL) throws -> URL {
    let process = Process()
    process.executableURL = virtualPython
    process.arguments = ["-c", "import sys; print(sys._base_executable)"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          let path = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
          )?.trimmingCharacters(in: .whitespacesAndNewlines),
          path.hasPrefix("/")
    else {
        throw RealSupervisorTestError.pythonExecutableUnavailable
    }
    let baseExecutable = URL(fileURLWithPath: path)
    let applicationExecutable = baseExecutable
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/Python.app/Contents/MacOS/Python")
    guard FileManager.default.isExecutableFile(atPath: applicationExecutable.path) else {
        throw RealSupervisorTestError.pythonExecutableUnavailable
    }
    return applicationExecutable
}

private func allocateDisposableLoopbackPort() throws -> UInt16 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw RealSupervisorTestError.portAllocationFailed }
    defer { _ = close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { throw RealSupervisorTestError.portAllocationFailed }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let read = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(descriptor, $0, &length)
        }
    }
    guard read == 0 else { throw RealSupervisorTestError.portAllocationFailed }
    return UInt16(bigEndian: address.sin_port)
}

private func realSupervisorCanonicalFileURL(_ url: URL) throws -> URL {
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
        throw RealSupervisorTestError.missingPhysicalCacheDirectory
    }
    return physicalDataVolumeURL
}

private func realSupervisorDarwinCacheDirectory() throws -> URL {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/getconf")
    process.arguments = ["DARWIN_USER_CACHE_DIR"]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          let path = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
          )?.trimmingCharacters(in: .whitespacesAndNewlines),
          !path.isEmpty
    else {
        throw RealSupervisorTestError.missingDarwinCache
    }
    return URL(fileURLWithPath: path, isDirectory: true)
}

private enum RealSupervisorTestError: Error {
    case missingDarwinCache
    case missingPhysicalCacheDirectory
    case portAllocationFailed
    case keyGenerationFailed(Int32)
    case pythonExecutableUnavailable
}
