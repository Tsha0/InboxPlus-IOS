import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum InboxPlusTheme {
    static let ink = Color.primary
    #if os(iOS)
    static let paper = Color(uiColor: .systemBackground)
    #else
    static let paper = Color(nsColor: .windowBackgroundColor)
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
