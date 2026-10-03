import Darwin
import Foundation

public struct RuntimePaths: Sendable {
    public let root: URL
    public let profile: URL
    public let runtime: URL
    public let configuration: URL
    public let data: URL
    public let logs: URL
    public let backups: URL
    public let reports: URL
    public let state: URL

    public init(root: URL, profileName: String) throws {
        guard profileName.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
            throw RuntimePathError.invalidProfileName(profileName)
        }
        guard root.isFileURL else {
            throw RuntimePathError.nonFileRoot(root)
        }

        let standardizedRoot = root.standardizedFileURL
        try Self.rejectSymlinkedAncestors(of: standardizedRoot)

        let standardizedProfile = standardizedRoot
            .appendingPathComponent(profileName, isDirectory: true)
            .standardizedFileURL
        let standardizedRuntime = standardizedProfile.appendingPathComponent("runtime", isDirectory: true).standardizedFileURL
        let standardizedConfiguration = standardizedProfile.appendingPathComponent("configuration", isDirectory: true).standardizedFileURL
        let standardizedData = standardizedProfile.appendingPathComponent("data", isDirectory: true).standardizedFileURL
        let standardizedLogs = standardizedProfile.appendingPathComponent("logs", isDirectory: true).standardizedFileURL
        let standardizedBackups = standardizedProfile.appendingPathComponent("backups", isDirectory: true).standardizedFileURL
        let standardizedReports = standardizedProfile.appendingPathComponent("reports", isDirectory: true).standardizedFileURL
        let standardizedState = standardizedProfile.appendingPathComponent("state", isDirectory: true).standardizedFileURL

        let resolvedPaths = [
            standardizedProfile,
            standardizedRuntime,
            standardizedConfiguration,
            standardizedData,
            standardizedLogs,
            standardizedBackups,
            standardizedReports,
            standardizedState,
        ]
        for path in resolvedPaths {
            guard Self.isContained(path, by: standardizedRoot) else {
                throw RuntimePathError.escapesRoot(path)
            }
            try Self.rejectSymlinkedAncestors(of: path)
        }

        self.root = standardizedRoot
        profile = standardizedProfile
        runtime = standardizedRuntime
        configuration = standardizedConfiguration
        data = standardizedData
        logs = standardizedLogs
        backups = standardizedBackups
        reports = standardizedReports
        state = standardizedState
    }

    private static func isContained(_ child: URL, by root: URL) -> Bool {
        if root.path == "/" {
            return child.path.hasPrefix("/")
        }
        return child.path.hasPrefix(root.path + "/")
    }

    private static func rejectSymlinkedAncestors(of url: URL) throws {
        var ancestor = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            ancestor.appendPathComponent(component, isDirectory: true)
            var metadata = stat()
            guard lstat(ancestor.path, &metadata) == 0 else {
                if errno != ENOENT {
                    throw RuntimePathError.cannotInspectAncestor(ancestor)
                }
                break
            }
            if metadata.st_mode & S_IFMT == S_IFLNK {
                throw RuntimePathError.symlinkedAncestor(ancestor)
            }
        }
    }
}

public enum RuntimePathError: Error, Equatable, Sendable {
    case invalidProfileName(String)
    case nonFileRoot(URL)
    case symlinkedAncestor(URL)
    case cannotInspectAncestor(URL)
    case escapesRoot(URL)
}
