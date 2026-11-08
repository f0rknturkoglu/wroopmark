import AppKit
import ImageIO
import SwiftUI

/// Downsampled images from the media store.
///
/// The cache is read synchronously (NSCache is thread-safe), so a cell that
/// scrolls back into view shows its picture in the first frame instead of
/// flashing the placeholder. Decoding runs off the main thread and stops
/// when the cell asking for it goes away, so a fast scroll through a large
/// library does not leave hundreds of decodes queued behind it.
final class Thumbnails: @unchecked Sendable {
    static let shared = Thumbnails()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 128 << 20
        return c
    }()

    private static func key(_ file: String, _ maxPixel: Int) -> NSString { "\(file)@\(maxPixel)" as NSString }

    func cached(file: String, maxPixel: Int) -> NSImage? {
        cache.object(forKey: Self.key(file, maxPixel))
    }

    func image(file: String, maxPixel: Int) async -> NSImage? {
        let key = Self.key(file, maxPixel)
        if let hit = cache.object(forKey: key) { return hit }
        let url = Core.shared.mediaURL(file)
        let work = Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard !Task.isCancelled, let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
        guard let cg = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() }) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key, cost: cg.width * cg.height * 4)
        return image
    }
}

/// A local media file, filled to its frame.
struct LocalImage: View {
    let file: String
    var maxPixel = 640
    var contentMode: ContentMode = .fill
    /// Grey box while loading; off where the backdrop should show through.
    var placeholder = true
    @State private var image: NSImage?

    init(file: String, maxPixel: Int = 640, contentMode: ContentMode = .fill, placeholder: Bool = true) {
        self.file = file
        self.maxPixel = maxPixel
        self.contentMode = contentMode
        self.placeholder = placeholder
        _image = State(initialValue: Thumbnails.shared.cached(file: file, maxPixel: maxPixel))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
            } else if placeholder {
                Rectangle().fill(.quaternary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: file) {
            if let hit = Thumbnails.shared.cached(file: file, maxPixel: maxPixel) {
                if hit !== image { image = hit }
                return
            }
            image = nil
            image = await Thumbnails.shared.image(file: file, maxPixel: maxPixel)
        }
    }
}
