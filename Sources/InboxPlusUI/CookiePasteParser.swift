import Foundation
import InboxPlusBridge

/// Reads cookies a user copied out of their own browser.
///
/// Some networks refuse to sign in inside an embedded web view at all — Google returns
/// `disallowed_useragent` for any OAuth attempt from one — so the in-app page is a dead end there
/// no matter how it is built. The bridges know this: their cookie steps say "enter a JSON object
/// with your cookies, or a cURL command copied from browser devtools". This is that path.
///
/// Accepts what a browser's devtools actually put on the clipboard, because telling someone to
/// reformat a copied cURL command by hand is how a login gets abandoned.
enum CookiePasteParser {
    /// Everything recognised in the pasted text, as raw `name: value` pairs.
    static func cookies(in text: String) -> [String: String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        if let json = jsonObject(in: trimmed) { return json }
        return headerPairs(in: trimmed)
    }

    /// Maps pasted cookies onto the field IDs the bridge declared.
    ///
    /// Unlike live capture, a paste carries no domain, so fields are matched by cookie name alone.
    /// The bridge still decides which names matter, so nothing not asked for is ever forwarded.
    static func match(
        pasted text: String,
        to parameters: BridgeLoginCookiesParams
    ) -> [String: String] {
        let available = cookies(in: text)
        guard !available.isEmpty else { return [:] }

        var captured: [String: String] = [:]
        for field in parameters.fields {
            let names = field.sources.isEmpty
                ? [field.id]
                : field.sources.filter { $0.type == "cookie" }.map(\.name)
            for name in names {
                guard let value = available[name], !value.isEmpty else { continue }
                captured[field.id] = value
                break
            }
        }
        return captured
    }

    /// Which required fields are still missing, so the user is told what to look for rather than
    /// left with a disabled button and no explanation.
    static func missingRequiredFieldIDs(
        pasted text: String,
        to parameters: BridgeLoginCookiesParams
    ) -> [String] {
        let captured = Set(match(pasted: text, to: parameters).keys)
        return parameters.requiredFieldIDs.filter { !captured.contains($0) }.sorted()
    }

    // MARK: - Formats

    /// A flat `{"name": "value"}` object, which is what "Copy as JSON" and most cookie extensions
    /// produce. Non-string values are ignored rather than stringified into nonsense.
    private static func jsonObject(in text: String) -> [String: String]? {
        guard text.hasPrefix("{"), let data = text.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let pairs = object.compactMapValues { $0 as? String }
        return pairs.isEmpty ? nil : pairs
    }

    /// A `Cookie:` header, a `-b`/`--cookie` argument, or a bare `a=1; b=2` list.
    ///
    /// A copied cURL command contains many other headers; only the cookie-bearing ones are read,
    /// so an `Authorization` header in the same paste is never mistaken for a cookie.
    private static func headerPairs(in text: String) -> [String: String] {
        var cookieText: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            for marker in ["cookie:", "-b ", "--cookie "] {
                guard let range = line.range(of: marker, options: [.caseInsensitive]) else { continue }
                cookieText.append(unquote(String(line[range.upperBound...])))
                break
            }
        }
        // A bare `a=1; b=2` paste has no marker at all; only treat the whole text that way when
        // nothing more specific was found, so cURL flags are never scraped indiscriminately.
        if cookieText.isEmpty, !text.contains("curl "), text.contains("=") {
            cookieText.append(text)
        }

        var pairs: [String: String] = [:]
        for chunk in cookieText {
            for pair in chunk.split(separator: ";") {
                let piece = pair.trimmingCharacters(in: .whitespaces)
                guard let split = piece.firstIndex(of: "=") else { continue }
                let name = String(piece[..<split]).trimmingCharacters(in: .whitespaces)
                let value = String(piece[piece.index(after: split)...])
                    .trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !value.isEmpty else { continue }
                pairs[name] = value
            }
        }
        return pairs
    }

    /// Strips shell quoting and any trailing line-continuation a copied cURL command carries.
    ///
    /// Leading and trailing quotes are stripped independently, not as a matched pair: in
    /// `-H 'cookie: a=1; b=2'` the opening quote sits before the marker, so only the closing one
    /// reaches here and a paired-only rule leaves it stuck to the last value.
    private static func unquote(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("\\") { text = String(text.dropLast()) }
        text = text.trimmingCharacters(in: .whitespaces)
        let quotes: Set<Character> = ["'", "\""]
        while let first = text.first, quotes.contains(first) { text = String(text.dropFirst()) }
        while let last = text.last, quotes.contains(last) { text = String(text.dropLast()) }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
