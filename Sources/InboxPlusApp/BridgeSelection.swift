import Foundation
import InboxPlusBridge
import InboxPlusBridgeService
import InboxPlusCore
import InboxPlusRuntime
import InboxPlusUI

/// Supplies the login session behind the account picker, installing the network's bridge first if
/// this profile has never had one.
///
/// Preparing a bridge means downloading a checksum-pinned binary and registering an appservice with
/// the homeserver, which only makes sense against a running developer profile. Without one the app
/// offers no login session at all, and `RootView` says why rather than presenting a login that
/// could never complete.
enum BridgeSelection {
    static func makeProvider(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> BridgeLoginSessionProvider? {
        // Resolved the same way the gateway resolves it, including the single-prepared-profile
        // fallback: an app launched from Finder inherits no environment, and offering no login
        // while the very same launch is attached to a real account is indistinguishable from a bug.
        guard let profileName = GatewaySelection.resolveProfileName(environment: environment)
        else { return nil }

        return { @MainActor platform in
            guard BridgeCatalog.canConnect(platform) else {
                throw BridgeCatalogError.unsupportedPlatform(platform)
            }
            let descriptor = try BridgeCatalog.require(platform)
            let root = try RuntimeProfileService.developerRuntimeRoot(environment: environment)
            let paths = try RuntimePaths(root: root, profileName: profileName)
            // The picker can be opened while the inbox is still starting the homeserver.
            // Wait for readiness instead of treating a missing or stale port as a login error.
            let state = try await ManagedRuntime.shared.ensureRunning(
                paths: paths, profileName: profileName
            )
            guard let port = state.snapshot.loopbackPort
            else { throw GatewaySelectionError.profileNotRunning(profileName) }

            let runtime = BridgeRuntime(paths: paths)
            guard let record = try runtime.prepared(for: platform) else {
                // Every network in the catalog is offered, so picking one this profile has never
                // installed is ordinary use, not a mistake — the download and registration the CLI
                // would do is done here instead of asking for a terminal.
                try await runtime.prepare(
                    descriptor,
                    serverName: state.serverName,
                    homeserverPort: port,
                    ownerUserID: "@inboxplus:\(state.serverName)"
                )
                // Synapse reads `app_service_config_files` once, at startup: the registration just
                // written is invisible to the running homeserver, and the bridge process itself is
                // launched by whoever supervises the profile. Neither is something the app can do
                // from here, so the restart is handed back rather than glossed over with a login
                // that would fail against a homeserver which has never heard of this appservice.
                return .installedPendingRuntimeRestart(
                    BridgeInstallOutcome(platform: platform, profile: profileName)
                )
            }
            // The homeserver takes a new port each session, so the config on disk may name the
            // previous one.
            try runtime.rebindToHomeserver(port: port)
            return .ready(try runtime.provisioningClient(for: record))
        }
    }
}
