import Foundation
import Testing
@testable import InboxPlusBridge
@testable import InboxPlusCore

@Test func theCatalogIsStructurallySound() throws {
    try BridgeCatalog.validate()
}

@Test func everyDownloadableBridgePinsAFullSHA256OverHTTPS() {
    for descriptor in BridgeCatalog.all {
        guard let artifact = descriptor.artifact else {
            #expect(descriptor.runtimeKind == .nativeAdapter, "\(descriptor.id) has no artifact")
            continue
        }
        #expect(artifact.sha256.count == 64, "\(descriptor.id) checksum is not a SHA-256")
        #expect(
            artifact.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase },
            "\(descriptor.id) checksum is not lowercase hex"
        )
        #expect(artifact.downloadURL.scheme == "https", "\(descriptor.id) is fetched insecurely")
        #expect(
            artifact.downloadURL.absoluteString.contains(descriptor.version),
            "\(descriptor.id) download URL is not pinned to its recorded version"
        )
    }
}

@Test func aMalformedChecksumIsRejected() {
    let broken = BridgeDescriptor(
        id: "broken",
        platform: .whatsApp,
        displayName: "Broken",
        version: "v1",
        runtimeKind: .goBinary,
        credentialStyle: .qrCode,
        artifact: BridgeArtifact(
            assetName: "x",
            sha256: "not-a-hash",
            downloadURL: URL(string: "https://example.com/x")!
        ),
        expectedLoginFlowIDs: [],
        license: "AGPL-3.0-or-later",
        sourceURL: URL(string: "https://example.com")!
    )
    #expect(throws: BridgeCatalogError.malformedChecksum(bridge: "broken", value: "not-a-hash")) {
        try BridgeCatalog.validate([broken])
    }
}

@Test func aBridgeIdentifierUnsafeForAnAppserviceRegistrationIsRejected() {
    let hostile = BridgeDescriptor(
        id: "../../etc/passwd",
        platform: .whatsApp,
        displayName: "Hostile",
        version: "v1",
        runtimeKind: .nativeAdapter,
        credentialStyle: .systemPermissions,
        artifact: nil,
        expectedLoginFlowIDs: [],
        license: "AGPL-3.0-or-later",
        sourceURL: URL(string: "https://example.com")!
    )
    #expect(throws: BridgeCatalogError.unsafeIdentifier("../../etc/passwd")) {
        try BridgeCatalog.validate([hostile])
    }
}

@Test func twoBridgesCannotClaimTheSamePlatform() {
    #expect(throws: BridgeCatalogError.duplicatePlatform(.instagram)) {
        try BridgeCatalog.validate([BridgeCatalog.instagram, BridgeCatalog.instagram])
    }
}

@Test func thePickerListsEveryPlatformInboxPlusIntendsToOfferAndPutsTheAvailableOnesFirst() {
    let order = BridgeCatalog.pickerOrder
    let offered = Set(Platform.allCases).subtracting(BridgeCatalog.notOffered)
    #expect(Set(order) == offered, "the picker must never hide a platform it intends to offer")
    #expect(order.count == Platform.allCases.count - BridgeCatalog.notOffered.count)

    // Available *and* offered: a network can stay in the catalog for existing profiles while no
    // longer being something you can add.
    let offeredAndAvailable = BridgeCatalog.all
        .map(\.platform)
        .filter { BridgeCatalog.canConnect($0) }
    let availableCount = order.prefix { BridgeCatalog.canConnect($0) }.count
    #expect(availableCount == offeredAndAvailable.count)
    #expect(
        order.dropFirst(availableCount).allSatisfy { !BridgeCatalog.canConnect($0) },
        "an available network was sorted below an unavailable one"
    )
}

@Test func aNetworkWithNoRouteAtAllIsNotOfferedRatherThanPermanentlyGreyedOut() {
    // IRC and Google Chat publish no pinned macOS release, and waiting does not change that.
    // A permanent disabled entry suggests it is coming.
    for platform in [Platform.irc, .googleChat] {
        #expect(BridgeCatalog.notOffered.contains(platform))
        #expect(!BridgeCatalog.pickerOrder.contains(platform))
        #expect(!BridgeCatalog.isAvailable(platform))
    }
}

@Test func aWorkingNetworkThatIsOutOfScopeKeepsItsCatalogEntry() {
    // Google Messages and Google Voice are removed by decision, not obstacle. Dropping their
    // descriptors would leave a profile that already runs one attributing its conversations to
    // Matrix, which is the exact bug this project just finished fixing.
    for platform in [Platform.googleMessages, .googleVoice] {
        #expect(!BridgeCatalog.pickerOrder.contains(platform))
        #expect(BridgeCatalog.isAvailable(platform), "the bridge must stay usable for existing profiles")
    }
}

@Test func networksBlockedOnWorkInboxPlusCouldDoAreStillListed() {
    // The distinction that keeps `notOffered` from becoming a place to hide awkward gaps.
    for platform in [Platform.discord, .matrix] {
        #expect(BridgeCatalog.pickerOrder.contains(platform))
        #expect(BridgeCatalog.unavailabilityReason(for: platform)?.isEmpty == false)
    }
}

@Test func askingForAnUnsupportedNetworkFailsWithAnActionableReason() {
    // Google Chat publishes no macOS binary, so there is nothing to checksum and nothing to run.
    #expect(throws: BridgeCatalogError.unsupportedPlatform(.googleChat)) {
        try BridgeCatalog.require(.googleChat)
    }
    #expect(BridgeCatalogError.unsupportedPlatform(.googleChat).description.contains("Google Chat"))
}

@Test func anUnavailableNetworkSaysWhyRatherThanJustBeingAbsent() throws {
    for platform in Platform.allCases {
        let reason = BridgeCatalog.unavailabilityReason(for: platform)
        if BridgeCatalog.isAvailable(platform) {
            #expect(reason == nil)
        } else {
            #expect(reason?.isEmpty == false)
        }
    }
    // The three the design lists but Phase 6 could not deliver each name their own obstacle.
    #expect(BridgeCatalog.unavailabilityReason(for: .googleChat)?.contains("Python-only") == true)
    #expect(BridgeCatalog.unavailabilityReason(for: .irc)?.contains("no pinned macOS") == true)
    #expect(BridgeCatalog.unavailabilityReason(for: .matrix)?.contains("multi-account") == true)
}

@Test func everyPhase6BridgePinsItsOwnReleaseTag() throws {
    // The mautrix projects share a version scheme but not a release train; assuming one tag across
    // all of them would point several downloads at tags that do not exist.
    for descriptor in BridgeCatalog.all {
        guard let artifact = descriptor.artifact else { continue }
        #expect(
            artifact.downloadURL.absoluteString.contains("/download/\(descriptor.version)/"),
            "\(descriptor.id) downloads from a tag that is not the version it claims"
        )
        #expect(artifact.downloadURL.absoluteString.hasSuffix(artifact.assetName))
        #expect(artifact.assetName.hasSuffix("-darwin-arm64"))
    }
}

@Test func instagramIsPinnedToTheVersionItsFlowsWereReadFrom() throws {
    let instagram = try BridgeCatalog.require(.instagram)
    #expect(instagram.credentialStyle == .cookies)
    #expect(instagram.runtimeKind == .goBinary)
    // Read from a live v0.2607.0 bridge: the flow is named for the network, not the step type.
    #expect(instagram.expectedLoginFlowIDs == ["instagram"])
    #expect(instagram.artifact?.assetName == "mautrix-instagram-darwin-arm64")
    #expect(instagram.senderLocalpart == "instagrambot")
}

@Test func everyBridgeCarriesALicenceCompatibleWithInboxPlus() {
    // Inbox+ is AGPL-3.0-or-later; shipping a bridge under something else would be a licence
    // violation that nothing else in the build would catch.
    for descriptor in BridgeCatalog.all {
        #expect(descriptor.license == "AGPL-3.0-or-later", "\(descriptor.id) licence drifted")
    }
}
