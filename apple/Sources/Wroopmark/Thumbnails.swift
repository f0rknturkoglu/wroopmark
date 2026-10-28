import AppKit
import ImageIO
import SwiftUI

/// Downsampled images from the media store. Decoding goes through ImageIO
/// thumbnails off the main thread, so a grid of 4K photos costs a few MB.
final class Thumbnails: @unchecked Sendable {
    static let shared = Thumbnails()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 96 << 20
        return c
    }()

    func image(file: String, maxPixel: Int) async -> NSImage? {
        let key = "\(file)@\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let url = Core.shared.mediaURL(file)
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let image {
            cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
        }
        return image
    }
}

/// A local media file, filled to its frame.
struct LocalImage: View {
    let file: String
    var maxPixel = 640
    var contentMode: ContentMode = .fill
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .task(id: file) {
            image = await Thumbnails.shared.image(file: file, maxPixel: maxPixel)
        }
    }
}
