import Darwin
import Foundation
import Testing
@testable import InboxPlusBridgeService

/// Opt-in because this downloads the checksum-pinned source and invokes a real C++ toolchain.
/// INBOXPLUS_LIBOLM_TEST_CMAKE=/path/to/cmake swift test --filter libolmBuildsWithSelectedCMake
@Test(.enabled(if: ProcessInfo.processInfo.environment["INBOXPLUS_LIBOLM_TEST_CMAKE"] != nil))
func libolmBuildsWithSelectedCMake() async throws {
    let cmakePath = try #require(ProcessInfo.processInfo.environment["INBOXPLUS_LIBOLM_TEST_CMAKE"])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("InboxPlusLibolmBuild-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try await LibolmProvisioner(
        cmake: URL(fileURLWithPath: cmakePath), bundledLibrary: nil
    ).install(into: root)
    let handle = try #require(dlopen(library.path, RTLD_NOW | RTLD_LOCAL))
    defer { dlclose(handle) }
    let symbol = try #require(dlsym(handle, "olm_get_library_version"))
    typealias VersionFunction = @convention(c) (
        UnsafeMutablePointer<UInt8>, UnsafeMutablePointer<UInt8>, UnsafeMutablePointer<UInt8>
    ) -> Void
    let version = unsafeBitCast(symbol, to: VersionFunction.self)
    var major: UInt8 = 0, minor: UInt8 = 0, patch: UInt8 = 0
    version(&major, &minor, &patch)
    #expect("\(major).\(minor).\(patch)" == LibolmProvisioner.version)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".libolm-build").path))
}
