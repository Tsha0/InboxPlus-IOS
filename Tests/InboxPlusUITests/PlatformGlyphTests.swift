import Foundation
import SwiftUI
import Testing
import InboxPlusBridge
import InboxPlusCore
@testable import InboxPlusUI

private let box = CGRect(x: 0, y: 0, width: 24, height: 24)

@Test func everyConnectableNetworkHasItsOwnMark() throws {
    // A network Inbox+ offers but draws with a generic symbol looks unfinished next to the ones
    // that have real marks.
    for platform in BridgeCatalog.pickerOrder where BridgeCatalog.isAvailable(platform) {
        #expect(PlatformGlyph.plateColor(for: platform) != nil, "\(platform) has no monochrome plate")
        let path = try #require(PlatformGlyph.path(for: platform, in: box), "\(platform) has no mark")
        #expect(!path.isEmpty, "\(platform) produced an empty mark")
    }
}

@Test func aMarkStaysInsideTheSpaceItIsGiven() throws {
    // The paths are generated from a 24x24 source; one that escaped its box would draw over the
    // badge's rounded corners or bleed into neighbouring views.
    for platform in Platform.allCases {
        guard let path = PlatformGlyph.path(for: platform, in: box) else { continue }
        let bounds = path.boundingRect
        #expect(bounds.minX >= -0.5, "\(platform) overflows left")
        #expect(bounds.minY >= -0.5, "\(platform) overflows top")
        #expect(bounds.maxX <= 24.5, "\(platform) overflows right")
        #expect(bounds.maxY <= 26, "\(platform) overflows bottom")
    }
}

@Test func aMarkScalesWithTheSpaceItIsGiven() throws {
    // Vector, not a fixed-size image: the same badge is drawn in the inbox, the header and the
    // picker at different sizes.
    let small = try #require(PlatformGlyph.path(for: .instagram, in: box))
    let large = try #require(
        PlatformGlyph.path(for: .instagram, in: CGRect(x: 0, y: 0, width: 240, height: 240))
    )
    #expect(large.boundingRect.width > small.boundingRect.width * 9)
}

@Test func aMarkIsOffsetByTheRectItIsDrawnIn() throws {
    let moved = try #require(
        PlatformGlyph.path(for: .whatsApp, in: CGRect(x: 100, y: 50, width: 24, height: 24))
    )
    #expect(moved.boundingRect.minX >= 99.5)
    #expect(moved.boundingRect.minY >= 49.5)
}

@Test func aPlatformWithoutAMarkFallsBackRatherThanDrawingNothing() {
    // Google Chat is in the domain model but has no mark; the badge must still render its symbol.
    #expect(PlatformGlyph.plateColor(for: .googleChat) == nil)
    #expect(PlatformGlyph.path(for: .googleChat, in: box) == nil)
    #expect(!Platform.googleChat.symbolName.isEmpty)
}

@Test @MainActor func platformPlatesAreMonochromeInBothAppearances() throws {
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        let appearance = try #require(NSAppearance(named: name))
        appearance.performAsCurrentDrawingAppearance {
            for platform in BridgeCatalog.pickerOrder {
                guard let color = PlatformGlyph.plateColor(for: platform),
                      let native = NSColor(color).usingColorSpace(.sRGB) else { continue }
                #expect(abs(native.redComponent - native.greenComponent) < 0.01)
                #expect(abs(native.greenComponent - native.blueComponent) < 0.01)
            }
            let ink = NSColor(InboxPlusTheme.ink).usingColorSpace(.sRGB)!
            let paper = NSColor(InboxPlusTheme.paper).usingColorSpace(.sRGB)!
            #expect(abs(ink.redComponent - paper.redComponent) > 0.95)
        }
    }
}
