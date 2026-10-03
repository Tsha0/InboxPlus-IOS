import Foundation

/// Recovers message text from the `attributedBody` column.
///
/// This is not an optimisation. Since macOS 11 the Messages database frequently leaves
/// `message.text` NULL and stores the body only in `attributedBody`, an old-style NSArchiver
/// "typedstream" blob. A reader that only looks at `text` therefore shows a large fraction of a
/// real conversation as empty, which looks exactly like data loss.
///
/// The blob is decoded structurally rather than scanned for anything that resembles words: the
/// string is length-prefixed, so the length is read and honoured. Anything unexpected returns nil,
/// because inventing a message body is worse than admitting one could not be read.
public enum TypedStreamText {
    /// The class name that immediately precedes the message body in the archive.
    private static let marker = Array("NSString".utf8)

    public static func text(fromAttributedBody data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count > marker.count else { return nil }

        var searchIndex = 0
        while let found = firstIndex(of: marker, in: bytes, from: searchIndex) {
            searchIndex = found + marker.count
            // `+` marks the start of the length-prefixed payload. A short run of type bytes sits
            // between the class name and it, so scan a bounded window rather than a fixed offset —
            // that run has changed length across macOS versions.
            guard let plus = firstIndex(of: [0x2B], in: bytes, from: searchIndex, limit: searchIndex + 8)
            else { continue }
            if let value = string(in: bytes, startingAfter: plus) { return value }
        }
        return nil
    }

    /// Reads the length prefix, then exactly that many bytes.
    ///
    /// A single byte below 0x80 is the length itself; 0x81 and 0x82 introduce a two- and four-byte
    /// little-endian length. This mirrors how the archiver writes it.
    private static func string(in bytes: [UInt8], startingAfter plusIndex: Int) -> String? {
        var index = plusIndex + 1
        guard index < bytes.count else { return nil }

        let length: Int
        switch bytes[index] {
        case 0x81:
            guard index + 2 < bytes.count else { return nil }
            length = Int(bytes[index + 1]) | Int(bytes[index + 2]) << 8
            index += 3
        case 0x82:
            guard index + 4 < bytes.count else { return nil }
            length = Int(bytes[index + 1]) | Int(bytes[index + 2]) << 8
                | Int(bytes[index + 3]) << 16 | Int(bytes[index + 4]) << 24
            index += 5
        case let short where short < 0x80:
            length = Int(short)
            index += 1
        default:
            return nil
        }

        guard length > 0, index + length <= bytes.count else { return nil }
        let slice = Data(bytes[index ..< index + length])
        guard let text = String(data: slice, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    private static func firstIndex(
        of needle: [UInt8],
        in haystack: [UInt8],
        from start: Int,
        limit: Int? = nil
    ) -> Int? {
        guard !needle.isEmpty, start >= 0 else { return nil }
        let end = min(limit ?? haystack.count, haystack.count) - needle.count
        guard end >= start else { return nil }
        for index in start ... end where Array(haystack[index ..< index + needle.count]) == needle {
            return index
        }
        return nil
    }
}
