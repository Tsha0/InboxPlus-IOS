import SwiftUI
public struct InboxPlusBrandMark: View {
    public init() {}
    public var body: some View {
        Image("InboxPlusLogo", bundle: .module).resizable().scaledToFit().clipShape(.rect(cornerRadius: 18))
    }
}
