import Foundation
import ImageIO
import UniformTypeIdentifiers
import WidgetKit

/// Writes the posts the home screen widget shows: twelve with pictures,
/// a new random set each day, with small copies of their pictures, in the
/// app group's container. At most every three hours.
enum WidgetSnapshot {
    private struct Post: Codable {
        let id: String
        let author: String
        let text: String
        let platform: String
        let image: String?
        let video: Bool
    }

    private static let writtenKey = "widgetWrittenAt"

    @MainActor
    static func refresh(force: Bool = false) {
        if !force, let last = UserDefaults.standard.object(forKey: writtenKey) as? Date, Date.now.timeIntervalSince(last) < 3 * 3600 { return }
        UserDefaults.standard.set(Date.now, forKey: writtenKey)
        Task.detached(priority: .background) { await write() }
    }

    private static func write() async {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppPaths.appGroup)?
            .appendingPathComponent("widget", isDirectory: true) else { return }
        // The same set all day, another tomorrow.
        let day = Int(Date.now.timeIntervalSince1970 / 86400)
        guard let r: SearchResult = try? await Core.shared.call(.search(q: "has:image", sort: "random:\(day % 100_000)", limit: 12, offset: 0)) else { return }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var posts: [Post] = []
        for item in r.items {
            var image: String?
            if let file = item.cover?.file, let small = thumbnail(Core.shared.mediaURL(file), to: dir.appendingPathComponent("\(posts.count).jpg")) {
                image = small
            }
            let text = item.headline.isEmpty ? (item.quote?.item.text ?? "") : item.headline
            posts.append(Post(
                id: item.id,
                author: item.author ?? URL(string: item.url)?.host() ?? "",
                text: String(text.prefix(280)),
                platform: item.platform,
                image: image,
                video: item.allMedia.contains(where: \.isVideo)
            ))
        }
        guard let data = try? JSONEncoder().encode(posts) else { return }
        try? data.write(to: dir.appendingPathComponent("posts.json"), options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// A JPEG of at most 700 px; returns its file name.
    private static func thumbnail(_ src: URL, to dst: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 700,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary),
              let out = CGImageDestinationCreateWithURL(dst as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(out, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(out) ? dst.lastPathComponent : nil
    }
}
