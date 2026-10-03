import Foundation
import InboxPlusFeatures
import InboxPlusGateway
import InboxPlusBridge
import InboxPlusBridgeService
import InboxPlusIMessage
import InboxPlusMatrix
import InboxPlusRuntime

/// Chooses which gateway the app runs on at launch.
///
/// A prepared profile is selected by name, or discovered when there is exactly one. A packaged app
/// creates its default profile on first launch; a bare developer executable starts empty. Demo conversations belong only in previews and tests.
///
/// Nothing here waits for the runtime. Selecting a profile only decides *what* to attach to; the
/// homeserver and the bridges are started behind the first use of the gateway, because a cold
/// runtime takes tens of seconds and the window has to appear now.
enum GatewaySelection {
    /// Set `INBOXPLUS_PROFILE=<name>` to run against a prepared, running developer profile.
    static let profileEnvironmentKey = "INBOXPLUS_PROFILE"

    /// What the app runs on. Media loading is paired with the gateway because both need the same
    /// authenticated client — an unconfigured app gets no loader, which simply never
    /// downloads rather than pretending to.
    struct Services {
        let gateway: any MessagingGateway
        let media: MediaController
        /// Manually linked people. Fixture contacts belong only to the fixture gateway: a demo
        /// person sitting in Contacts beside real conversations, linked to identities that do not
        /// exist, is indistinguishable from a bug.
        let directory: ContactDirectory
    }

    @MainActor
    static func makeServices(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Services {
        guard let profileName = resolveProfileName(environment: environment) else {
            FileHandle.standardError.write(Data(
                ("Inbox+: no \(profileEnvironmentKey) set and no prepared profile found — "
                    + "starting with an empty inbox.\n").utf8
            ))
            return Services(
                gateway: InMemoryMessagingGateway(seed: .empty),
                media: MediaController(),
                directory: ContactDirectory()
            )
        }

        do {
            let root = try RuntimeProfileService.developerRuntimeRoot(environment: environment)
            let paths = try RuntimePaths(root: root, profileName: profileName)

            // The media controller exists before the runtime does, so the transcript can render
            // immediately and attach its loader once there is a homeserver to fetch from.
            let media = MediaController()

            let gateway = DeferredRuntimeGateway(
                paths: paths,
                profileName: profileName,
                build: { state in try makeMatrixGateway(paths: paths, state: state) },
                onReady: { state in await attachMedia(media, paths: paths, state: state) }
            )

            return Services(
                gateway: gateway,
                media: media,
                // Real accounts start with no linked people. Linking is something the user does.
                directory: ContactDirectory()
            )
        } catch {
            // Surface the reason instead of silently substituting fake conversations.
            FileHandle.standardError.write(Data(
                "Inbox+: could not attach to profile '\(profileName)': \(error)\n".utf8
            ))
            return Services(
                gateway: InMemoryMessagingGateway(seed: .empty),
                media: MediaController(),
                directory: ContactDirectory()
            )
        }
    }
}

extension GatewaySelection {
    /// Builds the real gateway, once the homeserver behind it is answering.
    static func makeMatrixGateway(
        paths: RuntimePaths,
        state: RuntimeProfileState
    ) throws -> any MessagingGateway {
        guard let port = state.snapshot.loopbackPort else {
            throw GatewaySelectionError.profileNotRunning(paths.profile.lastPathComponent)
        }
        let homeserver = URL(string: "http://127.0.0.1:\(port)")!
        let client = InboxPlusMatrixClient(
            homeserverURL: homeserver,
            store: MatrixClientStore(profile: paths),
            provisioner: try MatrixAccountProvisioner(
                baseURL: homeserver,
                serverName: state.serverName,
                registrationSecret: state.registrationSecret
            )
        )

        // Bridges invite this account into the portals they create, so the gateway needs to know
        // which local users are allowed to do that. Anything not in a prepared bridge's own
        // namespace is ignored.
        let prepared = (try? BridgeRuntime(paths: paths).prepared()) ?? []
        let bridgeIDs = prepared.map(\.bridgeID)
        // A portal room belongs to the network that created it, not to Matrix. The catalog is what
        // knows which network a bridge identifier means, and it lives here rather than in the
        // gateway so the Matrix layer keeps no opinion about bridges.
        let bridgeAccounts = prepared.compactMap { record -> BridgeAccountDescriptor? in
            guard let descriptor = BridgeCatalog.all.first(where: { $0.id == record.bridgeID })
            else { return nil }
            return BridgeAccountDescriptor(
                bridgeID: record.bridgeID,
                platform: descriptor.platform,
                displayName: descriptor.displayName
            )
        }
        FileHandle.standardError.write(Data(
            """
            Inbox+: using local Matrix runtime on port \(port)\
            \(bridgeIDs.isEmpty ? "" : " with bridges: \(bridgeIDs.joined(separator: ", "))").

            """.utf8
        ))

        let matrix = MatrixMessagingGateway(
            client: client,
            invitePolicy: .forBridges(ids: bridgeIDs, serverName: state.serverName),
            bridgeAccounts: bridgeAccounts
        )

        // iMessage never reaches the homeserver, so it sits beside the Matrix gateway rather than
        // behind it. It is only added when the Messages database is actually readable: offering a
        // source that will throw on every read is worse than not offering it.
        var sources: [any MessagingGateway] = [matrix]
        if let imessage = makeIMessageGateway() { sources.append(imessage) }
        return sources.count == 1 ? matrix : CompositeMessagingGateway(sources)
    }

    /// Gives the media controller something to download with, now that there is a homeserver.
    static func attachMedia(
        _ media: MediaController,
        paths: RuntimePaths,
        state: RuntimeProfileState
    ) async {
        guard let port = state.snapshot.loopbackPort else { return }
        // Media lives beside the rest of the profile's private data and is bounded, so a long
        // history cannot fill the disk on its own. Per profile, not per runtime root: two profiles
        // are two separate installations and must not share cached message content.
        let cacheDirectory = paths.profile.appendingPathComponent("media")
        guard let cache = try? MediaCache(directory: cacheDirectory) else { return }

        let homeserver = URL(string: "http://127.0.0.1:\(port)")!
        guard let provisioner = try? MatrixAccountProvisioner(
            baseURL: homeserver,
            serverName: state.serverName,
            registrationSecret: state.registrationSecret
        ) else { return }
        let client = InboxPlusMatrixClient(
            homeserverURL: homeserver,
            store: MatrixClientStore(profile: paths),
            provisioner: provisioner
        )
        let loader = MediaLoader(
            cache: cache,
            fetcher: MatrixMediaFetcher(client: client),
            freeSpace: VolumeFreeSpaceReporter(url: cacheDirectory)
        )
        await MainActor.run { media.attach(loader: loader) }
    }

    /// Decides which profile to attach to.
    ///
    /// The environment variable wins, but an app launched from Finder inherits no environment at
    /// all — so a bundled Inbox+ would always start empty no matter how many real profiles
    /// existed. When exactly one profile is prepared, that is unambiguously the one meant, and
    /// using it is what makes a double-clicked app behave like the one started from a shell.
    ///
    /// With several profiles nothing is guessed: picking one at random would silently attach to the
    /// wrong account.
    static func resolveProfileName(environment: [String: String]) -> String? {
        if let named = environment[profileEnvironmentKey], !named.isEmpty { return named }

        guard let root = try? RuntimeProfileService.developerRuntimeRoot(environment: environment),
              FileManager.default.fileExists(atPath: root.path) ||
                BundledRuntime(packageRoot: RuntimeProfileService.resolvedPackageRoot(environment: environment)).isAvailable
        else { return nil }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []

        // Ask the store whether a profile is real rather than testing for a filename: the layout
        // is the store's business, and duplicating it here is how this silently stops working the
        // next time that file is renamed.
        let prepared = entries.filter { entry in
            guard let paths = try? RuntimePaths(root: root, profileName: entry.lastPathComponent),
                  (try? RuntimeProfileStore(paths: paths).load()) != nil else { return false }
            return true
        }
        if prepared.count == 1 { return prepared[0].lastPathComponent }
        if prepared.isEmpty,
           BundledRuntime(packageRoot: RuntimeProfileService.resolvedPackageRoot(environment: environment)).isAvailable {
            return "default"
        }
        return nil
    }

    /// Opens the local Messages database, or explains why it could not.
    ///
    /// Full Disk Access is the usual reason and it cannot be requested programmatically, so the
    /// failure is written to stderr rather than swallowed — a silently missing iMessage looks like
    /// a bug in Inbox+ rather than a permission the user has not granted.
    static func makeIMessageGateway() -> IMessageGateway? {
        do {
            return IMessageGateway(store: try IMessageStore())
        } catch {
            FileHandle.standardError.write(Data(
                "Inbox+: iMessage is not available: \(error)\n".utf8
            ))
            return nil
        }
    }
}

enum GatewaySelectionError: Error, CustomStringConvertible {
    case profileNotRunning(String)

    var description: String {
        switch self {
        case let .profileNotRunning(name):
            "profile '\(name)' is not running; start it with: InboxPlusRuntimeCLI start --profile \(name)"
        }
    }
}
