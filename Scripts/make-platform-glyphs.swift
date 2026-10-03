#!/usr/bin/env swift
//
// Turns brand SVGs into Swift vector paths.
//
//   swift Scripts/make-platform-glyphs.swift <svg-directory> <output.swift> [contact-sheet.png]
//
// The icons come from Simple Icons, whose SVG files are released CC0. The marks themselves remain
// the trademarks of their owners; InboxPlus uses them to identify the network a conversation belongs
// to, which is what they are for.
//
// The paths are converted at build time rather than parsed at runtime, and emitted as plain
// move/line/curve calls, so the app draws vectors with no SVG parser and no bundled images. Arcs
// are converted to cubic curves here — that is the one genuinely error-prone part, which is why
// this also renders a contact sheet: a wrong logo is obvious to look at and invisible in a diff.

import AppKit
import Foundation

let arguments = CommandLine.arguments
let svgDirectory = arguments.count > 1 ? arguments[1] : "Scripts/brand-icons"
let outputPath = arguments.count > 2 ? arguments[2] : "Sources/InboxPlusUI/PlatformGlyphPaths.swift"
let sheetPath = arguments.count > 3 ? arguments[3] : ""

/// Platform case name → (Simple Icons slug, brand colour). Colours are the ones the same pinned
/// release records, so the mark and its colour come from one source.
let mapping: [(platform: String, slug: String, hex: String)] = [
    ("instagram", "instagram", "FF0069"),
    ("whatsApp", "whatsapp", "25D366"),
    ("facebookMessenger", "messenger", "00B2FF"),
    ("telegram", "telegram", "26A5E4"),
    ("discord", "discord", "5865F2"),
    ("slack", "slack", "4A154B"),
    ("x", "x", "000000"),
    ("linkedIn", "linkedin", "0A66C2"),
    ("iMessage", "imessage", "34DA50"),
    ("matrix", "matrix", "000000"),
]

// MARK: - SVG path parsing

/// A minimal SVG path reader covering the commands Simple Icons actually uses: M, L, H, V, C, S,
/// Q, T, A, Z and their relative forms. Anything unrecognised aborts rather than silently dropping
/// a segment, which would produce a subtly wrong logo.
struct PathParser {
    private let scalars: [Character]
    private var index = 0

    init(_ text: String) { scalars = Array(text) }

    static func cgPath(from d: String) -> CGPath? {
        var parser = PathParser(d)
        return parser.parse()
    }

    private mutating func parse() -> CGPath? {
        let path = CGMutablePath()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var lastQuadControl: CGPoint?
        var command: Character = " "

        while true {
            skipSeparators()
            guard index < scalars.count else { break }

            if scalars[index].isLetter {
                command = scalars[index]
                index += 1
            } else if command == "M" {
                command = "L"          // repeated pairs after a moveto are implicit linetos
            } else if command == "m" {
                command = "l"
            }

            let relative = command.isLowercase
            func point(_ x: Double, _ y: Double) -> CGPoint {
                relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }

            switch command.lowercased().first! {
            case "m":
                guard let x = number(), let y = number() else { return path }
                current = point(x, y)
                start = current
                path.move(to: current)
                lastControl = nil; lastQuadControl = nil
            case "l":
                guard let x = number(), let y = number() else { return path }
                current = point(x, y)
                path.addLine(to: current)
                lastControl = nil; lastQuadControl = nil
            case "h":
                guard let x = number() else { return path }
                current = relative ? CGPoint(x: current.x + x, y: current.y) : CGPoint(x: x, y: current.y)
                path.addLine(to: current)
                lastControl = nil; lastQuadControl = nil
            case "v":
                guard let y = number() else { return path }
                current = relative ? CGPoint(x: current.x, y: current.y + y) : CGPoint(x: current.x, y: y)
                path.addLine(to: current)
                lastControl = nil; lastQuadControl = nil
            case "c":
                guard let x1 = number(), let y1 = number(),
                      let x2 = number(), let y2 = number(),
                      let x = number(), let y = number() else { return path }
                let control1 = point(x1, y1), control2 = point(x2, y2)
                current = point(x, y)
                path.addCurve(to: current, control1: control1, control2: control2)
                lastControl = control2; lastQuadControl = nil
            case "s":
                guard let x2 = number(), let y2 = number(),
                      let x = number(), let y = number() else { return path }
                // The first control point mirrors the previous one, which is what "smooth" means.
                let control1 = lastControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                let control2 = point(x2, y2)
                current = point(x, y)
                path.addCurve(to: current, control1: control1, control2: control2)
                lastControl = control2; lastQuadControl = nil
            case "q":
                guard let x1 = number(), let y1 = number(),
                      let x = number(), let y = number() else { return path }
                let control = point(x1, y1)
                current = point(x, y)
                path.addQuadCurve(to: current, control: control)
                lastQuadControl = control; lastControl = nil
            case "t":
                guard let x = number(), let y = number() else { return path }
                let control = lastQuadControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                current = point(x, y)
                path.addQuadCurve(to: current, control: control)
                lastQuadControl = control; lastControl = nil
            case "a":
                // The two flags are single characters and are routinely written without any
                // separator — `0 00-4.885-1.515` is rotation 0, flags 0 and 0, then the endpoint.
                // Reading them as ordinary numbers swallows "00" as one value and shifts every
                // remaining parameter, which silently produces a fragment of the real shape.
                guard let rx = number(), let ry = number(), let rotation = number(),
                      let largeArc = flag(), let sweep = flag(),
                      let x = number(), let y = number() else { return path }
                let end = point(x, y)
                addArc(
                    to: path, from: current, to: end,
                    rx: rx, ry: ry, rotation: rotation,
                    largeArc: largeArc, sweep: sweep
                )
                current = end
                lastControl = nil; lastQuadControl = nil
            case "z":
                path.closeSubpath()
                current = start
                lastControl = nil; lastQuadControl = nil
            default:
                return path
            }
        }
        return path
    }

    private mutating func skipSeparators() {
        while index < scalars.count, scalars[index] == " " || scalars[index] == ","
            || scalars[index] == "\n" || scalars[index] == "\t" || scalars[index] == "\r" {
            index += 1
        }
    }

    /// An arc flag: exactly one character, `0` or `1`.
    private mutating func flag() -> Bool? {
        skipSeparators()
        guard index < scalars.count else { return nil }
        switch scalars[index] {
        case "0": index += 1; return false
        case "1": index += 1; return true
        default: return nil
        }
    }

    /// SVG numbers run together without separators — `.5.5` is two numbers, and `1e-3` is one.
    private mutating func number() -> Double? {
        skipSeparators()
        var text = ""
        var seenDigit = false
        var seenDot = false
        while index < scalars.count {
            let character = scalars[index]
            if character == "-" || character == "+" {
                // A sign only starts a number, or follows an exponent.
                if text.isEmpty || text.lowercased().hasSuffix("e") {
                    text.append(character); index += 1; continue
                }
                break
            }
            if character == "." {
                if seenDot { break }
                seenDot = true; text.append(character); index += 1; continue
            }
            if character.isNumber {
                seenDigit = true; text.append(character); index += 1; continue
            }
            if character == "e" || character == "E", seenDigit {
                text.append(character); index += 1; continue
            }
            break
        }
        return seenDigit ? Double(text) : nil
    }
}

/// Converts an SVG elliptical arc into cubic segments.
///
/// Implemented from the SVG specification's own endpoint-to-centre conversion. This is the part
/// most likely to be subtly wrong, which is why the contact sheet exists.
func addArc(
    to path: CGMutablePath,
    from start: CGPoint,
    to end: CGPoint,
    rx: Double, ry: Double, rotation: Double,
    largeArc: Bool, sweep: Bool
) {
    guard rx != 0, ry != 0 else { path.addLine(to: end); return }
    var rx = abs(rx), ry = abs(ry)

    let phi = rotation * .pi / 180
    let cosPhi = cos(phi), sinPhi = sin(phi)

    let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
    let x1p = cosPhi * dx + sinPhi * dy
    let y1p = -sinPhi * dx + cosPhi * dy

    // Scale the radii up if they are too small to span the endpoints, as the specification requires.
    let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lambda > 1 {
        rx *= lambda.squareRoot()
        ry *= lambda.squareRoot()
    }

    let sign: Double = largeArc == sweep ? -1 : 1
    let numerator = max(0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
    let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    let coefficient = denominator == 0 ? 0 : sign * (numerator / denominator).squareRoot()

    let cxp = coefficient * rx * y1p / ry
    let cyp = -coefficient * ry * x1p / rx
    let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
    let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

    func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
        let dot = ux * vx + uy * vy
        let length = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
        guard length != 0 else { return 0 }
        let value = max(-1, min(1, dot / length))
        return (ux * vy - uy * vx < 0 ? -1 : 1) * acos(value)
    }

    let startAngle = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    var sweepAngle = angle(
        (x1p - cxp) / rx, (y1p - cyp) / ry,
        (-x1p - cxp) / rx, (-y1p - cyp) / ry
    )
    if !sweep, sweepAngle > 0 { sweepAngle -= 2 * .pi }
    if sweep, sweepAngle < 0 { sweepAngle += 2 * .pi }

    // One cubic per quarter turn or less keeps the approximation within a rounding error.
    let segments = max(1, Int(ceil(abs(sweepAngle) / (.pi / 2))))
    let delta = sweepAngle / Double(segments)
    let alpha = 4.0 / 3.0 * tan(delta / 4)

    var theta = startAngle
    for _ in 0 ..< segments {
        let next = theta + delta
        let cosTheta = cos(theta), sinTheta = sin(theta)
        let cosNext = cos(next), sinNext = sin(next)

        func map(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: cosPhi * rx * x - sinPhi * ry * y + cx, y: sinPhi * rx * x + cosPhi * ry * y + cy)
        }

        let p1 = map(cosTheta - alpha * sinTheta, sinTheta + alpha * cosTheta)
        let p2 = map(cosNext + alpha * sinNext, sinNext - alpha * cosNext)
        let p3 = map(cosNext, sinNext)
        path.addCurve(to: p3, control1: p1, control2: p2)
        theta = next
    }
}

// MARK: - Emit

func pathData(inSVGAt url: URL) -> String? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    guard let range = text.range(of: "d=\"") else { return nil }
    let rest = text[range.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { return nil }
    return String(rest[..<end])
}

var swift = """
// Generated by Scripts/make-platform-glyphs.swift — do not edit by hand.
//
// Brand marks from Simple Icons (https://simpleicons.org), whose SVG files are CC0. The marks
// themselves are trademarks of their respective owners; Inbox+ draws them to identify which network
// a conversation belongs to.
//
// Emitted as vector paths so the badge stays crisp at any size with no bundled images and no SVG
// parsing at runtime. Coordinates are in the icons' own 24x24 space.

import SwiftUI
import InboxPlusCore

enum PlatformGlyph {
    /// Monochrome plate for each supported network mark.
    static func plateColor(for platform: Platform) -> Color? {
        switch platform {

"""

var renderable: [(String, CGPath, String)] = []

for entry in mapping {
    swift += "        case .\(entry.platform): Color.primary\n"
}
swift += """
        default: nil
        }
    }

    /// The mark itself, in a 24x24 space.
    static func path(for platform: Platform, in rect: CGRect) -> Path? {
        var path: Path?
        switch platform {

"""

func hexComponent(_ hex: String, _ index: Int) -> String {
    let start = hex.index(hex.startIndex, offsetBy: index * 2)
    let end = hex.index(start, offsetBy: 2)
    let value = Double(Int(hex[start ..< end], radix: 16) ?? 0) / 255
    return String(format: "%.4f", value)
}

for entry in mapping {
    let url = URL(fileURLWithPath: svgDirectory).appendingPathComponent("\(entry.slug).svg")
    guard let d = pathData(inSVGAt: url), let cgPath = PathParser.cgPath(from: d) else {
        FileHandle.standardError.write(Data("error: could not parse \(entry.slug)\n".utf8))
        exit(1)
    }
    renderable.append((entry.slug, cgPath, entry.hex))

    var body = ""
    cgPath.applyWithBlock { element in
        let points = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint:
            body += "            path.move(to: p(\(f(points[0].x)), \(f(points[0].y))))\n"
        case .addLineToPoint:
            body += "            path.addLine(to: p(\(f(points[0].x)), \(f(points[0].y))))\n"
        case .addQuadCurveToPoint:
            body += "            path.addQuadCurve(to: p(\(f(points[1].x)), \(f(points[1].y))), control: p(\(f(points[0].x)), \(f(points[0].y))))\n"
        case .addCurveToPoint:
            body += "            path.addCurve(to: p(\(f(points[2].x)), \(f(points[2].y))), control1: p(\(f(points[0].x)), \(f(points[0].y))), control2: p(\(f(points[1].x)), \(f(points[1].y))))\n"
        case .closeSubpath:
            body += "            path.closeSubpath()\n"
        @unknown default:
            break
        }
    }

    swift += "        case .\(entry.platform):\n            var path = Path()\n"
    swift += body.replacingOccurrences(of: "            path.", with: "            path.")
    swift += "            return path\n"
}

func f(_ value: CGFloat) -> String { String(format: "%.3f", value) }

swift += """
        default:
            return nil
        }
    }
}

"""

// The generated switch needs a coordinate mapper in scope; emit it as a nested helper the callers
// pass in, so the 24x24 coordinates scale to whatever the badge is drawn at.
swift = swift.replacingOccurrences(
    of: "    static func path(for platform: Platform, in rect: CGRect) -> Path? {\n        var path: Path?\n        switch platform {\n",
    with: """
        static func path(for platform: Platform, in rect: CGRect) -> Path? {
            let scale = min(rect.width, rect.height) / 24
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
            }
            switch platform {

    """
)

try swift.write(to: URL(fileURLWithPath: outputPath), atomically: true, encoding: .utf8)
print("wrote \(outputPath)")

// MARK: - Contact sheet

guard !sheetPath.isEmpty else { exit(0) }

let columns = 4
let cell: CGFloat = 128
let rows = Int(ceil(Double(renderable.count) / Double(columns)))
let sheetWidth = CGFloat(columns) * cell
let sheetHeight = CGFloat(rows) * cell

guard let sheet = CGContext(
    data: nil, width: Int(sheetWidth), height: Int(sheetHeight),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

sheet.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
sheet.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))

for (offset, item) in renderable.enumerated() {
    let column = offset % columns
    let row = offset / columns
    // SVG's y axis points down and CoreGraphics' points up, so each cell is flipped.
    sheet.saveGState()
    sheet.translateBy(x: CGFloat(column) * cell, y: sheetHeight - CGFloat(row + 1) * cell)
    sheet.translateBy(x: 0, y: cell)
    sheet.scaleBy(x: 1, y: -1)

    // Preview the light-appearance badge: white mark on a black plate.
    let plate: CGFloat = 96
    let plateOrigin = (cell - plate) / 2
    let plateRect = CGRect(x: plateOrigin, y: plateOrigin, width: plate, height: plate)
    sheet.addPath(CGPath(
        roundedRect: plateRect, cornerWidth: plate * 0.28, cornerHeight: plate * 0.28, transform: nil
    ))
    sheet.setFillColor(CGColor(gray: 0, alpha: 1))
    sheet.fillPath()

    let inset = plate * 0.22
    let glyphSide = plate - inset * 2
    let scale = glyphSide / 24
    sheet.translateBy(x: plateOrigin + inset, y: plateOrigin + inset)
    sheet.scaleBy(x: scale, y: scale)
    sheet.addPath(item.1)
    sheet.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    sheet.fillPath(using: .winding)
    sheet.restoreGState()
}

if let image = sheet.makeImage(),
   let destination = CGImageDestinationCreateWithURL(
       URL(fileURLWithPath: sheetPath) as CFURL, "public.png" as CFString, 1, nil
   ) {
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("wrote \(sheetPath)")
}
