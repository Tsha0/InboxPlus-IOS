import Foundation
import Testing

@Test func failedFreezeLeavesTheExistingLockUntouched() throws {
    let temporaryDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(".build/InboxPlusRuntimeLockScriptTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let runtimeDirectory = temporaryDirectory.appendingPathComponent("Runtime/Synapse", isDirectory: true)
    let scriptsDirectory = temporaryDirectory.appendingPathComponent("Scripts", isDirectory: true)
    try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)

    let sourceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let script = scriptsDirectory.appendingPathComponent("lock-synapse-runtime.sh")
    try FileManager.default.copyItem(
        at: sourceRoot.appendingPathComponent("Scripts/lock-synapse-runtime.sh"),
        to: script
    )
    try "\n".write(to: runtimeDirectory.appendingPathComponent("requirements.in"), atomically: true, encoding: .utf8)
    let lock = runtimeDirectory.appendingPathComponent("requirements.lock")
    let sentinel = "sentinel-lock\n"
    try sentinel.write(to: lock, atomically: true, encoding: .utf8)

    let fakePython = temporaryDirectory.appendingPathComponent("fake-python")
    try fakePythonScript.write(to: fakePython, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePython.path)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [script.path]
    process.currentDirectoryURL = temporaryDirectory
    process.environment = ProcessInfo.processInfo.environment.merging(
        ["INBOXPLUS_RUNTIME_PYTHON": fakePython.path],
        uniquingKeysWith: { _, injected in injected }
    )
    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus != 0)
    #expect(try String(contentsOf: lock, encoding: .utf8) == sentinel)
}

private let fakePythonScript = """
#!/bin/sh
if [ "$1" = "-m" ] && [ "$2" = "venv" ]; then
    mkdir -p "$3/bin"
    cp "$0" "$3/bin/python"
    chmod +x "$3/bin/python"
    exit 0
fi
if [ "$1" = "-m" ] && [ "$2" = "pip" ] && [ "$3" = "install" ]; then
    exit 0
fi
if [ "$1" = "-m" ] && [ "$2" = "pip" ] && [ "$3" = "freeze" ]; then
    exit 42
fi
exit 1
"""
