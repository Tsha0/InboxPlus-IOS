import Foundation

/// The single place Inbox+'s own version is written down.
///
/// Release notes, the updater, the bill of materials and the diagnostics header all have to agree
/// on this. Two sources of truth for a version is how a build ships claiming to be something it is
/// not.
public enum InboxPlusVersion {
    public static let current = "0.5.0"

    /// Semantic ordering, so the updater can tell an upgrade from a downgrade rather than comparing
    /// strings — `0.10.0` sorts before `0.9.0` as text.
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(lhs)
        let right = components(rhs)
        for index in 0 ..< max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    public static func isUpgrade(from installed: String, to candidate: String) -> Bool {
        compare(candidate, installed) == .orderedDescending
    }

    private static func components(_ version: String) -> [Int] {
        // A pre-release suffix is dropped rather than parsed: Inbox+ does not publish them, and
        // guessing an ordering for one would be inventing a rule.
        version.split(separator: "-").first?
            .split(separator: ".")
            .map { Int($0) ?? 0 } ?? []
    }
}
