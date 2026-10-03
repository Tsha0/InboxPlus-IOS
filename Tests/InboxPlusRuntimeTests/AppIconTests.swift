import Foundation
import Testing

/// The icon is generated from the asterisk logo by `Scripts/make-icon.swift`. These guard the parts that
/// break silently: a missing size makes the system scale a neighbour, which looks soft in exactly
/// one place and is easy to miss.
@Test func theAppIconShipsEverySizeMacOSAsksFor() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let icon = repository.appendingPathComponent("Resources/AppIcon.icns")
    try #require(FileManager.default.fileExists(atPath: icon.path), "run Scripts/make-icon.swift")

    let extracted = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("InboxPlusIconTest-\(UUID().uuidString).iconset")
    defer { try? FileManager.default.removeItem(at: extracted) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "iconset", icon.path, "-o", extracted.path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "the icns could not be read back")

    let names = Set(
        (try FileManager.default.contentsOfDirectory(atPath: extracted.path))
    )
    for required in [
        "icon_16x16.png", "icon_16x16@2x.png", "icon_32x32.png", "icon_32x32@2x.png",
        "icon_128x128.png", "icon_128x128@2x.png", "icon_256x256.png", "icon_256x256@2x.png",
        "icon_512x512.png", "icon_512x512@2x.png",
    ] {
        #expect(names.contains(required), "missing \(required)")
    }
}

@Test func theBundleDeclaresTheIconItShips() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let script = try String(
        contentsOf: repository.appendingPathComponent("Scripts/build-app.sh"), encoding: .utf8
    )
    // An icns in Resources that Info.plist never names is an icon nobody sees.
    #expect(script.contains("<key>CFBundleIconFile</key><string>AppIcon</string>"))
    #expect(script.contains("cp Resources/AppIcon.icns"))
}
