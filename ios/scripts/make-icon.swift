// Renders the Resonote app icon set (light, dark, and tinted 1024 pt iOS icons)
// from the logo geometry in public/logo-mark.svg (viewBox 0 0 64 64):
//
//   disc     circle (32, 32) r 29   #181713
//   label    circle (32, 32) r 10   #F4EFE4
//   spindle  circle (32, 32) r 3    #D35D3F
//   tonearm  path "M47 14v22c0 8-5 14-12 14", stroke #D35D3F, width 4, round caps
//
// Usage (from anywhere):  swift ios/scripts/make-icon.swift [output .appiconset directory]
// The default output is ios/Resonote/Resources/Assets.xcassets/AppIcon.appiconset.
// The script also writes the set's Contents.json, so it is the single source of the icon.

import CoreGraphics
import Foundation
import ImageIO

let canvas = 1024
/// The record fills about three quarters of the canvas, which keeps it clear of the
/// icon mask and the Liquid Glass edge highlight.
let logoScale = 0.76 * CGFloat(canvas) / 58

struct Variant {
    let fileName: String
    /// `nil` draws on a transparent canvas.
    let background: UInt32?
    let disc: UInt32
    let label: UInt32
    let spindle: UInt32
    let arm: UInt32
    /// The appearance key in Contents.json, or `nil` for the default (light) icon.
    let appearance: String?
}

let variants = [
    Variant(fileName: "AppIcon.png", background: 0xF4EFE4, disc: 0x181713, label: 0xF4EFE4, spindle: 0xD35D3F, arm: 0xD35D3F, appearance: nil),
    Variant(fileName: "AppIcon-Dark.png", background: 0x101113, disc: 0x23221D, label: 0xF4EFE4, spindle: 0xD35D3F, arm: 0xD35D3F, appearance: "dark"),
    // Tinted icons are grayscale: the system maps luminance to the person's tint.
    Variant(fileName: "AppIcon-Tinted.png", background: nil, disc: 0x3C3C3C, label: 0xEDEDED, spindle: 0x3C3C3C, arm: 0xFFFFFF, appearance: "tinted"),
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

func color(_ hex: UInt32, in space: CGColorSpace) -> CGColor {
    let components: [CGFloat] = [
        CGFloat((hex >> 16) & 0xFF) / 255,
        CGFloat((hex >> 8) & 0xFF) / 255,
        CGFloat(hex & 0xFF) / 255,
        1,
    ]
    guard let color = CGColor(colorSpace: space, components: components) else { fail("could not make color \(hex)") }
    return color
}

func render(_ variant: Variant) -> CGImage {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { fail("sRGB color space unavailable") }
    // Opaque icons are written without an alpha channel; App Store Connect rejects
    // transparency in the primary icon.
    let alpha: CGImageAlphaInfo = variant.background == nil ? .premultipliedLast : .noneSkipLast
    guard let context = CGContext(
        data: nil,
        width: canvas,
        height: canvas,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: alpha.rawValue
    ) else { fail("could not create a bitmap context") }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let size = CGFloat(canvas)
    if let background = variant.background {
        context.setFillColor(color(background, in: space))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    } else {
        context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    }

    // SVG space: origin top-left, y down, logo centre (32, 32) on the canvas centre.
    context.translateBy(x: 0, y: size)
    context.scaleBy(x: 1, y: -1)
    context.translateBy(x: size / 2, y: size / 2)
    context.scaleBy(x: logoScale, y: logoScale)
    context.translateBy(x: -32, y: -32)

    func circle(radius: CGFloat, fill hex: UInt32) {
        context.setFillColor(color(hex, in: space))
        context.fillEllipse(in: CGRect(x: 32 - radius, y: 32 - radius, width: radius * 2, height: radius * 2))
    }

    circle(radius: 29, fill: variant.disc)
    circle(radius: 10, fill: variant.label)
    circle(radius: 3, fill: variant.spindle)

    // M47 14 v22 c0 8 -5 14 -12 14
    let arm = CGMutablePath()
    arm.move(to: CGPoint(x: 47, y: 14))
    arm.addLine(to: CGPoint(x: 47, y: 36))
    arm.addCurve(to: CGPoint(x: 35, y: 50), control1: CGPoint(x: 47, y: 44), control2: CGPoint(x: 42, y: 50))
    context.addPath(arm)
    context.setStrokeColor(color(variant.arm, in: space))
    context.setLineWidth(4)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()

    guard let image = context.makeImage() else { fail("could not render \(variant.fileName)") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fail("could not open \(url.path) for writing")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("could not write \(url.path)") }
}

func contentsJSON() -> Data {
    let images: [[String: Any]] = variants.map { variant in
        var entry: [String: Any] = [
            "filename": variant.fileName,
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024",
        ]
        if let appearance = variant.appearance {
            entry["appearances"] = [["appearance": "luminosity", "value": appearance]]
        }
        return entry
    }
    let document: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]) else {
        fail("could not encode Contents.json")
    }
    return data + Data("\n".utf8)
}

let scriptDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let defaultOutput = scriptDirectory
    .deletingLastPathComponent()
    .appending(path: "Resonote/Resources/Assets.xcassets/AppIcon.appiconset", directoryHint: .isDirectory)
let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    : defaultOutput

do {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try contentsJSON().write(to: output.appending(path: "Contents.json"), options: .atomic)
} catch {
    fail("could not prepare \(output.path): \(error.localizedDescription)")
}

for variant in variants {
    let url = output.appending(path: variant.fileName)
    writePNG(render(variant), to: url)
    FileHandle.standardOutput.write(Data("wrote \(url.path)\n".utf8))
}
