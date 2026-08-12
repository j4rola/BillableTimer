import AppKit
import Foundation

// Builds the BillableTimer app icon from the running-hare silhouette artwork.
//
// The source is a solid black hare on white. Rather than drawing the bitmap
// directly — which would stamp a white rectangle onto the plate — its luminance
// is turned into an alpha mask: dark becomes opaque, white becomes transparent,
// and the antialiased edge is carried through as partial alpha. The silhouette is
// then painted in a single flat colour, so it composites cleanly over any plate
// and stays crisp at every size.
//
// A solid shape survives downsampling on its own, so unlike line-work there is no
// dilation or brightness trickery here.

let design: CGFloat = 1024

/// Resolved relative to the working directory when run from the project root,
/// with an absolute fallback so it also works from anywhere else.
let artworkPath: String = {
    let relative = "Resources/hare-source.png"
    if FileManager.default.fileExists(atPath: relative) { return relative }
    return "/Users/froula/Documents/BillableTimer/Resources/hare-source.png"
}()

/// Luminance range mapped to the alpha ramp. Anything lighter than `inkWhite` is
/// fully transparent; anything darker than `inkBlack` is fully opaque.
let inkWhite: CGFloat = 235
let inkBlack: CGFloat = 20

/// Fraction of the plate's width the hare spans.
let subjectWidthFraction: CGFloat = 0.82

func rgb(_ hex: UInt32) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
    (
        CGFloat((hex >> 16) & 0xFF) / 255,
        CGFloat((hex >> 8) & 0xFF) / 255,
        CGFloat(hex & 0xFF) / 255
    )
}

func cgColor(_ hex: UInt32) -> CGColor {
    let c = rgb(hex)
    return CGColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
}

let plateTop = cgColor(0xFDFBF7)
let plateBottom = cgColor(0xEBE7DD)
let inkColor = rgb(0x15171B)

func bitmapContext(width: Int, height: Int) -> CGContext {
    CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

/// Loads the artwork, finds the ink, and returns it as a flat-coloured silhouette
/// with a transparent ground, cropped tight to the subject.
let silhouette: CGImage = {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: artworkPath) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        FileHandle.standardError.write("Could not read artwork at \(artworkPath)\n".data(using: .utf8)!)
        exit(1)
    }

    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { raw in
        let ctx = CGContext(
            data: raw.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    // Luminance → alpha, and find the ink bounds in the same pass.
    var minX = width, maxX = -1, minY = height, maxY = -1
    var out = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            let luminance = (CGFloat(pixels[i]) * 0.30 + CGFloat(pixels[i + 1]) * 0.59 + CGFloat(pixels[i + 2]) * 0.11)
            let alpha = min(max((inkWhite - luminance) / (inkWhite - inkBlack), 0), 1)
            guard alpha > 0 else { continue }

            // Premultiplied, so the flat ink colour scales with coverage.
            out[i] = UInt8((inkColor.r * alpha * 255).rounded())
            out[i + 1] = UInt8((inkColor.g * alpha * 255).rounded())
            out[i + 2] = UInt8((inkColor.b * alpha * 255).rounded())
            out[i + 3] = UInt8((alpha * 255).rounded())

            if alpha > 0.5 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
    }
    guard maxX >= minX, maxY >= minY else {
        FileHandle.standardError.write("No ink found in artwork\n".data(using: .utf8)!)
        exit(1)
    }

    let full: CGImage = out.withUnsafeMutableBytes { raw in
        let ctx = CGContext(
            data: raw.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    // `cropping(to:)` takes a top-left origin rect.
    let crop = CGRect(
        x: minX, y: height - 1 - maxY,
        width: maxX - minX + 1, height: maxY - minY + 1
    )
    return full.cropping(to: crop) ?? full
}()

func drawIcon(_ ctx: CGContext, size: CGFloat) {
    let scale = size / design
    ctx.saveGState()
    // Flip into a y-down design space so the layout reads like an SVG.
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: scale, y: -scale)

    // macOS icon grid: rounded square inset within the full canvas.
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.clip()

    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [plateTop, plateBottom] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: plate.minY),
        end: CGPoint(x: 0, y: plate.maxY),
        options: []
    )

    let aspect = CGFloat(silhouette.width) / CGFloat(silhouette.height)
    let drawWidth = plate.width * subjectWidthFraction
    let drawHeight = drawWidth / aspect
    let target = CGRect(
        x: plate.midX - drawWidth / 2,
        y: plate.midY - drawHeight / 2,
        width: drawWidth,
        height: drawHeight
    )

    ctx.interpolationQuality = .high
    ctx.saveGState()
    // Undo the y-down flip just for the bitmap, which carries its own orientation.
    ctx.translateBy(x: target.minX, y: target.minY + target.height)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(silhouette, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
    ctx.restoreGState()

    ctx.restoreGState()
    ctx.restoreGState()
}

func render(size: Int, to url: URL) throws {
    let ctx = bitmapContext(width: size, height: size)
    ctx.setShouldAntialias(true)
    drawIcon(ctx, size: CGFloat(size))

    guard let image = ctx.makeImage() else { throw NSError(domain: "icon", code: 2) }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 3)
    }
    try png.write(to: url)
}

let outputDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

if CommandLine.arguments.count > 2, CommandLine.arguments[2] == "preview" {
    for size in [1024, 128, 64, 32, 16] {
        try render(size: size, to: outputDir.appendingPathComponent("preview-\(size).png"))
    }
    print("previews written")
} else {
    let variants: [(String, Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for (name, size) in variants {
        try render(size: size, to: outputDir.appendingPathComponent("\(name).png"))
    }
    print("wrote \(variants.count) icon sizes")
}
