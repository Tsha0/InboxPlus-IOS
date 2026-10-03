import CryptoKit
import Darwin
import Foundation
import InboxPlusBridge
import InboxPlusRuntime

public enum LibolmError: Error, Equatable, Sendable, CustomStringConvertible {
    case cmakeMissing
    case downloadFailed(status: Int)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case patchDidNotApply
    case configureFailed(String)
    case buildFailed(String)
    case libraryMissingAfterBuild(URL)
    case cannotWrite(URL)

    public var description: String {
        switch self {
        case .cmakeMissing:
            "cmake is required to build libolm; install it with: brew install cmake"
        case let .downloadFailed(status):
            "downloading the libolm source failed with HTTP \(status)"
        case let .checksumMismatch(expected, actual):
            "the libolm source failed verification: expected SHA-256 \(expected), got \(actual)"
        case let .extractionFailed(reason):
            "could not extract the libolm source: \(reason)"
        case .patchDidNotApply:
            "the pinned libolm patch no longer matches its source; the pin must be reviewed"
        case let .configureFailed(reason):
            "configuring the libolm build failed: \(reason)"
        case let .buildFailed(reason):
            "building libolm failed: \(reason)"
        case let .libraryMissingAfterBuild(url):
            "libolm built but \(url.lastPathComponent) is not where it was expected"
        case let .cannotWrite(url):
            "cannot write \(url.path)"
        }
    }
}

/// Builds `libolm.3.dylib` from pinned source and installs it beside a bridge binary.
///
/// Every prebuilt mautrix binary links `@rpath/libolm.3.dylib`, but libolm reached end of life and
/// Homebrew no longer carries it, so nothing on a current macOS supplies the library. Building it
/// from a checksum-verified tarball keeps the provenance chain intact rather than committing an
/// opaque binary — the same discipline Phase 2 applies to the Synapse runtime.
///
/// dyld resolves `@rpath` against the loader's own directory first, so installing the dylib next to
/// the bridge binary needs no `DYLD_*` variables, which macOS strips from hardened processes anyway.
public struct LibolmProvisioner: Sendable {
    public static let version = "3.2.16"
    public static let libraryName = "libolm.3.dylib"
    /// SHA-256 of `olm-3.2.16.tar.gz` from the canonical Matrix.org GitLab archive.
    public static let sourceSHA256 =
        "1e90f9891009965fd064be747616da46b232086fe270b77605ec9bda34272a68"
    public static let sourceURL = URL(
        string: "https://gitlab.matrix.org/matrix-org/olm/-/archive/3.2.16/olm-3.2.16.tar.gz"
    )!

    /// libolm 3.2.16 does not compile with a current clang: `List::operator=` declares its cursor
    /// `T * const` and then increments it. The function has therefore never compiled anywhere, so
    /// it has never run, and it is also wrong in a second way — it dereferences the list rather
    /// than the cursor. libolm is archived, so upstream will not fix it.
    ///
    /// The patch is pinned as an exact before/after pair: if the source ever stops matching
    /// verbatim, the build fails loudly instead of applying a fuzzy edit to a crypto library.
    static let patchTarget = """
            T * this_pos = _data;
            T * const other_pos = other._data;
            while (other_pos != other._end) {
                *this_pos = *other;
                ++this_pos;
                ++other_pos;
            }
    """

    static let patchReplacement = """
            T * this_pos = _data;
            T const * other_pos = other._data;
            while (other_pos != other._end) {
                *this_pos = *other_pos;
                ++this_pos;
                ++other_pos;
            }
    """

    private let fetcher: any BridgeArtifactFetching
    private let cmake: URL?
    private let bundledLibrary: URL?

    public init(
        fetcher: any BridgeArtifactFetching = URLSessionBridgeArtifactFetcher(),
        cmake: URL? = LibolmProvisioner.locateCMake(),
        bundledLibrary: URL? = RuntimeProfileService.resolvedPackageRoot()
            .appendingPathComponent("Runtime/libolm.3.dylib")
    ) {
        self.fetcher = fetcher
        self.cmake = cmake
        self.bundledLibrary = bundledLibrary
    }

    public static func locateCMake() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/cmake",
            "/usr/local/bin/cmake",
            "/usr/bin/cmake",
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    public func isInstalled(in directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(Self.libraryName).path
        )
    }

    /// Ensures `libolm.3.dylib` sits in `directory`, building it if it is not already there.
    @discardableResult
    public func install(into directory: URL) async throws -> URL {
        let destination = directory.appendingPathComponent(Self.libraryName, isDirectory: false)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        if let bundledLibrary, FileManager.default.fileExists(atPath: bundledLibrary.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(at: bundledLibrary, to: destination)
            return destination
        }
        guard let cmake else { throw LibolmError.cmakeMissing }

        let workspace = directory.appendingPathComponent(".libolm-build", isDirectory: true)
        try? FileManager.default.removeItem(at: workspace)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tarball = workspace.appendingPathComponent("olm.tar.gz", isDirectory: false)
        let (status, body) = try await fetcher.fetch(Self.sourceURL)
        guard (200..<300).contains(status) else {
            throw LibolmError.downloadFailed(status: status)
        }
        let actual = BridgeInstaller.hash(body)
        guard actual == Self.sourceSHA256 else {
            throw LibolmError.checksumMismatch(expected: Self.sourceSHA256, actual: actual)
        }
        try body.write(to: tarball)

        try Self.run(
            URL(fileURLWithPath: "/usr/bin/tar"),
            ["xzf", tarball.path],
            in: workspace,
            failure: LibolmError.extractionFailed
        )
        let source = workspace.appendingPathComponent("olm-\(Self.version)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw LibolmError.extractionFailed("olm-\(Self.version) is not in the archive")
        }
        try applyPinnedPatch(in: source)

        let build = workspace.appendingPathComponent("build", isDirectory: true)
        try Self.run(
            cmake,
            [
                "-S", source.path,
                "-B", build.path,
                // libolm's archived build declares pre-3.5 policies, removed in CMake 4.
                // Set the supported compatibility floor externally without changing the source pin.
                "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
                "-DCMAKE_BUILD_TYPE=Release",
                "-DBUILD_SHARED_LIBS=ON",
                "-DOLM_TESTS=OFF",
                "-DCMAKE_OSX_ARCHITECTURES=arm64",
            ],
            in: workspace,
            failure: LibolmError.configureFailed
        )
        try Self.run(
            cmake,
            ["--build", build.path, "-j", "\(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))"],
            in: workspace,
            failure: LibolmError.buildFailed
        )

        let built = build.appendingPathComponent(Self.libraryName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: built.path) else {
            throw LibolmError.libraryMissingAfterBuild(built)
        }
        // Resolve first: cmake publishes `libolm.3.dylib` as a symlink to the versioned file, and
        // copying the link would leave a dangling pointer into a workspace this method deletes.
        let resolved = built.resolvingSymlinksInPath()
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: resolved, to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
        return destination
    }

    private func applyPinnedPatch(in source: URL) throws {
        let header = source.appendingPathComponent("include/olm/list.hh", isDirectory: false)
        guard let contents = try? String(contentsOf: header, encoding: .utf8),
              contents.contains(Self.patchTarget)
        else { throw LibolmError.patchDidNotApply }
        let patched = contents.replacingOccurrences(
            of: Self.patchTarget,
            with: Self.patchReplacement
        )
        try patched.write(to: header, atomically: true, encoding: .utf8)
    }

    private static func run(
        _ executable: URL,
        _ arguments: [String],
        in directory: URL,
        failure: (String) -> LibolmError
    ) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: output.suffix(2_048), as: UTF8.self)
            throw failure(text.isEmpty ? "exit status \(process.terminationStatus)" : text)
        }
    }
}
