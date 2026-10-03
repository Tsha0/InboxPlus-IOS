import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum InboxPlusTheme {
    #if os(iOS)
    static let ink = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .white : .black })
    static let paper = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .black : .white })
    #else
    static let ink = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black
    })
    static let paper = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white
    })
    #endif
}
#if os(iOS)
typealias PlatformImage = UIImage
#else
typealias PlatformImage = NSImage
#endif
extension Image {
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}
