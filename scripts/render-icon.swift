#!/usr/bin/env swift
// Rebuild on macOS: swift scripts/render-icon.swift
// Optional first argument: output directory (defaults to this repository's Assets).
// Original vector artwork: two overlapping portrait displays, with no upstream logos.
// Every icon size is rendered from vectors; tiny sizes omit the glass detail and device bars.
// AppKit/CoreGraphics encode PNGs, then Apple's iconutil packages the standard .iconset.
import AppKit
import Foundation

func color(_ rgb: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: alpha)
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fill(_ context: CGContext, _ path: CGPath, _ fill: CGColor) {
    context.addPath(path); context.setFillColor(fill); context.fillPath()
}

func gradient(_ context: CGContext, path: CGPath, colors: [CGColor], from: CGPoint, to: CGPoint) {
    context.saveGState()
    context.addPath(path); context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: from, end: to,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

func display(_ context: CGContext, rect: CGRect, radius: CGFloat, primary: Bool, detailed: Bool) {
    let shell = rounded(rect, radius)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -15), blur: 22, color: color(0x020C22, alpha: 0.38))
    fill(context, shell, color(primary ? 0x93CEFF : 0x55DABC))
    context.restoreGState()
    gradient(context, path: shell,
             colors: [color(primary ? 0xD6EEFF : 0x98F5DD), color(primary ? 0x5CAAF7 : 0x2AB397)],
             from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.maxX, y: rect.minY))

    let inset: CGFloat = primary ? 20 : 18
    let screenRect = rect.insetBy(dx: inset, dy: inset)
    let screen = rounded(screenRect, radius - inset)
    gradient(context, path: screen,
             colors: [color(primary ? 0x398FE9 : 0x2F9C99), color(primary ? 0x19468D : 0x15565E)],
             from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.maxX, y: rect.minY))

    guard detailed else { return }
    context.saveGState()
    context.addPath(screen); context.clip()
    let glass = CGMutablePath()
    glass.move(to: CGPoint(x: screenRect.minX, y: screenRect.maxY))
    glass.addLine(to: CGPoint(x: screenRect.maxX, y: screenRect.maxY))
    glass.addLine(to: CGPoint(x: screenRect.maxX, y: screenRect.minY + screenRect.height * 0.65))
    glass.addLine(to: CGPoint(x: screenRect.minX, y: screenRect.minY + screenRect.height * 0.42))
    glass.closeSubpath()
    gradient(context, path: glass, colors: [color(0xFFFFFF, alpha: 0.13), color(0xFFFFFF, alpha: 0)],
             from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.maxX, y: rect.minY))
    context.restoreGState()
    let speakerWidth: CGFloat = primary ? 64 : 50
    fill(context, rounded(CGRect(x: rect.midX - speakerWidth / 2, y: rect.maxY - 48,
                                  width: speakerWidth, height: 9), 4.5), color(0x06284D, alpha: 0.55))
    let homeWidth: CGFloat = primary ? 94 : 72
    fill(context, rounded(CGRect(x: rect.midX - homeWidth / 2, y: rect.minY + 35,
                                  width: homeWidth, height: 9), 4.5), color(0xE4F7FF, alpha: 0.78))
}

func render(size: Int) throws -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "IconRendering", code: 1)
    }
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let base = rounded(CGRect(x: 80, y: 80, width: 864, height: 864), 190)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 16, color: color(0x000817, alpha: 0.25))
    fill(context, base, color(0x132B4A))
    context.restoreGState()
    gradient(context, path: base, colors: [color(0x23486C), color(0x10223D), color(0x0B182C)],
             from: CGPoint(x: 100, y: 944), to: CGPoint(x: 820, y: 80))
    // Subtle inner edge gives the rounded tile definition without a hard outline.
    context.saveGState()
    context.addPath(base); context.clip()
    context.addPath(rounded(CGRect(x: 82, y: 82, width: 860, height: 860), 188))
    context.setStrokeColor(color(0xD0EDFF, alpha: 0.10)); context.setLineWidth(3); context.strokePath()
    context.restoreGState()

    display(context, rect: CGRect(x: 493, y: 324, width: 285, height: 498),
            radius: 47, primary: false, detailed: size >= 64)
    display(context, rect: CGRect(x: 246, y: 210, width: 340, height: 570),
            radius: 52, primary: true, detailed: size >= 64)
    guard let image = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconRendering", code: 2)
    }
    return png
}

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? repository.appendingPathComponent("Assets", isDirectory: true)
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("scrcpy-viewer-icon-\(UUID().uuidString)", isDirectory: true)
let iconset = temporary.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(points)x\(points)\(suffix).png"
        try render(size: points * scale).write(to: iconset.appendingPathComponent(name))
    }
}
try render(size: 1024).write(to: output.appendingPathComponent("AppIcon.png"))
let packager = Process()
packager.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
packager.arguments = ["-c", "icns", "-o", output.appendingPathComponent("AppIcon.icns").path, iconset.path]
try packager.run()
packager.waitUntilExit()
guard packager.terminationStatus == 0 else { throw NSError(domain: "IconPackaging", code: Int(packager.terminationStatus)) }
print("Generated \(output.appendingPathComponent("AppIcon.icns").path)")
print("Preview   \(output.appendingPathComponent("AppIcon.png").path)")
