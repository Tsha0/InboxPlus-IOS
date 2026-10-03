import Foundation

/// Converts the Messages database's own clock.
///
/// Messages counts from 2001-01-01 UTC, not 1970. Older macOS wrote whole seconds; since 10.13 it
/// writes nanoseconds. Both appear in the same column of a database that has survived an upgrade,
/// so the unit has to be inferred per value rather than assumed for the file.
public enum AppleTimestamp {
    /// 2001-01-01 00:00:00 UTC, expressed against the Unix epoch.
    public static let referenceOffset: TimeInterval = 978_307_200

    /// Any real nanosecond timestamp is astronomically larger than any plausible second count,
    /// so the magnitude separates them unambiguously.
    static let nanosecondThreshold: Int64 = 1_000_000_000_00

    public static func date(fromAppleTime value: Int64) -> Date? {
        guard value > 0 else { return nil }
        let seconds = value >= nanosecondThreshold
            ? Double(value) / 1_000_000_000
            : Double(value)
        return Date(timeIntervalSince1970: seconds + referenceOffset)
    }

    /// Nanoseconds since 2001, which is what current macOS stores.
    public static func appleTime(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 - referenceOffset) * 1_000_000_000)
    }
}
