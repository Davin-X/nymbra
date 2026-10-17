#!/usr/bin/env swift

// Draws Nymbra's application icon and compiles it into an `.icns`.
//
// The artwork is drawn here rather than stored as a binary so that it is
// reviewable, reproducible, and has no third-party provenance: a prompt chevron
// and a block cursor on the same background the terminal itself uses. It is only
// ever run by `Scripts/make-app.sh`, never by the app.
//
// Usage: swift Scripts/make-icon.swift <out.icns> [preview.png]

import AppKit
import CoreGraphics
import Foundation

// MARK: - The drawing
//
// Everything is expressed as a fraction of the *rounded square*, so the same
// code produces a legible 16px icon and a 1024px one. `y` is measured from the
// top here and flipped once, because that is how the geometry reads.

private let backgroundTop = (r: 0x1B, g: 0x23, b: 0x38)
private let backgroundBottom = (r: 0x0B, g: 0x0E, b: 0x18)
private let edge = (r: 0x2B, g: 0x3A, b: 0x5C)
private let chevron = (r: 0x6E, g: 0x8C, b: 0xF0)
private let cursor = (r: 0xD9, g: 0xE6, b: 0xFF)

/// macOS draws icons inside a grid: the rounded square does not fill the canvas,
/// and its corner radius is a fixed fraction of its side. Matching that grid is
/// what makes the icon look native next to every other one in the Dock.
private let inset = 0.094
private let cornerRadius = 0.2247

private func colour(_ c: (r: Int, g: Int, b: Int), _ a: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
        blue: CGFloat(c.b) / 255, alpha: a
    )
}

private func draw(into ctx: CGContext, size: CGFloat) {
    let side = size * (1 - inset * 2)
    let origin = size * inset

    // The mark is enlarged as the canvas shrinks. At 16px a faithful copy of the
    // 1024px drawing is a smudge of dark pixels; growing the mark keeps it
    // recognisable in the Dock, the tab bar and Spotlight.
    let zoom: CGFloat = size <= 32 ? 1.42 : (size <= 64 ? 1.18 : 1)

    // The rounded square, filled with a gradient. At 16px this is most of what
    // the icon is, so it is drawn first and unfussily.
    let shape = CGPath(
        roundedRect: CGRect(x: origin, y: origin, width: side, height: side),
        cornerWidth: side * cornerRadius, cornerHeight: side * cornerRadius,
        transform: nil
    )
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [colour(backgroundTop), colour(backgroundBottom)] as CFArray,
        locations: [0, 1]
    ) {
        // Top of the rounded square to its bottom, in the drawing's terms.
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: origin + side),
            end: CGPoint(x: 0, y: origin),
            options: []
        )
    }
    ctx.restoreGState()

    // Shorthand: fractions of the rounded square, y from the top. The zoom is
    // applied about the centre so the composition stays balanced.
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let cx = 0.5 + (x - 0.5) * zoom
        let cy = 0.5 + (y - 0.5) * zoom
        return CGPoint(x: origin + side * cx, y: origin + side * (1 - cy))
    }

    // Heavier strokes when the whole icon is a few pixels wide, because a
    // hairline that is correct at 1024 is invisible at 16.
    let stroke = side * (size <= 64 ? 0.105 : 0.082) * zoom

    // A rounded outline just inside the edge, so the shape still reads on a
    // light background without a double edge appearing at small sizes.
    if size >= 128 {
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.setStrokeColor(colour(edge))
        ctx.setLineWidth(max(1, size * 0.006))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // The prompt: `>` drawn as one polyline with round caps, which is what gives
    // it the same weight at every size.
    ctx.saveGState()
    ctx.setStrokeColor(colour(chevron))
    ctx.setLineWidth(stroke)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: point(0.325, 0.335))
    ctx.addLine(to: point(0.465, 0.5))
    ctx.addLine(to: point(0.325, 0.665))
    ctx.strokePath()
    ctx.restoreGState()

    // The block cursor, to the right of it.
    let blockWidth = 0.11
    let blockTop = 0.36
    let blockHeight = 0.28
    let block = CGPath(
        roundedRect: CGRect(
            x: origin + side * 0.565,
            y: origin + side * (1 - blockTop - blockHeight),
            width: side * blockWidth,
            height: side * blockHeight
        ),
        cornerWidth: side * 0.035, cornerHeight: side * 0.035,
        transform: nil
    )
    ctx.saveGState()
    ctx.addPath(block)
    ctx.setFillColor(colour(cursor))
    ctx.fillPath()
    ctx.restoreGState()
}

// MARK: - Rasterising

private func render(size: CGFloat) -> CGImage? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
              data: nil, width: Int(size), height: Int(size),
              bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return nil }
    draw(into: ctx, size: size)
    return ctx.makeImage()
}

/// Every size in a row, on grey so that both the dark edge and the light cursor
/// are visible against something.
private func previewStrip() -> CGImage? {
    let sizes: [CGFloat] = [16, 32, 64, 128, 256]
    let gap: CGFloat = 24
    let height: CGFloat = 300
    let width = sizes.reduce(gap) { $0 + $1 + gap }

    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
              data: nil, width: Int(width), height: Int(height),
              bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return nil }

    ctx.setFillColor(CGColor(srgbRed: 0.6, green: 0.6, blue: 0.62, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    var x = gap
    for size in sizes {
        if let image = render(size: size) {
            ctx.draw(image, in: CGRect(x: x, y: (height - size) / 2, width: size, height: size))
        }
        x += size + gap
    }
    return ctx.makeImage()
}

private func write(_ image: CGImage, to url: URL) throws {
    // "public.png" rather than a deprecated `kUTTypePNG`: the identifier has been
    // stable since long before UTI types were formalised in Swift.
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil
    ) else {
        throw IconError.cannotWrite(url.path)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw IconError.cannotWrite(url.path)
    }
}

private enum IconError: Error, CustomStringConvertible {
    case cannotRender(CGFloat)
    case cannotWrite(String)

    var description: String {
        switch self {
        case .cannotRender(let size): return "cannot render the icon at \(Int(size))px"
        case .cannotWrite(let path): return "cannot write \(path)"
        }
    }
}

// MARK: - Entry point

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <out.icns> [preview.png]\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])

// The ten files `iconutil` requires: each size, and each size's Retina pair.
let iconset: [(Int, CGFloat)] = [
    (16, 16), (32, 32), (64, 64), (128, 128),
    (256, 256), (512, 512), (1024, 1024),
]

do {
    let staging = FileManager.default.temporaryDirectory
        .appendingPathComponent("Nymbra-\(ProcessInfo.processInfo.processIdentifier).iconset")
    try? FileManager.default.removeItem(at: staging)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

    for (pixels, _) in iconset {
        guard let image = render(size: CGFloat(pixels)) else {
            throw IconError.cannotRender(CGFloat(pixels))
        }
        try write(image, to: staging.appendingPathComponent("icon_\(pixels).png"))
    }

    // `iconutil` wants the Retina names, not more sizes: 16@2x *is* 32.
    let names: [(String, Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]
    let source = staging.appendingPathComponent("source.iconset")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    for (name, pixels) in names {
        try FileManager.default.copyItem(
            at: staging.appendingPathComponent("icon_\(pixels).png"),
            to: source.appendingPathComponent(name)
        )
    }

    try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", source.path, "-o", output.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        FileHandle.standardError.write(Data("iconutil failed\n".utf8))
        exit(1)
    }

    // Optional: the same mark at every size it will actually be drawn at. Whether
    // a 16px icon still reads is not something to assume.
    if arguments.count >= 3, let strip = previewStrip() {
        try write(strip, to: URL(fileURLWithPath: arguments[2]))
    }

    try? FileManager.default.removeItem(at: staging)
    let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path))?[.size] as? Int ?? 0
    print("icon: \(output.path) (\(bytes) bytes)")
} catch {
    FileHandle.standardError.write(Data("icon: \(error)\n".utf8))
    exit(1)
}
