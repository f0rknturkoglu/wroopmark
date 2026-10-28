// Draws the wroopmark icon: white "WM" on a violet squircle.
//
//   swift apple/scripts/make-icon.swift <out.png> [app|flat]
//
// `app` follows the macOS icon grid (824 pt shape on a 1024 canvas, with
// shadow); `flat` fills the canvas for browser-extension icons.
import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: make-icon.swift <out.png> [app|flat]")
    exit(1)
}
let flat = args.count > 2 && args[2] == "flat"
let size: CGFloat = 1024

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

let inset: CGFloat = flat ? 24 : 100
let rect = CGRect(x: inset, y: inset + (flat ? 0 : 10), width: size - inset * 2, height: size - inset * 2)
let radius = rect.width * 0.225
let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

// Soft drop shadow under the tile (macOS grid only).
if !flat {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    NSColor(calibratedRed: 0.36, green: 0.18, blue: 0.80, alpha: 1).setFill()
    shape.fill()
    ctx.restoreGState()
}

// Violet gradient, lighter at the top left.
ctx.saveGState()
shape.addClip()
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.66, green: 0.47, blue: 1.00, alpha: 1),
    NSColor(calibratedRed: 0.47, green: 0.29, blue: 0.93, alpha: 1),
    NSColor(calibratedRed: 0.31, green: 0.14, blue: 0.72, alpha: 1),
], atLocations: [0, 0.5, 1], colorSpace: .deviceRGB)!
gradient.draw(in: rect, angle: -60)

// Glassy highlight across the upper half.
let gloss = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
gloss.draw(in: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)

// Fine inner edge.
NSColor.white.withAlphaComponent(0.18).setStroke()
let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: radius - 2, yRadius: radius - 2)
edge.lineWidth = 4
edge.stroke()
ctx.restoreGState()

// "WM", rounded and heavy, optically centered.
let base = NSFont.systemFont(ofSize: rect.width * 0.40, weight: .heavy)
let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: base.pointSize) } ?? base
let shadow = NSShadow()
shadow.shadowColor = NSColor(calibratedRed: 0.15, green: 0.03, blue: 0.40, alpha: 0.45)
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowBlurRadius = 18
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.white,
    .kern: -rect.width * 0.012,
    .shadow: shadow,
]
let text = NSAttributedString(string: "WM", attributes: attrs)
let bounds = text.boundingRect(with: NSSize(width: size, height: size), options: [.usesLineFragmentOrigin, .usesFontLeading])
let capHeight = font.capHeight
let origin = CGPoint(
    x: rect.midX - bounds.width / 2,
    y: rect.midY - capHeight / 2 + font.descender * -0.05 - (bounds.height - capHeight) / 2 + rect.height * 0.01
)
text.draw(at: origin)

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: args[1]))
