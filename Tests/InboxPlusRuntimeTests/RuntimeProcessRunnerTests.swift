import Darwin
import Foundation
import Testing
@testable import InboxPlusRuntime

@Test func systemRunnerRemapsAChildDescriptorWhenSourceEqualsPreferredTarget() async throws {
    // Break caught: dup2(source, source) stays close-on-exec, so the child cannot read the authenticated bytes.
    let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(".build/RuntimeProcessRunnerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sentinelURL = directory.appendingPathComponent("sentinel")
    try Data("descriptor-sentinel\n".utf8).write(to: sentinelURL)

    let source = Darwin.open(sentinelURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard source >= 0 else { throw POSIXError(.EIO) }
    defer { _ = Darwin.close(source) }
    let workingDirectory = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard workingDirectory >= 0 else { throw POSIXError(.EIO) }
    defer { _ = Darwin.close(workingDirectory) }

    let output = try await RuntimeBootstrapper.runSystemProcess(RuntimeProcessRequest(
        executable: URL(fileURLWithPath: "/bin/sh"),
        relativeExecutable: nil,
        arguments: ["-c", "cat \"$1\"", "inboxplus-fd-test", "unmapped"],
        environment: ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"],
        workingDirectoryDescriptor: workingDirectory,
        inheritedDescriptors: [
            .init(source: source, preferredTarget: source, destination: .argument(3)),
        ]
    ))

    #expect(output.status == 0)
    #expect(output.standardOutput == "descriptor-sentinel\n")
    #expect(output.standardError.isEmpty)
}

@Test func systemRunnerExecutesAnchoredRelativeFileMatchingHeldIdentity() async throws {
    // Break caught: the runner reopens the selected absolute executable pathname instead of the verified anchored inode alias.
    let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(".build/RuntimeExecutableRunnerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceCode = directory.appendingPathComponent("validated.c")
    try Data("#include <stdio.h>\nint main(void) { fputs(\"anchored-executable\", stdout); return 0; }\n".utf8)
        .write(to: sourceCode)
    let sourceExecutable = directory.appendingPathComponent("source-sh")
    let compiler = Process()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
    compiler.arguments = [sourceCode.path, "-o", sourceExecutable.path]
    try compiler.run()
    compiler.waitUntilExit()
    #expect(compiler.terminationStatus == 0)
    let anchoredExecutable = directory.appendingPathComponent("validated-sh")
    guard Darwin.link(sourceExecutable.path, anchoredExecutable.path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    let identity = Darwin.open(sourceExecutable.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard identity >= 0 else { throw POSIXError(.EIO) }
    defer { _ = Darwin.close(identity) }
    let workingDirectory = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard workingDirectory >= 0 else { throw POSIXError(.EIO) }
    defer { _ = Darwin.close(workingDirectory) }

    let output = try await RuntimeBootstrapper.runSystemProcess(RuntimeProcessRequest(
        executable: URL(fileURLWithPath: "/path/replaced-after-validation"),
        relativeExecutable: "validated-sh",
        arguments: [],
        environment: ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"],
        workingDirectoryDescriptor: workingDirectory,
        expectedExecutableIdentity: identity,
        inheritedDescriptors: []
    ))

    #expect(output.status == 0)
    #expect(output.standardOutput == "anchored-executable")
    #expect(output.standardError.isEmpty)
}

@Test func childWaitRetriesInterruptsWithoutTerminatingTheChild() throws {
    // Break caught: a signal-interrupted wait is reported as failure while the launched child continues running.
    let child = pid_t(4242)
    var attempts = 0
    var terminated: [pid_t] = []

    let status = try RuntimeChildWaiter.wait(
        for: child,
        wait: { pid in
            #expect(pid == child)
            attempts += 1
            if attempts == 1 {
                return RuntimeWaitAttempt(result: -1, status: 0, error: EINTR)
            }
            return RuntimeWaitAttempt(result: child, status: 7 << 8, error: 0)
        },
        terminate: { pid, _ in
            terminated.append(pid)
            return 0
        }
    )

    #expect(status == 7 << 8)
    #expect(attempts == 2)
    #expect(terminated.isEmpty)
}

@Test func childWaitTerminatesAndReapsAfterAnUnrecoverableWaitError() throws {
    // Break caught: an unrecoverable wait error is thrown while the exact venv/pip child remains alive and unreaped.
    let child = pid_t(4343)
    var attempts = 0
    var terminated: [(pid_t, Int32)] = []

    do {
        _ = try RuntimeChildWaiter.wait(
            for: child,
            wait: { pid in
                #expect(pid == child)
                attempts += 1
                switch attempts {
                case 1:
                    return RuntimeWaitAttempt(result: -1, status: 0, error: EIO)
                case 2:
                    return RuntimeWaitAttempt(result: -1, status: 0, error: EINTR)
                default:
                    return RuntimeWaitAttempt(result: child, status: SIGKILL, error: 0)
                }
            },
            terminate: { pid, signal in
                terminated.append((pid, signal))
                return 0
            }
        )
        Issue.record("expected the original unrecoverable wait error")
    } catch let error as POSIXError {
        #expect(error.code == .EIO)
    }

    #expect(attempts == 3)
    #expect(terminated.count == 1)
    #expect(terminated.first?.0 == child)
    #expect(terminated.first?.1 == SIGKILL)
}
