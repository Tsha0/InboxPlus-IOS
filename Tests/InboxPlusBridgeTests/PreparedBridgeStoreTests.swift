import Foundation
import Testing
import InboxPlusCore
import InboxPlusRuntime
@testable import InboxPlusBridgeService

@Test(arguments: ["signal", "bluesky"])
func removedPlatformsDoNotHideSupportedPreparedBridges(_ removedPlatform: String) throws {
    // RuntimePaths rejects /var, including standardized temporary-directory URLs.
    let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Library/Caches", isDirectory: true)
        .appendingPathComponent("inboxplus-bridge-store-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = PreparedBridgeStore(paths: try RuntimePaths(root: root, profileName: "test"))
    let supported = PreparedBridge(
        bridgeID: "telegram", platform: .telegram, displayName: "Telegram", version: "test",
        serverName: "inboxplus.localhost", ownerUserID: "@inboxplus:inboxplus.localhost",
        executable: "/unused/bridge", configurationFile: "/unused/config.yaml",
        registrationFile: "/unused/registration.yaml", appservicePort: 29337,
        provisioningSecret: "test-secret", sha256: String(repeating: "a", count: 64)
    )
    try store.save([supported])
    let data = try Data(contentsOf: store.file)
    var records = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    var removed = records[0]
    removed["platform"] = removedPlatform
    removed["bridgeID"] = removedPlatform
    records.insert(removed, at: 0)
    try JSONSerialization.data(withJSONObject: records).write(to: store.file)

    #expect(try store.load() == [supported])
    try store.upsert(supported)
    #expect(try JSONDecoder().decode([PreparedBridge].self, from: Data(contentsOf: store.file)) == [supported])
}
