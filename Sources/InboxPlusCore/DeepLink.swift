import Foundation

/// A link Inbox+ is willing to hand to the rest of the system.
///
/// Only the verifier can make one, so a URL that reached this type has already been checked against
/// the platform that claims to own it.
public struct VerifiedDeepLink: Codable, Hashable, Sendable {
    public let url: URL
    public let platform: Platform

    fileprivate init(url: URL, platform: Platform) {
        self.url = url
        self.platform = platform
    }

    /// Decoding cannot run the verifier, so a persisted link is re-checked on the way back in.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let url = try container.decode(URL.self, forKey: .url)
        let platform = try container.decode(Platform.self, forKey: .platform)
        guard let verified = try? DeepLinkVerifier.verify(url, for: platform) else {
            throw DecodingError.dataCorruptedError(
                forKey: .url,
                in: container,
                debugDescription: "stored deep link no longer passes verification"
            )
        }
        self = verified
    }
}

public enum DeepLinkVerificationError: Error, Equatable {
    case malformed(String)
    case unsupportedScheme(String)
    case missingHost
    case hostNotOwnedByPlatform(host: String, platform: Platform)
    case embeddedCredentials
    case unexpectedPort(Int)
    case platformHasNoVerifiableLinks(Platform)
}

/// Decides whether a link a bridge reported may be opened.
///
/// Only `https` on a host the platform demonstrably owns is accepted. Custom schemes such as
/// `instagram://` are rejected on purpose: any installed application can claim a scheme, so
/// following one means handing a message's contents to whatever registered it first. An `https`
/// link is resolved by macOS against the domain's own app-site association, which is the only part
/// of this chain Inbox+ does not have to take a bridge's word for. When no app is installed the
/// same link opens the website, so rejecting schemes costs the user nothing.
public enum DeepLinkVerifier {
    public static func verify(_ raw: String, for platform: Platform) throws -> VerifiedDeepLink {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw DeepLinkVerificationError.malformed(raw)
        }
        return try verify(url, for: platform)
    }

    public static func verify(_ url: URL, for platform: Platform) throws -> VerifiedDeepLink {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw DeepLinkVerificationError.malformed(url.absoluteString)
        }
        guard let scheme = components.scheme?.lowercased() else {
            throw DeepLinkVerificationError.malformed(url.absoluteString)
        }
        guard scheme == "https" else {
            throw DeepLinkVerificationError.unsupportedScheme(scheme)
        }
        guard components.user == nil, components.password == nil else {
            throw DeepLinkVerificationError.embeddedCredentials
        }
        // Universal links are only served over 443, so a port at all is a redirection attempt.
        if let port = components.port, port != 443 {
            throw DeepLinkVerificationError.unexpectedPort(port)
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else {
            throw DeepLinkVerificationError.missingHost
        }
        let domains = verifiableDomains(for: platform)
        guard !domains.isEmpty else {
            throw DeepLinkVerificationError.platformHasNoVerifiableLinks(platform)
        }
        guard domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
            throw DeepLinkVerificationError.hostNotOwnedByPlatform(host: host, platform: platform)
        }
        return VerifiedDeepLink(url: url, platform: platform)
    }

    /// Finds the platform a link belongs to, if any one of them owns it.
    ///
    /// Used for content shared *into* a conversation — a Reel pasted into an Instagram DM arrives
    /// as ordinary text, and the link is the only thing identifying what it actually is.
    public static func verifyAgainstAnyPlatform(_ url: URL) -> VerifiedDeepLink? {
        for platform in Platform.allCases {
            if let link = try? verify(url, for: platform) { return link }
        }
        return nil
    }

    /// Domains each platform serves its own links from. A host matches one of these exactly or as a
    /// subdomain of it; the leading dot in the suffix check is what keeps `evil-instagram.com` out.
    public static func verifiableDomains(for platform: Platform) -> [String] {
        switch platform {
        case .instagram: ["instagram.com", "ig.me"]
        case .whatsApp: ["whatsapp.com", "wa.me"]
        case .facebookMessenger: ["messenger.com", "m.me", "facebook.com", "fb.com"]
        case .telegram: ["t.me", "telegram.me", "telegram.org"]
        case .discord: ["discord.com", "discord.gg"]
        case .googleMessages: ["messages.google.com"]
        case .googleChat: ["chat.google.com"]
        case .googleVoice: ["voice.google.com"]
        case .matrix: ["matrix.to"]
        // Coming-soon placeholders and networks without web links have no supported domains.
        case .iMessage, .irc, .slack, .x, .linkedIn: []
        }
    }
}
