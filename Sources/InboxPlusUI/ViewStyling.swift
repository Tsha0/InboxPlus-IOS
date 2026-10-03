import Foundation
import SwiftUI

/// `Text(date, style: .relative)` renders inbox timestamps as "6 mins, 16 secs." — this
/// trims them to the compact form messaging clients actually use.
enum RelativeTime {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 0 else { return "now" }
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}

extension View {
    /// Sidebar rows are plain buttons rather than `List` selection, so they have to paint
    /// their own selected state.
    func selectedRowBackground(_ isSelected: Bool) -> some View {
        listRowBackground(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? AnyShapeStyle(InboxPlusTheme.ink.opacity(0.12)) : AnyShapeStyle(.clear))
        )
    }
}

extension View {
    /// iOS propagates a container's identifier to its controls. Keep identifiers on
    /// the individual interactive elements so VoiceOver/UI automation can distinguish them.
    @ViewBuilder func screenAccessibilityIdentifier(_ value: String) -> some View {
        #if os(macOS)
        self.accessibilityIdentifier(value)
        #else
        self
        #endif
    }
}
