import Foundation
import ImageIO
import UniformTypeIdentifiers
import WidgetKit

/// Writes the posts the home screen widget shows, with small copies of
/// their pictures, in the app group's container: a random set from the
/// whole archive and a few from each folder (the widget can be set to one),
/// a new set each day. At most every three hours.
enum WidgetSnapshot {
    private struct Post: Codable {
        let id: String
        let author: String
        let text: String
        let platform: String
        let image: String?
        let video: Bool
        let folder: String?
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
        let seed = Int(Date.now.timeIntervalSince1970 / 86400) % 100_000
        let folders: [Folder] = (try? await Core.shared.call(.folders)) ?? []
        let names = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) })

        var picked: [Item] = []
        var seen = Set<String>()
        func take(_ q: String, _ count: Int) async {
            guard let r: SearchResult = try? await Core.shared.call(.search(q: q, sort: "random:\(seed)", limit: count * 3, offset: 0)) else { return }
            for item in r.items.filter({ $0.cover?.file != nil }).prefix(count) where seen.insert(item.id).inserted {
                picked.append(item)
            }
        }
        await take("", 48)
        for f in folders { await take("folder:\(f.id)", 12) }

        let tmp = dir.deletingLastPathComponent().appendingPathComponent("widget-new", isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        var posts: [Post] = []
        for item in picked {
            guard let file = item.cover?.file,
                  let small = thumbnail(Core.shared.mediaURL(file), to: tmp.appendingPathComponent("\(posts.count).jpg")) else { continue }
            let text = item.headline.isEmpty ? (item.quote?.item.text ?? "") : item.headline
            posts.append(Post(
                id: item.id,
                author: item.author ?? URL(string: item.url)?.host() ?? "",
                text: String(text.prefix(280)),
                platform: item.platform,
                image: small,
                video: item.allMedia.contains(where: \.isVideo),
                folder: item.folderId.flatMap { names[$0] }
            ))
        }
        guard !posts.isEmpty, let data = try? JSONEncoder().encode(posts) else { return }
        try? data.write(to: tmp.appendingPathComponent("posts.json"), options: .atomic)
        // Swapped in whole, so the widget never reads half a set.
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.moveItem(at: tmp, to: dir)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// A JPEG of at most 600 px; returns its file name.
    private static func thumbnail(_ src: URL, to dst: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary),
              let out = CGImageDestinationCreateWithURL(dst as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(out, cg, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        return CGImageDestinationFinalize(out) ? dst.lastPathComponent : nil
    }
}
