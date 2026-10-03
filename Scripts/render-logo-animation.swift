// Compile alongside the archived merge artwork, then run with an output directory:
// swiftc -parse-as-library Scripts/LogoMergeArtwork.swift \
//   Scripts/render-logo-animation.swift -o /tmp/render-inboxplus-logo
// /tmp/render-inboxplus-logo docs/assets
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main struct LogoAnimationRenderer {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs/assets", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let originals = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("docs/assets")
        let stacked = NSImage(contentsOf: originals.appendingPathComponent("inboxplus-logo-stacked.png"))
        let final = NSImage(contentsOf: originals.appendingPathComponent("inboxplus-logo.png"))
        let fps = 30
        let count = Int(LogoMergeArtwork.duration * Double(fps)) + 1
        let gifURL = output.appendingPathComponent("inboxplus-logo-merge.gif")
        guard let destination = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, count, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<count {
            let time = Double(frame) / Double(fps)
            let artwork = LogoMergeArtwork(elapsed: time, reduceMotion: false, stackedLogo: stacked, finalLogo: final)
                .frame(width: 320, height: 320)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: artwork)
            renderer.scale = 1
            guard let image = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(destination, image,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps)]] as CFDictionary)
            if [0, 24, 42, 53, 75, 102].contains(frame) {
                let png = output.appendingPathComponent("logo-frame-\(frame).png")
                guard let snapshot = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil)
                else { throw CocoaError(.fileWriteUnknown) }
                CGImageDestinationAddImage(snapshot, image, nil)
                guard CGImageDestinationFinalize(snapshot) else { throw CocoaError(.fileWriteUnknown) }
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        print("Rendered \(count) frames: \(gifURL.path)")
    }
}
