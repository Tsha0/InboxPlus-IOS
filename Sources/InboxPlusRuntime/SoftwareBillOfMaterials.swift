import CryptoKit
import Foundation

/// One thing Inbox+ ships, runs, or downloads that it did not write.
public struct SBOMComponent: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case library
        case application
        case framework
    }

    public let name: String
    public let version: String
    public let kind: Kind
    public let license: String
    /// Lowercase hex SHA-256 of the exact bytes, where Inbox+ verifies them.
    public var sha256: String?
    public var sourceURL: String?
    public var downloadURL: String?
    /// Package URL, the identifier vulnerability scanners match against.
    public var purl: String?
    public var notes: String?

    public init(
        name: String,
        version: String,
        kind: Kind,
        license: String,
        sha256: String? = nil,
        sourceURL: String? = nil,
        downloadURL: String? = nil,
        purl: String? = nil,
        notes: String? = nil
    ) {
        self.name = name
        self.version = version
        self.kind = kind
        self.license = license
        self.sha256 = sha256
        self.sourceURL = sourceURL
        self.downloadURL = downloadURL
        self.purl = purl
        self.notes = notes
    }
}

public enum SBOMError: Error, Equatable, CustomStringConvertible {
    case duplicateComponent(name: String, version: String)
    case malformedChecksum(component: String, value: String)
    case missingLicense(component: String)

    public var description: String {
        switch self {
        case let .duplicateComponent(name, version):
            "two components claim \(name) \(version)"
        case let .malformedChecksum(component, value):
            "component '\(component)' has a malformed SHA-256 '\(value)'"
        case let .missingLicense(component):
            "component '\(component)' has no licence recorded"
        }
    }
}

/// Emits a CycloneDX software bill of materials.
///
/// CycloneDX rather than a bespoke format because vulnerability scanners already read it: an
/// inventory nothing can consume is a document, not a control. The `purl` on each component is what
/// a scanner matches against an advisory database, so a component without one is reported as
/// unscannable rather than quietly omitted.
public struct SoftwareBillOfMaterials: Sendable {
    public let components: [SBOMComponent]
    public let applicationVersion: String

    public init(components: [SBOMComponent], applicationVersion: String) {
        self.components = components
        self.applicationVersion = applicationVersion
    }

    /// Structural checks. A bill of materials with a wrong hash in it is worse than none, because
    /// it will be believed.
    public func validate() throws {
        var seen: Set<String> = []
        for component in components {
            let key = "\(component.name)@\(component.version)"
            guard seen.insert(key).inserted else {
                throw SBOMError.duplicateComponent(name: component.name, version: component.version)
            }
            guard !component.license.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw SBOMError.missingLicense(component: component.name)
            }
            if let sha256 = component.sha256 {
                guard sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                    throw SBOMError.malformedChecksum(component: component.name, value: sha256)
                }
            }
        }
    }

    /// Components a scanner cannot look up, so the gap is stated rather than discovered later.
    public var unscannableComponents: [SBOMComponent] {
        components.filter { $0.purl == nil }
    }

    /// A UUID derived from the components themselves.
    ///
    /// Used as the document serial so identical pins produce an identical document: a bill of
    /// materials that changes on every run cannot be diffed across releases, which is most of what
    /// it is for.
    public func contentFingerprint() throws -> UUID {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(
            components.sorted { "\($0.name)@\($0.version)" < "\($1.name)@\($1.version)" }
        )
        var digest = Array(SHA256.hash(data: payload + Data(applicationVersion.utf8)).prefix(16))
        // Stamp the RFC 4122 version and variant so this is a well-formed UUID, not 16 loose bytes.
        digest[6] = (digest[6] & 0x0F) | 0x40
        digest[8] = (digest[8] & 0x3F) | 0x80
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        ))
    }

    /// `timestamp` is passed in rather than read from the clock so the same inputs produce the same
    /// document — a bill of materials that differs on every run cannot be diffed across releases.
    public func cycloneDXJSON(timestamp: Date, serialNumber: String) throws -> Data {
        try validate()

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let componentObjects: [[String: Any]] = components
            .sorted { "\($0.name)@\($0.version)" < "\($1.name)@\($1.version)" }
            .map { component in
                var object: [String: Any] = [
                    "type": component.kind.rawValue,
                    "name": component.name,
                    "version": component.version,
                    "licenses": [["license": ["id": component.license]]],
                ]
                if let purl = component.purl { object["purl"] = purl }
                if let sha256 = component.sha256 {
                    object["hashes"] = [["alg": "SHA-256", "content": sha256]]
                }
                var references: [[String: String]] = []
                if let sourceURL = component.sourceURL {
                    references.append(["type": "vcs", "url": sourceURL])
                }
                if let downloadURL = component.downloadURL {
                    references.append(["type": "distribution", "url": downloadURL])
                }
                if !references.isEmpty { object["externalReferences"] = references }
                if let notes = component.notes { object["description"] = notes }
                return object
            }

        let document: [String: Any] = [
            "bomFormat": "CycloneDX",
            "specVersion": "1.5",
            "serialNumber": "urn:uuid:\(serialNumber)",
            "version": 1,
            "metadata": [
                "timestamp": formatter.string(from: timestamp),
                "component": [
                    "type": "application",
                    "name": "Inbox+",
                    "version": applicationVersion,
                    "licenses": [["license": ["id": "AGPL-3.0-or-later"]]],
                ],
            ],
            "components": componentObjects,
        ]

        return try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys]
        )
    }
}
