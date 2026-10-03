import Foundation
import Testing
@testable import InboxPlusRuntime

private func makeProfile() throws -> (RuntimePaths, URL) {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/DiagnosticsBundleTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
    )
    let paths = try RuntimePaths(root: root, profileName: "demo")
    for directory in [paths.logs, paths.configuration, paths.data, paths.state] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    return (paths, root)
}

private let redactor = DiagnosticsRedactor(knownSecrets: [], salt: "fixed")

@Test func aBundleContainsLogsAndConfigurationWithSecretsRemoved() throws {
    let (paths, root) = try makeProfile()
    defer { try? FileManager.default.removeItem(at: root) }

    try "starting\nAuthorization: Bearer secrettokenvalue\nready"
        .write(to: paths.logs.appendingPathComponent("stderr.log"), atomically: true, encoding: .utf8)
    try "as_token: J9aGsgSecretTokenValue\nport: 8008"
        .write(to: paths.configuration.appendingPathComponent("homeserver.yaml"), atomically: true, encoding: .utf8)

    let destination = root.appendingPathComponent("bundle")
    let manifest = try DiagnosticsBundle(paths: paths, redactor: redactor)
        .write(to: destination, inboxplusVersion: "0.5.0")

    #expect(manifest.entries.map(\.name).sorted() == ["homeserver.yaml", "stderr.log"])

    let log = try String(contentsOf: destination.appendingPathComponent("stderr.log"), encoding: .utf8)
    #expect(!log.contains("secrettokenvalue"))
    #expect(log.contains("starting"))

    let config = try String(contentsOf: destination.appendingPathComponent("homeserver.yaml"), encoding: .utf8)
    #expect(!config.contains("J9aGsgSecretTokenValue"))
    // The parts that make it worth collecting survive.
    #expect(config.contains("port: 8008"))
}

@Test func theDatabaseAndKeyMaterialAreNeverCollected() throws {
    let (paths, root) = try makeProfile()
    defer { try? FileManager.default.removeItem(at: root) }

    // Placed where the collector walks, to prove the exclusion is by name and not by luck.
    try "sqlite-ish".write(to: paths.logs.appendingPathComponent("homeserver.db"), atomically: true, encoding: .utf8)
    try "PRIVATEKEY".write(to: paths.configuration.appendingPathComponent("signing.key"), atomically: true, encoding: .utf8)

    let destination = root.appendingPathComponent("bundle")
    let manifest = try DiagnosticsBundle(paths: paths, redactor: redactor)
        .write(to: destination, inboxplusVersion: "0.5.0")

    #expect(manifest.entries.isEmpty)
    #expect(manifest.excluded.count == 2)
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("signing.key").path))
    // An absence is stated, so it is never mistaken for a collection bug.
    #expect(manifest.excluded.contains { $0.contains("signing.key") })
}

@Test func aKeyWhoseNameIsPrefixedIsStillExcluded() throws {
    // Found by running the export against a real profile: the homeserver's key is called
    // `inboxplus.signing.key`, and an exact-name blocklist let the raw ed25519 key into the bundle.
    let (paths, root) = try makeProfile()
    defer { try? FileManager.default.removeItem(at: root) }

    try "ed25519 a_AWOo KkA3CU2boZACuP3SPIiVQ6k3cDzEehbAK3OiKEw5JUQ".write(
        to: paths.configuration.appendingPathComponent("inboxplus.signing.key"),
        atomically: true, encoding: .utf8
    )
    try #"{"accessToken":"opaque-value","userID":"@a:b"}"#.write(
        to: paths.configuration.appendingPathComponent("inboxplus-probe-credential.json"),
        atomically: true, encoding: .utf8
    )

    let destination = root.appendingPathComponent("bundle")
    let manifest = try DiagnosticsBundle(paths: paths, redactor: redactor)
        .write(to: destination, inboxplusVersion: "0.5.0")

    #expect(manifest.entries.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("inboxplus.signing.key").path))
    #expect(!FileManager.default.fileExists(
        atPath: destination.appendingPathComponent("inboxplus-probe-credential.json").path
    ))
}

@Test(arguments: [
    "inboxplus.signing.key", "signing.key", "homeserver.db", "homeserver.db-wal",
    "inboxplus-probe-credential.json", "as_token.txt", "my-secret.yaml", "user.keychain",
])
func anyNameSuggestingKeyMaterialIsRefused(_ name: String) {
    // Fails safe on purpose: excluding a log is a nuisance, including a key is a compromise.
    #expect(DiagnosticsBundle.isExcluded(name))
}

@Test(arguments: ["stderr.log", "homeserver.yaml", "config.yaml", "registration.yaml"])
func ordinaryDiagnosticFilesAreStillCollected(_ name: String) {
    #expect(!DiagnosticsBundle.isExcluded(name))
}

@Test func nothingOutsideLogsAndConfigurationIsEvenWalked() throws {
    let (paths, root) = try makeProfile()
    defer { try? FileManager.default.removeItem(at: root) }

    try "@maya:s.example private".write(
        to: paths.state.appendingPathComponent("bridges.json"), atomically: true, encoding: .utf8
    )
    let destination = root.appendingPathComponent("bundle")
    let manifest = try DiagnosticsBundle(paths: paths, redactor: redactor)
        .write(to: destination, inboxplusVersion: "0.5.0")

    #expect(manifest.entries.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("bridges.json").path))
}

@Test func aBundleIsWrittenUserOnly() throws {
    let (paths, root) = try makeProfile()
    defer { try? FileManager.default.removeItem(at: root) }
    try "hello".write(to: paths.logs.appendingPathComponent("stderr.log"), atomically: true, encoding: .utf8)

    let destination = root.appendingPathComponent("bundle")
    _ = try DiagnosticsBundle(paths: paths, redactor: redactor)
        .write(to: destination, inboxplusVersion: "0.5.0")

    let directory = try FileManager.default.attributesOfItem(atPath: destination.path)
    #expect(directory[.posixPermissions] as? Int == 0o700)
    let file = try FileManager.default.attributesOfItem(
        atPath: destination.appendingPathComponent("stderr.log").path
    )
    #expect(file[.posixPermissions] as? Int == 0o600)
}

@Test func anEnormousLogIsTruncatedToItsEndAndSaysSo() throws {
    let (paths, root) = try makeProfile()
    defer { try? FileManager.default.removeItem(at: root) }

    let lines = (0 ..< 5_000).map { "line \($0)" }.joined(separator: "\n")
    try lines.write(to: paths.logs.appendingPathComponent("stderr.log"), atomically: true, encoding: .utf8)

    let destination = root.appendingPathComponent("bundle")
    let manifest = try DiagnosticsBundle(paths: paths, redactor: redactor, maximumBytesPerFile: 2_000)
        .write(to: destination, inboxplusVersion: "0.5.0")

    let entry = try #require(manifest.entries.first)
    #expect(entry.truncated)
    let text = try String(contentsOf: destination.appendingPathComponent("stderr.log"), encoding: .utf8)
    // The end of a log is the part worth having.
    #expect(text.contains("line 4999"))
    #expect(!text.contains("line 0\n"))
}

@Test func truncationNeverStartsMidLine() {
    let (text, truncated) = DiagnosticsBundle.tail(of: "aaaa\nbbbb\ncccc", limit: 8)
    #expect(truncated)
    #expect(text == "cccc" || text == "bbbb\ncccc")
    #expect(!text.hasPrefix("bb\n"))
}

@Test func aManifestNamesTheVersionAndProfileThatProducedIt() throws {
    let (paths, root) = try makeProfile()
    defer { try? FileManager.default.removeItem(at: root) }
    try "x".write(to: paths.logs.appendingPathComponent("stderr.log"), atomically: true, encoding: .utf8)

    let destination = root.appendingPathComponent("bundle")
    let manifest = try DiagnosticsBundle(paths: paths, redactor: redactor)
        .write(to: destination, inboxplusVersion: "0.5.0")

    #expect(manifest.inboxplusVersion == "0.5.0")
    #expect(manifest.profileName == "demo")

    // The manifest is on disk too, so the bundle explains itself without this process.
    let data = try Data(contentsOf: destination.appendingPathComponent("manifest.json"))
    let decoded = try JSONDecoder().decode(DiagnosticsManifest.self, from: data)
    #expect(decoded == manifest)
}
