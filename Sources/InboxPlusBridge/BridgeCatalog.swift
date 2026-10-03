import Foundation
import InboxPlusCore

/// How a bridge binary is obtained and run.
public enum BridgeRuntimeKind: String, Codable, Sendable, Equatable {
    /// A statically linked Go binary downloaded from the project's release page.
    case goBinary
    /// A macOS-native adapter built into Inbox+; nothing is downloaded and nothing is supervised
    /// as a separate process. iMessage works this way because it authenticates through system
    /// permissions rather than credentials.
    case nativeAdapter
}

/// What Inbox+ asks the user for before a network will connect.
///
/// This is Inbox+'s own expectation, recorded so the picker can describe the flow before any
/// process is running. The bridge remains the authority: what it actually advertises over the
/// provisioning API is what gets rendered.
public enum BridgeCredentialStyle: String, Codable, Sendable, Equatable {
    case cookies
    case qrCode
    case phoneNumber
    case systemPermissions

    public var summary: String {
        switch self {
        case .cookies: "Sign in on the network's own web page"
        case .qrCode: "Scan a QR code with your phone"
        case .phoneNumber: "Enter your phone number and the code you receive"
        case .systemPermissions: "Grant macOS permissions — no password needed"
        }
    }
}

/// One downloadable artifact, pinned to a version and a content hash.
public struct BridgeArtifact: Codable, Sendable, Equatable {
    public let assetName: String
    /// Lowercase hex SHA-256 of the exact bytes the release publishes.
    public let sha256: String
    public let downloadURL: URL

    public init(assetName: String, sha256: String, downloadURL: URL) {
        self.assetName = assetName
        self.sha256 = sha256
        self.downloadURL = downloadURL
    }
}

/// Everything Inbox+ needs to know about one network's bridge before it runs.
public struct BridgeDescriptor: Codable, Sendable, Equatable, Identifiable {
    /// Matches the appservice registration id and the on-disk directory name, so it must stay
    /// within the safe-identifier set `AppServiceRegistration` enforces.
    public let id: String
    public let platform: Platform
    public let displayName: String
    public let version: String
    public let runtimeKind: BridgeRuntimeKind
    public let credentialStyle: BridgeCredentialStyle
    /// `nil` for a native adapter, which has nothing to download.
    public let artifact: BridgeArtifact?
    /// The flow identifiers Inbox+ expects this bridge to advertise, recorded only where they were
    /// read from a running bridge. Used to detect protocol drift against a pinned version, never to
    /// filter what the user is offered. Empty means "not yet observed", and drift detection stays
    /// silent rather than asserting a guess.
    public let expectedLoginFlowIDs: [String]
    public let license: String
    public let sourceURL: URL

    public init(
        id: String,
        platform: Platform,
        displayName: String,
        version: String,
        runtimeKind: BridgeRuntimeKind,
        credentialStyle: BridgeCredentialStyle,
        artifact: BridgeArtifact?,
        expectedLoginFlowIDs: [String],
        license: String,
        sourceURL: URL
    ) {
        self.id = id
        self.platform = platform
        self.displayName = displayName
        self.version = version
        self.runtimeKind = runtimeKind
        self.credentialStyle = credentialStyle
        self.artifact = artifact
        self.expectedLoginFlowIDs = expectedLoginFlowIDs
        self.license = license
        self.sourceURL = sourceURL
    }

    /// The `@<sender>:<server>` localpart the bridge's own bot uses.
    public var senderLocalpart: String { "\(id)bot" }
}

public enum BridgeCatalogError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedPlatform(Platform)
    case malformedChecksum(bridge: String, value: String)
    case unsafeIdentifier(String)
    case duplicatePlatform(Platform)

    public var description: String {
        switch self {
        case let .unsupportedPlatform(platform):
            "\(platform.accessibilityLabel) is not yet available in Inbox+"
        case let .malformedChecksum(bridge, value):
            "bridge '\(bridge)' has a malformed SHA-256 '\(value)'"
        case let .unsafeIdentifier(id):
            "bridge identifier '\(id)' is not a safe appservice identifier"
        case let .duplicatePlatform(platform):
            "two bridges claim \(platform.accessibilityLabel)"
        }
    }
}

/// The pinned set of networks Phase 4 can connect.
///
/// Versions and hashes are recorded verbatim from the upstream `sha256sums.txt` for the pinned
/// tag. A hash is the only thing standing between a release page and code Inbox+ executes, so it is
/// never derived at runtime and never inferred from the download.
public enum BridgeCatalog {
    public static let mautrixVersion = "v0.2607.0"

    /// Only `darwin-arm64` is pinned: Inbox+ targets Apple silicon, and pinning a hash for a
    /// platform that is never verified end to end would be a hash nobody has checked.
    ///
    /// Each bridge carries its own release tag. The mautrix projects share a calendar-versioning
    /// scheme but not a release train, so assuming one version across all of them would point
    /// several downloads at tags that do not exist.
    private static func mautrixArtifact(
        repository: String,
        version: String = mautrixVersion,
        assetName: String,
        sha256: String
    ) -> BridgeArtifact {
        BridgeArtifact(
            assetName: assetName,
            sha256: sha256,
            downloadURL: URL(
                string: "https://github.com/mautrix/\(repository)/releases/download/\(version)/\(assetName)"
            )!
        )
    }

    public static let instagram = BridgeDescriptor(
        id: "instagram",
        platform: .instagram,
        displayName: "Instagram",
        version: mautrixVersion,
        runtimeKind: .goBinary,
        credentialStyle: .cookies,
        artifact: mautrixArtifact(
            repository: "meta",
            assetName: "mautrix-instagram-darwin-arm64",
            sha256: "c7bc6e81def6a23f0f2e8359d7079e86b82723dfb9082b22ad642a9a8912173b"
        ),
        // Read from a running v0.2607.0 bridge, not assumed: the flow is named for the network,
        // and `cookies` is the step type it returns.
        expectedLoginFlowIDs: ["instagram"],
        license: "AGPL-3.0-or-later",
        sourceURL: URL(string: "https://github.com/mautrix/meta")!
    )

    public static let facebookMessenger = BridgeDescriptor(
        id: "facebookmessenger",
        platform: .facebookMessenger,
        displayName: "Facebook Messenger",
        version: mautrixVersion,
        runtimeKind: .goBinary,
        credentialStyle: .cookies,
        artifact: mautrixArtifact(
            repository: "meta",
            assetName: "mautrix-meta-darwin-arm64",
            sha256: "a468cca261034f1a93efc927113ab3d07411836e7c5dd68b7c71e59bdfb17dfb"
        ),
        expectedLoginFlowIDs: [],
        license: "AGPL-3.0-or-later",
        sourceURL: URL(string: "https://github.com/mautrix/meta")!
    )

    public static let whatsApp = BridgeDescriptor(
        id: "whatsapp",
        platform: .whatsApp,
        displayName: "WhatsApp",
        version: mautrixVersion,
        runtimeKind: .goBinary,
        credentialStyle: .phoneNumber,
        artifact: mautrixArtifact(
            repository: "whatsapp",
            assetName: "mautrix-whatsapp-darwin-arm64",
            sha256: "f5c0291e4315a8cf70e836b7707f4e6503353b021a115eebb3a6b18f1b9acfbc"
        ),
        expectedLoginFlowIDs: [],
        license: "AGPL-3.0-or-later",
        sourceURL: URL(string: "https://github.com/mautrix/whatsapp")!
    )

    /// Go since the `bridgev2` rewrite — the Python implementation the earlier plan assumed is
    /// gone, so this needs no interpreter and reuses the same supervision as the others.
    public static let telegram = BridgeDescriptor(
        id: "telegram",
        platform: .telegram,
        displayName: "Telegram",
        version: mautrixVersion,
        runtimeKind: .goBinary,
        credentialStyle: .phoneNumber,
        artifact: mautrixArtifact(
            repository: "telegram",
            assetName: "mautrix-telegram-darwin-arm64",
            sha256: "0e2c2ded1773533c691b902b3d0fc4ec87a2f5d3170cd714f7e9e3e494481dd3"
        ),
        expectedLoginFlowIDs: [],
        license: "AGPL-3.0-or-later",
        sourceURL: URL(string: "https://github.com/mautrix/telegram")!
    )

    /// No download and no supervised process: iMessage is reached through macOS itself, so the
    /// "login" is a permissions grant. Reading and sending are implemented natively in
    /// `InboxPlusIMessage`, not by a bridge.
    public static let iMessage = BridgeDescriptor(
        id: "imessage",
        platform: .iMessage,
        displayName: "iMessage",
        version: "native",
        runtimeKind: .nativeAdapter,
        credentialStyle: .systemPermissions,
        artifact: nil,
        expectedLoginFlowIDs: [],
        license: "AGPL-3.0-or-later",
        sourceURL: URL(string: "https://github.com/mautrix/imessage")!
    )

    // MARK: - Phase 6 networks
    //
    // Every hash below is taken verbatim from the named tag's own `sha256sums.txt`. None of these
    // bridges has been driven with a real account, so `expectedLoginFlowIDs` stays empty and drift
    // detection stays silent rather than asserting a guess — the same rule Phase 4 applied to
    // everything except Instagram.

    public static let googleMessages = BridgeDescriptor(
        id: "gmessages",
        platform: .googleMessages,
        displayName: "Google Messages",
        version: "v0.2605.0",
        runtimeKind: .goBinary,
        credentialStyle: .qrCode,
        artifact: mautrixArtifact(
            repository: "gmessages",
            version: "v0.2605.0",
            assetName: "mautrix-gmessages-darwin-arm64",
            sha256: "d45c1a5e4ce317f0288930f71ecb32375b1a755567469eaac581d17d6b1777b9"
        ),
        // Read from a running bridge.
        expectedLoginFlowIDs: ["google"],
        license: "AGPL-3.0-or-later",
        sourceURL: URL(string: "https://github.com/mautrix/gmessages")!
    )

    public static let googleVoice = BridgeDescriptor(
        id: "gvoice",
        platform: .googleVoice,
        displayName: "Google Voice",
        version: "v0.2605.0",
        runtimeKind: .goBinary,
        credentialStyle: .cookies,
        artifact: mautrixArtifact(
            repository: "gvoice",
            version: "v0.2605.0",
            assetName: "mautrix-gvoice-darwin-arm64",
            sha256: "a259d45000dd34c144a71b017d0a193bf13b414d1321d7f2113736cbae0df4da"
        ),
        // Read from a running bridge.
        expectedLoginFlowIDs: ["cookies"],
        license: "AGPL-3.0-or-later",
        sourceURL: URL(string: "https://github.com/mautrix/gvoice")!
    )

    public static let all: [BridgeDescriptor] = [
        instagram, facebookMessenger, whatsApp, telegram, iMessage,
        googleMessages, googleVoice,
    ]

    /// Networks the design lists that Inbox+ still cannot connect, with the reason.
    ///
    /// Recorded rather than left as an absence so the picker can say why, and so a later phase does
    /// not rediscover the same three dead ends.
    public static func unavailabilityReason(for platform: Platform) -> String? {
        guard !isAvailable(platform) else { return nil }
        switch platform {
        case .x, .slack, .linkedIn:
            return "It's coming soon"
        case .discord:
            // Installed and checksum-verified successfully, then exited immediately on launch: the
            // current release is still the pre-`bridgev2` architecture and does not speak the
            // provisioning protocol every other bridge here uses.
            return "The Discord bridge has not been rewritten for the protocol Inbox+ speaks, so it "
                + "cannot be driven from the app yet."
        case .googleChat:
            return "The Google Chat bridge is Python-only and publishes no macOS binary to verify."
        case .irc:
            return "The maintained IRC bridges are Python and Node projects with no pinned macOS "
                + "release, so there is nothing to checksum."
        case .matrix:
            return "Connecting a second Matrix homeserver needs multi-account support, which Inbox+ "
                + "does not have yet."
        default:
            return "Not yet available in Inbox+."
        }
    }

    public static func descriptor(for platform: Platform) -> BridgeDescriptor? {
        all.first { $0.platform == platform }
    }

    public static func require(_ platform: Platform) throws -> BridgeDescriptor {
        guard let descriptor = descriptor(for: platform) else {
            throw BridgeCatalogError.unsupportedPlatform(platform)
        }
        return descriptor
    }

    public static func isAvailable(_ platform: Platform) -> Bool {
        descriptor(for: platform) != nil
    }

    /// Networks Inbox+ does not offer.
    ///
    /// Distinct from merely unavailable. A network blocked on work Inbox+ could plausibly do stays
    /// in the picker, disabled and explained, because hiding it would misrepresent the roadmap as
    /// the product. These are not that:
    ///
    /// - **IRC** and **Google Chat** have no route at all. Their maintained bridges publish no
    ///   pinned macOS release, so there is nothing Inbox+ could verify before running one, and
    ///   waiting does not change that. A permanent disabled entry would only suggest it is coming.
    /// - **Google Messages** and **Google Voice** are out of scope by decision, not by obstacle.
    ///   Their bridges work and stay in the catalog, so a profile that already has one keeps
    ///   attributing its conversations correctly rather than silently reporting them as Matrix.
    ///   They simply cannot be added.
    public static let notOffered: Set<Platform> = [.irc, .googleChat, .googleMessages, .googleVoice]

    /// Display-only placeholders without connection implementations.
    public static let comingSoon: Set<Platform> = [.x, .slack, .linkedIn]

    public static func canConnect(_ platform: Platform) -> Bool {
        isAvailable(platform) && !notOffered.contains(platform) && !comingSoon.contains(platform)
    }

    /// Every platform the picker shows, available ones first, then alphabetically.
    /// Coming-soon networks always appear at the end.
    ///
    /// The ones Inbox+ cannot connect *yet* are still listed and disabled, with the reason.
    public static var pickerOrder: [Platform] {
        Platform.allCases.filter { !notOffered.contains($0) }.sorted { lhs, rhs in
            let lhsComingSoon = comingSoon.contains(lhs)
            let rhsComingSoon = comingSoon.contains(rhs)
            if lhsComingSoon != rhsComingSoon { return !lhsComingSoon }
            let lhsAvailable = canConnect(lhs)
            let rhsAvailable = canConnect(rhs)
            if lhsAvailable != rhsAvailable { return lhsAvailable }
            return lhs.accessibilityLabel.localizedCaseInsensitiveCompare(rhs.accessibilityLabel)
                == .orderedAscending
        }
    }

    /// Structural checks the catalog must satisfy for any of it to be safe to execute.
    public static func validate(_ descriptors: [BridgeDescriptor] = all) throws {
        var seenPlatforms: Set<Platform> = []
        for descriptor in descriptors {
            guard descriptor.id.range(of: "^[a-z0-9][a-z0-9._-]*$", options: .regularExpression) != nil
            else { throw BridgeCatalogError.unsafeIdentifier(descriptor.id) }
            guard seenPlatforms.insert(descriptor.platform).inserted else {
                throw BridgeCatalogError.duplicatePlatform(descriptor.platform)
            }
            if let artifact = descriptor.artifact {
                guard artifact.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
                else {
                    throw BridgeCatalogError.malformedChecksum(
                        bridge: descriptor.id,
                        value: artifact.sha256
                    )
                }
                guard artifact.downloadURL.scheme == "https" else {
                    throw BridgeCatalogError.malformedChecksum(
                        bridge: descriptor.id,
                        value: artifact.downloadURL.absoluteString
                    )
                }
            }
        }
    }
}
