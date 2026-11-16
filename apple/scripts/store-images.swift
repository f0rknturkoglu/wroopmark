// Store images from the app screenshots: a headline on the brand purple
// above the screenshot, at the App Store sizes, in English and Turkish;
// small copies for the README and a social preview for GitHub.
//
//   swift apple/scripts/store-images.swift
//
// Reads apple/iOS/Screenshots/{en,tr}/{iphone,ipad}/*.png (taken from a
// demo library, see AppStore.md) and writes apple/iOS/Screenshots/store/
// (not in git) and docs/images/ (in git).

import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let shots = root.appendingPathComponent("apple/iOS/Screenshots")
let store = shots.appendingPathComponent("store")
let readme = root.appendingPathComponent("docs/images")

// Brand: the icon's purple, top to bottom.
let top = NSColor(srgbRed: 0.55, green: 0.38, blue: 0.94, alpha: 1)
let bottom = NSColor(srgbRed: 0.33, green: 0.18, blue: 0.74, alpha: 1)
let ink = NSColor.white

struct Shot {
    let file: String
    let en: (String, String)
    let tr: (String, String)
}

let phone: [Shot] = [
    Shot(file: "1-list", en: ("Everything you saved", "Offline and searchable"), tr: ("Kaydettiğin her şey", "İnternetsiz ve aranabilir")),
    Shot(file: "2-item", en: ("Posts keep their pictures", "Tags, folders, notes"), tr: ("Gönderi görselleriyle kalır", "Etiket, klasör, not")),
    Shot(file: "3-reader", en: ("A clean reader", "Themes, highlights, read aloud"), tr: ("Sade okuyucu", "Tema, vurgu, sesli okuma")),
    Shot(file: "4-triage", en: ("Tidy up with a swipe", "On-device summaries and folders"), tr: ("Kaydırarak ayıkla", "Cihazda özet ve klasör önerisi")),
]
let pad: [Shot] = [
    Shot(file: "1", en: ("Made for iPad too", "Scopes, list and post side by side"), tr: ("iPad için de", "Kapsam, liste ve kayıt yan yana")),
    Shot(file: "2", en: ("Decide in seconds", "Keep, delete or file away"), tr: ("Saniyeler içinde karar ver", "Sakla, sil ya da klasöre koy")),
]

func image(_ url: URL) -> NSImage? { NSImage(contentsOf: url) }

/// Draws into a bitmap of exactly `size` pixels.
func render(_ size: NSSize, _ draw: (NSRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func background(_ r: NSRect) {
    NSGradient(starting: top, ending: bottom)?.draw(in: r, angle: -90)
}

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, in r: NSRect, alpha: CGFloat = 1) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineBreakMode = .byWordWrapping
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: ink.withAlphaComponent(alpha),
        .paragraphStyle: style,
    ]
    (s as NSString).draw(with: r, options: [.usesLineFragmentOrigin], attributes: attrs)
}

/// The screenshot with rounded corners and a soft shadow.
func device(_ img: NSImage, in r: NSRect, radius: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = radius * 0.6
    shadow.shadowOffset = NSSize(width: 0, height: -radius * 0.25)
    shadow.set()
    NSColor.black.setFill()
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).addClip()
    img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
}

func save(_ rep: NSBitmapImageRep, png url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}

func save(_ rep: NSBitmapImageRep, jpeg url: URL, width: CGFloat) {
    let scale = width / rep.size.width
    let small = render(NSSize(width: width, height: (rep.size.height * scale).rounded())) { r in
        NSImage(size: rep.size, flipped: false) { _ in rep.draw(); return true }.draw(in: r)
    }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? small.representation(using: .jpeg, properties: [.compressionFactor: 0.82])?.write(to: url)
}

var made = 0
for lang in ["en", "tr"] {
    // iPhone 6.9": 1320 × 2868.
    for s in phone {
        let src = shots.appendingPathComponent("\(lang)/iphone/\(lang)-\(s.file).png")
        guard let img = image(src) else { print("missing \(src.path)"); continue }
        let (title, sub) = lang == "en" ? s.en : s.tr
        let rep = render(NSSize(width: 1320, height: 2868)) { r in
            background(r)
            text(title, size: 96, weight: .bold, in: NSRect(x: 80, y: r.height - 330, width: r.width - 160, height: 220))
            text(sub, size: 54, weight: .medium, in: NSRect(x: 80, y: r.height - 450, width: r.width - 160, height: 110), alpha: 0.88)
            let w: CGFloat = 1060, h = w * img.size.height / img.size.width
            device(img, in: NSRect(x: (r.width - w) / 2, y: r.height - 540 - h, width: w, height: h), radius: 70)
        }
        save(rep, png: store.appendingPathComponent("\(lang)/iphone-\(s.file).png"))
        save(rep, jpeg: readme.appendingPathComponent("\(lang)-iphone-\(s.file).jpg"), width: 440)
        made += 1
    }
    // iPad 13" landscape: 2752 × 2064.
    for s in pad {
        let src = shots.appendingPathComponent("\(lang)/ipad/ipad-\(lang)-\(s.file).png")
        guard let img = image(src) else { print("missing \(src.path)"); continue }
        let (title, sub) = lang == "en" ? s.en : s.tr
        let rep = render(NSSize(width: 2752, height: 2064)) { r in
            background(r)
            text(title, size: 104, weight: .bold, in: NSRect(x: 120, y: r.height - 250, width: r.width - 240, height: 150))
            text(sub, size: 58, weight: .medium, in: NSRect(x: 120, y: r.height - 345, width: r.width - 240, height: 90), alpha: 0.88)
            let w: CGFloat = 2240, h = w * img.size.height / img.size.width
            device(img, in: NSRect(x: (r.width - w) / 2, y: r.height - 420 - h, width: w, height: h), radius: 48)
        }
        save(rep, png: store.appendingPathComponent("\(lang)/ipad-\(s.file).png"))
        save(rep, jpeg: readme.appendingPathComponent("\(lang)-ipad-\(s.file).jpg"), width: 900)
        made += 1
    }
}

// GitHub social preview: 1280 × 640.
if let logo = image(root.appendingPathComponent("docs/logo.png")),
   let a = image(shots.appendingPathComponent("en/iphone/en-1-list.png")),
   let b = image(shots.appendingPathComponent("en/iphone/en-3-reader.png")) {
    let rep = render(NSSize(width: 1280, height: 640)) { r in
        background(r)
        logo.draw(in: NSRect(x: 80, y: 360, width: 150, height: 150))
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        ("wroopmark" as NSString).draw(at: NSPoint(x: 80, y: 250), withAttributes: [.font: NSFont.systemFont(ofSize: 76, weight: .heavy), .foregroundColor: ink])
        ("Your saved posts, videos and pages.\nOffline, searchable, on your devices." as NSString).draw(
            with: NSRect(x: 84, y: 120, width: 640, height: 120), options: [.usesLineFragmentOrigin],
            attributes: [.font: NSFont.systemFont(ofSize: 30, weight: .medium), .foregroundColor: ink.withAlphaComponent(0.9), .paragraphStyle: style])
        let h: CGFloat = 560, w = h * a.size.width / a.size.height
        device(b, in: NSRect(x: 1280 - 60 - w, y: 40, width: w, height: h), radius: 36)
        device(a, in: NSRect(x: 1280 - 100 - 2 * w, y: 60, width: w, height: h), radius: 36)
    }
    save(rep, png: root.appendingPathComponent("docs/images/social-preview.png"))
    made += 1
}
print("made \(made) images")
