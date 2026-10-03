// swift-tools-version: 6.2
import PackageDescription
import Foundation
let package: Package
if ProcessInfo.processInfo.environment["INBOXPLUS_BUILD_COMPANION"] == "1" {
package = Package(
    name: "InboxPlus",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "InboxPlus", targets: ["InboxPlusApp"]),
        .executable(name: "InboxPlusCompanion", targets: ["InboxPlusCompanion"]),
        .library(name: "InboxPlusRuntime", targets: ["InboxPlusRuntime"]),
        .executable(name: "InboxPlusRuntimeCLI", targets: ["InboxPlusRuntimeCLI"]),
    ],
    dependencies: [
        // Pinned exactly: the SDK ships a checksum-verified binary xcframework, and bridge/SDK
        // protocol drift must never arrive silently through a version range.
        .package(url: "https://github.com/matrix-org/matrix-rust-components-swift", exact: "26.08.11"),
    ],
    targets: [
        .target(name: "InboxPlusRemote", dependencies: ["InboxPlusCore", "InboxPlusGateway", "InboxPlusBridge"]),
        .target(name: "InboxPlusCompanionServer", dependencies: ["InboxPlusRemote"]),
        .executableTarget(name: "InboxPlusCompanion", dependencies: ["InboxPlusCompanionServer", "InboxPlusRemote", "InboxPlusFeatures", "InboxPlusGateway", "InboxPlusUI", "InboxPlusMatrix", "InboxPlusRuntime", "InboxPlusBridge", "InboxPlusBridgeService", "InboxPlusIMessage"]),
        .executableTarget(name: "InboxPlusRuntimeBundler", dependencies: ["InboxPlusRuntime", "InboxPlusBridgeService"]),
        .target(name: "InboxPlusCore"),
        .target(name: "InboxPlusGateway", dependencies: ["InboxPlusCore"]),
        .target(name: "InboxPlusFeatures", dependencies: ["InboxPlusCore", "InboxPlusGateway", "InboxPlusBridge"]),
        .target(
            name: "InboxPlusUI",
            dependencies: ["InboxPlusCore", "InboxPlusFeatures", "InboxPlusBridge"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "InboxPlusApp",
            dependencies: [
                "InboxPlusGateway", "InboxPlusFeatures", "InboxPlusUI", "InboxPlusMatrix", "InboxPlusRuntime",
                "InboxPlusBridge", "InboxPlusBridgeService", "InboxPlusIMessage",
            ]
        ),
        // iMessage does not go through Matrix: it is read from the local Messages database and
        // sent by asking Messages itself. It therefore implements the gateway seam directly.
        .target(
            name: "InboxPlusIMessage",
            dependencies: ["InboxPlusCore", "InboxPlusGateway"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "InboxPlusRuntime"),
        // The bridge contract as pure data: bridgev2 protocol models, the network catalog, and the
        // login state machine. Deliberately dependency-free beyond InboxPlusCore so InboxPlusFeatures and
        // InboxPlusUI can drive a login without importing the runtime or a process supervisor.
        .target(name: "InboxPlusBridge", dependencies: ["InboxPlusCore"]),
        // Everything that talks to a real bridge: provisioning client, installer, configuration,
        // supervision, and the deterministic dummy bridge used as a contract-test fixture.
        .target(name: "InboxPlusBridgeService", dependencies: ["InboxPlusBridge", "InboxPlusCore", "InboxPlusRuntime"]),
        .executableTarget(
            name: "InboxPlusRuntimeCLI",
            dependencies: ["InboxPlusRuntime", "InboxPlusBridge", "InboxPlusBridgeService", "InboxPlusCore"]
        ),
        // The Matrix SDK stays behind this target. InboxPlusFeatures and InboxPlusUI must never import it,
        // so the app layer keeps depending only on the MessagingGateway protocol.
        .target(
            name: "InboxPlusMatrix",
            dependencies: [
                "InboxPlusCore",
                "InboxPlusGateway",
                "InboxPlusRuntime",
                .product(name: "MatrixRustSDK", package: "matrix-rust-components-swift"),
            ]
        ),
        .testTarget(name: "InboxPlusAppTests", dependencies: ["InboxPlusApp"]),
        .testTarget(name: "InboxPlusCoreTests", dependencies: ["InboxPlusCore"]),
        .testTarget(name: "InboxPlusGatewayTests", dependencies: ["InboxPlusCore", "InboxPlusGateway"]),
        .testTarget(
            name: "InboxPlusFeaturesTests",
            dependencies: ["InboxPlusCore", "InboxPlusGateway", "InboxPlusFeatures", "InboxPlusBridge"]
        ),
        .testTarget(
            name: "InboxPlusUITests",
            dependencies: ["InboxPlusCore", "InboxPlusFeatures", "InboxPlusUI", "InboxPlusBridge"]
        ),
        .testTarget(name: "InboxPlusRuntimeTests", dependencies: ["InboxPlusRuntime", "InboxPlusRuntimeCLI"]),
        .testTarget(
            name: "InboxPlusBridgeTests",
            dependencies: ["InboxPlusBridge", "InboxPlusBridgeService", "InboxPlusCore", "InboxPlusRuntime"]
        ),
        .testTarget(
            name: "InboxPlusIMessageTests",
            dependencies: ["InboxPlusIMessage", "InboxPlusCore", "InboxPlusGateway"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "InboxPlusMatrixTests",
            dependencies: ["InboxPlusMatrix", "InboxPlusCore", "InboxPlusGateway", "InboxPlusRuntime"]
        ),
    ]
)

} else {
package = Package(
    name: "InboxPlusIOS", platforms: [.iOS(.v17), .macOS(.v15)],
    products: [.library(name: "InboxPlusMobile", targets: ["InboxPlusMobile"]), .executable(name: "InboxPlusCompanionFixture", targets: ["InboxPlusCompanionFixture"])],
    targets: [
        .target(name: "InboxPlusCore"),
        .target(name: "InboxPlusGateway", dependencies: ["InboxPlusCore"]),
        .target(name: "InboxPlusBridge", dependencies: ["InboxPlusCore"]),
        .target(name: "InboxPlusFeatures", dependencies: ["InboxPlusCore", "InboxPlusGateway", "InboxPlusBridge"]),
        .target(name: "InboxPlusUI", dependencies: ["InboxPlusCore", "InboxPlusFeatures", "InboxPlusBridge"], resources: [.process("Resources")]),
        .target(name: "InboxPlusRemote", dependencies: ["InboxPlusCore", "InboxPlusGateway", "InboxPlusBridge"]),
        .target(name: "InboxPlusMobile", dependencies: ["InboxPlusUI", "InboxPlusRemote", "InboxPlusFeatures", "InboxPlusGateway", "InboxPlusBridge"]),
        .testTarget(name: "InboxPlusCoreTests", dependencies: ["InboxPlusCore"]),
        .testTarget(name: "InboxPlusGatewayTests", dependencies: ["InboxPlusGateway", "InboxPlusCore"]),
        .testTarget(name: "InboxPlusFeaturesTests", dependencies: ["InboxPlusFeatures", "InboxPlusCore", "InboxPlusGateway", "InboxPlusBridge"]),
        .target(name: "InboxPlusCompanionServer", dependencies: ["InboxPlusRemote"]),
        .executableTarget(name: "InboxPlusCompanionFixture", dependencies: ["InboxPlusCompanionServer", "InboxPlusRemote", "InboxPlusFeatures"]),
        .testTarget(name: "InboxPlusRemoteTests", dependencies: ["InboxPlusRemote", "InboxPlusFeatures", "InboxPlusCompanionServer"]),
        .testTarget(name: "InboxPlusUITests", dependencies: ["InboxPlusCore", "InboxPlusFeatures", "InboxPlusUI", "InboxPlusBridge"]),
    ]
)

}
