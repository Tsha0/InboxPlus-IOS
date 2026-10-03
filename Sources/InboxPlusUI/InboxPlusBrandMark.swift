import SwiftUI
public struct InboxPlusBrandMark: View {
    public init() {}
    public var body: some View {
        Group {
            if let url = Bundle.module.url(forResource: "InboxPlusLogo", withExtension: "png"),
               let image = PlatformImage(contentsOfFile: url.path) {
                Image(platformImage: image).renderingMode(.original).resizable().scaledToFit()
            } else {
                Image(systemName: "asterisk").resizable().scaledToFit().padding(18).foregroundStyle(.white).background(.black)
            }
        }
        .clipShape(.rect(cornerRadius: 14))
        .accessibilityLabel("Inbox+ logo")
        .accessibilityIdentifier("inboxplus-logo")
    }
}
