import ImageIO
import SwiftUI
import UIKit

/// Downsampled pictures from the media store, cached in memory.
@MainActor
final class Thumbs {
    static let shared = Thumbs()
    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 48 << 20
        return c
    }()

    func image(_ file: String, maxPixel: Int) async -> UIImage? {
        let key = "\(file)@\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let url = Core.shared.mediaURL(file)
        let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
        if let img { cache.setObject(img, forKey: key, cost: Int(img.size.width * img.size.height * 4)) }
        return img
    }
}

struct LocalImage: View {
    let file: String
    var maxPixel = 400
    var fill = true
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
            } else {
                Rectangle().fill(Color.secondary.opacity(0.12))
            }
        }
        .task(id: file) { image = await Thumbs.shared.image(file, maxPixel: maxPixel) }
    }
}
