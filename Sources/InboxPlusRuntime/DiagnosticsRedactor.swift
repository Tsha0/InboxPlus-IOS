import CryptoKit
import Foundation

/// Removes secrets and personal data from text destined for a diagnostics bundle.
///
/// The existing supervisor redaction substitutes values Inbox+ already knows. That is necessary but
/// not sufficient for a bundle a user might attach to a bug report: a log can contain a token
/// nobody registered, a contact's phone number, or the text of a message. This works by pattern, so
/// it catches what was never handed to it.
///
/// Identifiers are replaced with a stable pseudonym rather than deleted. A log in which every user
/// is `[redacted]` cannot show that two events concern the same person, which is usually the thing
/// being debugged; a pseudonym keeps the correlation and drops the identity.
public struct DiagnosticsRedactor: Sendable {
    /// Values Inbox+ knows are secret — tokens, shared secrets, passphrases.
    private let knownSecrets: [String]
    /// Salts the pseudonyms so they cannot be reversed by hashing a guess.
    private let salt: String

    public init(knownSecrets: [String] = [], salt: String = UUID().uuidString) {
        self.knownSecrets = knownSecrets.filter { $0.count >= 8 }
        self.salt = salt
    }

    public func redact(_ text: String) -> String {
        var result = text
        // Exact known secrets first: the patterns below must not get a chance to only partly
        // rewrite a value that should disappear completely.
        for secret in knownSecrets {
            result = result.replacingOccurrences(of: secret, with: "[redacted-secret]")
        }
        for rule in Self.rules {
            result = rule.apply(to: result, pseudonym: pseudonym)
        }
        return result
    }

    public func redact(linesOf text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { redact(String($0)) }
            .joined(separator: "\n")
    }

    /// A short, stable, salted stand-in for one identifier.
    func pseudonym(_ value: String) -> String {
        let digest = SHA256.hash(data: Data("\(salt):\(value)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    // MARK: - Rules

    struct Rule: Sendable {
        let pattern: String
        /// Replacement template. `$1`-style references are supported; `%PSEUDO%` substitutes a
        /// salted hash of capture group 1.
        let template: String
        let pseudonymize: Bool

        init(_ pattern: String, _ template: String, pseudonymize: Bool = false) {
            self.pattern = pattern
            self.template = template
            self.pseudonymize = pseudonymize
        }

        func apply(to text: String, pseudonym: (String) -> String) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { return text }
            guard pseudonymize else {
                return regex.stringByReplacingMatches(
                    in: text,
                    range: NSRange(text.startIndex..., in: text),
                    withTemplate: template
                )
            }
            // Rewrite from the back so earlier ranges stay valid as the string changes length.
            var result = text
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches.reversed() {
                guard match.numberOfRanges > 1,
                      let full = Range(match.range, in: result),
                      let captured = Range(match.range(at: 1), in: text) else { continue }
                // Expand `$n` references first — a template may keep a non-personal group, such as
                // the server half of a user id, which is diagnostically important.
                let expanded = regex.replacementString(
                    for: match, in: text, offset: 0, template: template
                )
                let token = pseudonym(String(text[captured]))
                result.replaceSubrange(
                    full,
                    with: expanded.replacingOccurrences(of: "%PSEUDO%", with: token)
                )
            }
            return result
        }
    }

    /// Ordered: the most specific patterns run first so a broad one cannot consume part of a value
    /// a narrower rule would have removed entirely.
    static let rules: [Rule] = [
        // Matrix access tokens and their relatives.
        Rule("\\b(syt_|mct_|mat_)[A-Za-z0-9_\\-]{8,}", "[redacted-token]"),
        // Authorization headers, in any casing.
        Rule("(authorization\\s*[:=]\\s*)(bearer\\s+)?\\S+", "$1[redacted-token]"),
        // Secrets in YAML and JSON, keyed by name.
        Rule(
            "((?:as_token|hs_token|shared_secret|registration_shared_secret|access_token|password|passphrase|api_key|client_secret)\\s*[:=]\\s*)[\"']?[^\\s\"',}]+[\"']?",
            "$1[redacted-secret]"
        ),
        // Cookies, whole header and individual pairs.
        Rule("(cookie\\s*[:=]\\s*).*", "$1[redacted-cookies]"),
        Rule("\\b(sessionid|csrftoken|ds_user_id|ig_did|mid|auth_token|ct0)=[^;\\s&]+", "$1=[redacted]"),
        // Message bodies. The single most sensitive thing in a messaging app's logs.
        Rule("(\"body\"\\s*:\\s*)\"(?:[^\"\\\\]|\\\\.)*\"", "$1\"[redacted-message]\""),
        Rule("(\"formatted_body\"\\s*:\\s*)\"(?:[^\"\\\\]|\\\\.)*\"", "$1\"[redacted-message]\""),
        // Attachment URLs — the media id alone is enough to fetch the file.
        Rule("mxc://[^\\s\"',)]+", "[redacted-media-url]"),
        // Verification codes: a short digit run introduced by the word "code".
        Rule("(code\\s*[:=]?\\s*[\"']?)\\d{4,8}", "$1[redacted-code]"),
        // Contact identifiers, pseudonymised rather than deleted.
        Rule("@([A-Za-z0-9._=\\-/+]+):([A-Za-z0-9.\\-]+)", "@[user-%PSEUDO%]:$2", pseudonymize: true),
        // Group 1 is the whole address, so two people at different domains cannot collide.
        Rule("\\b([A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,})\\b", "[email-%PSEUDO%]", pseudonymize: true),
        Rule("(?<![\\w.])(\\+\\d{7,15})(?![\\w.])", "[phone-%PSEUDO%]", pseudonymize: true),
    ]
}
