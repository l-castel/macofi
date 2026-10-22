// Draws the macofi app icon from scratch (no external artwork) and writes
// packaging/Macofi.icns plus docs/icon.png. Run via `make icon`.
//
// The .icns artwork is full-bleed: macOS 26+ masks it into the system icon shape itself
// (an icon with its own rounded tile and margin gets shrunk onto a gray plate instead).
// The README preview has the rounded shape drawn in, since nothing masks it there.
//
//   swift scripts/make-icon.swift <output-dir-for-iconset> <preview.png>
import AppKit

/// A prompt chevron and a cursor on a dark tile. `rounded` draws the tile as a squircle with
/// the standard margin (for previews); otherwise the artwork fills the canvas (for the .icns).
func drawIcon(in ctx: CGContext, size: CGFloat, rounded: Bool) {
    ctx.scaleBy(x: size / 1024, y: size / 1024) // laid out on Apple's 1024pt icon grid

    if rounded {
        let tile = squircle(in: CGRect(x: 100, y: 100, width: 824, height: 824), exponent: 5)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(tile)
        ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.106, blue: 0.149, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        // Hairline edge so the tile reads on dark backgrounds too.
        ctx.saveGState()
        ctx.addPath(tile)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08))
        ctx.setLineWidth(4)
        ctx.strokePath()
        ctx.restoreGState()
        ctx.addPath(tile)
        ctx.clip()
        // Fit the full-bleed artwork into the tile.
        ctx.translateBy(x: 100, y: 100)
        ctx.scaleBy(x: 824 / 1024, y: 824 / 1024)
    }
    drawArtwork(in: ctx)
}

/// The full-bleed 1024x1024 artwork.
func drawArtwork(in ctx: CGContext) {
    ctx.saveGState()
    let background = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        CGColor(srgbRed: 0.165, green: 0.180, blue: 0.259, alpha: 1), // #2a2e42 top
        CGColor(srgbRed: 0.086, green: 0.090, blue: 0.129, alpha: 1), // #161721 bottom
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])
    ctx.restoreGState()

    // The glyph: a chevron and a cursor bar, filled with the accent gradient and a soft glow.
    let glyph = CGMutablePath()
    let chevron = CGMutablePath()
    chevron.move(to: CGPoint(x: 322, y: 652))
    chevron.addLine(to: CGPoint(x: 486, y: 512))
    chevron.addLine(to: CGPoint(x: 322, y: 372))
    glyph.addPath(chevron.copy(strokingWithWidth: 68, lineCap: .round, lineJoin: .round, miterLimit: 10))
    glyph.addPath(CGPath(roundedRect: CGRect(x: 548, y: 338, width: 168, height: 64),
                         cornerWidth: 32, cornerHeight: 32, transform: nil))

    let accent = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        CGColor(srgbRed: 0.490, green: 0.812, blue: 1.0, alpha: 1),   // #7dcfff
        CGColor(srgbRed: 0.478, green: 0.635, blue: 0.969, alpha: 1), // #7aa2f7
        CGColor(srgbRed: 0.733, green: 0.604, blue: 0.969, alpha: 1), // #bb9af7
    ] as CFArray, locations: [0, 0.55, 1])!

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 60, color: CGColor(srgbRed: 0.478, green: 0.635, blue: 0.969, alpha: 0.55))
    ctx.addPath(glyph)
    ctx.setFillColor(CGColor(srgbRed: 0.478, green: 0.635, blue: 0.969, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(glyph)
    ctx.clip()
    ctx.drawLinearGradient(accent, start: CGPoint(x: 300, y: 680), end: CGPoint(x: 730, y: 330), options: [])
    ctx.restoreGState()
}

/// |x|^n + |y|^n = 1, the continuous-curvature shape macOS uses for app icons.
func squircle(in rect: CGRect, exponent n: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), sn = sin(t)
        let x = pow(abs(c), 2 / n) * (c < 0 ? -1 : 1)
        let y = pow(abs(sn), 2 / n) * (sn < 0 ? -1 : 1)
        let p = CGPoint(x: rect.midX + x * rect.width / 2, y: rect.midY + y * rect.height / 2)
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

func png(size: Int, rounded: Bool = false) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    drawIcon(in: ctx, size: CGFloat(size), rounded: rounded)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: make-icon.swift <iconset-dir> <preview.png>"); exit(2) }
let iconset = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(size: 512, rounded: true).write(to: URL(fileURLWithPath: args[2]))
