import Foundation
import Testing
@testable import InboxPlusRuntime

private func component(
    _ name: String,
    version: String = "1.0.0",
    license: String = "Apache-2.0",
    sha256: String? = nil,
    purl: String? = "pkg:generic/thing@1.0.0"
) -> SBOMComponent {
    SBOMComponent(name: name, version: version, kind: .library, license: license, sha256: sha256, purl: purl)
}

@Test func aBillWithTheSameComponentTwiceIsRejected() {
    let bill = SoftwareBillOfMaterials(
        components: [component("thing"), component("thing")],
        applicationVersion: "0.5.0"
    )
    #expect(throws: SBOMError.duplicateComponent(name: "thing", version: "1.0.0")) {
        try bill.validate()
    }
}

@Test func theSameNameAtTwoVersionsIsFine() throws {
    // A profile can legitimately hold two versions of a bridge during an upgrade.
    let bill = SoftwareBillOfMaterials(
        components: [component("thing", version: "1.0.0"), component("thing", version: "1.1.0")],
        applicationVersion: "0.5.0"
    )
    try bill.validate()
}

@Test func aMalformedHashIsRejectedBecauseAWrongOneWouldBeBelieved() {
    let bill = SoftwareBillOfMaterials(
        components: [component("thing", sha256: "not-a-hash")],
        applicationVersion: "0.5.0"
    )
    #expect(throws: SBOMError.malformedChecksum(component: "thing", value: "not-a-hash")) {
        try bill.validate()
    }
}

@Test func aComponentWithoutALicenceIsRejected() {
    let bill = SoftwareBillOfMaterials(
        components: [component("thing", license: "  ")],
        applicationVersion: "0.5.0"
    )
    #expect(throws: SBOMError.missingLicense(component: "thing")) { try bill.validate() }
}

@Test func aComponentAScannerCannotLookUpIsReportedNotOmitted() {
    let bill = SoftwareBillOfMaterials(
        components: [component("scannable"), component("opaque", purl: nil)],
        applicationVersion: "0.5.0"
    )
    #expect(bill.unscannableComponents.map(\.name) == ["opaque"])
}

@Test func theDocumentIsIdenticalForIdenticalPins() throws {
    let components = [component("a"), component("b")]
    let first = SoftwareBillOfMaterials(components: components, applicationVersion: "0.5.0")
    // Same pins, different order in the array: the document must not depend on that.
    let second = SoftwareBillOfMaterials(components: components.reversed(), applicationVersion: "0.5.0")

    #expect(try first.contentFingerprint() == second.contentFingerprint())
    let stamp = Date(timeIntervalSince1970: 0)
    #expect(
        try first.cycloneDXJSON(timestamp: stamp, serialNumber: "x")
            == second.cycloneDXJSON(timestamp: stamp, serialNumber: "x")
    )
}

@Test func changingAPinChangesTheFingerprint() throws {
    let first = SoftwareBillOfMaterials(components: [component("a", version: "1.0.0")], applicationVersion: "0.5.0")
    let second = SoftwareBillOfMaterials(components: [component("a", version: "1.0.1")], applicationVersion: "0.5.0")
    #expect(try first.contentFingerprint() != second.contentFingerprint())
}

@Test func theDocumentIsValidCycloneDXAScannerWouldAccept() throws {
    let bill = SoftwareBillOfMaterials(
        components: [
            component("thing", sha256: String(repeating: "a", count: 64)),
        ],
        applicationVersion: "0.5.0"
    )
    let data = try bill.cycloneDXJSON(timestamp: Date(timeIntervalSince1970: 0), serialNumber: "abc")
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(json["bomFormat"] as? String == "CycloneDX")
    #expect(json["specVersion"] as? String == "1.5")
    #expect((json["serialNumber"] as? String)?.hasPrefix("urn:uuid:") == true)

    let components = try #require(json["components"] as? [[String: Any]])
    #expect(components.count == 1)
    #expect(components[0]["purl"] as? String == "pkg:generic/thing@1.0.0")
    let hashes = try #require(components[0]["hashes"] as? [[String: String]])
    #expect(hashes[0]["alg"] == "SHA-256")

    let metadata = try #require(json["metadata"] as? [String: Any])
    let root = try #require(metadata["component"] as? [String: Any])
    #expect(root["name"] as? String == "Inbox+")
    #expect(root["version"] as? String == "0.5.0")
}

@Test func aBillThatFailsValidationIsNeverSerialised() {
    // Emitting an invalid document would put a wrong hash somewhere it gets trusted.
    let bill = SoftwareBillOfMaterials(
        components: [component("thing", sha256: "bad")],
        applicationVersion: "0.5.0"
    )
    #expect(throws: SBOMError.self) {
        try bill.cycloneDXJSON(timestamp: Date(timeIntervalSince1970: 0), serialNumber: "x")
    }
}

@Test func theFingerprintIsAWellFormedVersion4UUID() throws {
    let bill = SoftwareBillOfMaterials(components: [component("a")], applicationVersion: "0.5.0")
    let uuid = try bill.contentFingerprint().uuidString
    #expect(uuid.count == 36)
    // Version nibble and variant, per RFC 4122.
    let parts = uuid.split(separator: "-")
    #expect(parts[2].hasPrefix("4"))
    #expect("89AB".contains(parts[3].first!))
}
