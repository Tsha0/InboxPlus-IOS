import AppKit
import SwiftUI

/// Archived logo-merge concept used by the standalone animation renderer.
/// The generated originals bookend a native vector animation, keeping the final brand exact.
struct LogoMergeArtwork: View {
    static let duration: TimeInterval = 3.4
    let elapsed: TimeInterval
    let reduceMotion: Bool
    let stackedLogo: NSImage?
    let finalLogo: NSImage?

    private func ease(_ value: Double) -> Double {
        let value = min(1, max(0, value))
        return value * value * (3 - 2 * value)
    }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let merge = ease((elapsed - 0.65) / 0.95)
            let landing = max(0, elapsed - 1.6)
            let settle = 1 + 0.075 * exp(-5 * landing) * sin(14 * landing)
            let twist = 10 * sin(merge * .pi) + 3 * exp(-5 * landing) * sin(12 * landing)
            let vectorIn = stackedLogo == nil ? 1 : ease((elapsed - 0.3) / 0.25)
            let finalIn = finalLogo == nil ? 0 : ease((elapsed - 2.15) / 0.4)
            let ring = ease((elapsed - 1.52) / 0.65)
            let reducedBlend = ease(elapsed / 0.45)

            ZStack {
                Color.black
                if reduceMotion {
                    if let stackedLogo { Image(nsImage: stackedLogo).resizable().opacity(1 - reducedBlend) }
                    finalMark(side: side).opacity(reducedBlend)
                } else {
                    if let stackedLogo {
                        Image(nsImage: stackedLogo).resizable().opacity(1 - vectorIn)
                    }
                    Circle()
                        .stroke(.white.opacity(0.28 * (1 - ring)), lineWidth: 1)
                        .frame(width: side * (0.48 + 0.32 * ring))
                        .opacity(elapsed >= 1.52 && elapsed < 2.17 ? 1 : 0)
                        .offset(x: -side * 0.01, y: -side * 0.014)

                    ZStack {
                        cross(side: side)
                            .rotationEffect(.degrees(45 + 7 * sin(merge * .pi)))
                            .scaleEffect(0.67 + 0.33 * merge)
                            .offset(x: -side * 0.025 * sin(merge * .pi), y: -side * 0.15 * (1 - merge))
                        cross(side: side)
                            .rotationEffect(.degrees(-7 * sin(merge * .pi)))
                            .scaleEffect(0.59 + 0.41 * merge)
                            .offset(x: side * 0.025 * sin(merge * .pi), y: side * 0.15 * (1 - merge))
                    }
                    .rotationEffect(.degrees(twist))
                    .scaleEffect(settle)
                    .offset(x: -side * 0.01, y: -side * 0.014)
                    .opacity(vectorIn * (1 - finalIn))

                    finalMark(side: side).opacity(finalIn)
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }

    private func cross(side: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.021)
                .frame(width: side * 0.50, height: side * 0.085)
            RoundedRectangle(cornerRadius: side * 0.021)
                .frame(width: side * 0.085, height: side * 0.50)
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private func finalMark(side: CGFloat) -> some View {
        if let finalLogo {
            Image(nsImage: finalLogo).resizable()
        } else {
            ZStack {
                cross(side: side)
                cross(side: side).rotationEffect(.degrees(45))
            }
            .offset(x: -side * 0.01, y: -side * 0.014)
        }
    }
}
