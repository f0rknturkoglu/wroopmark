import Foundation
import SwiftUI

/// Mirrors `model::Item` in the core.
struct Item: Decodable, Identifiable, Hashable {
    let id: String
    let platform: String
    let url: String
    let authorHandle: String?
    let authorName: String?
    let title: String?
    let text: String
    let extra: String?
    let ocr: String?
    let createdAt: Int64?
    let savedAt: Int64
    let media: [Media]
    let links: [String]
    let quote: Quote?
    let tags: [String]
    let note: String?

    /// Boxed so `Item` can contain an `Item`.
    final class Quote: Decodable, @unchecked Sendable {
        let item: Item
        init(from decoder: Decoder) throws { item = try Item(from: decoder) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, platform, url, authorHandle, authorName, title, text, extra, ocr, createdAt, savedAt, media, links, quote, tags, note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? "web"
        url = try c.decode(String.self, forKey: .url)
        authorHandle = try c.decodeIfPresent(String.self, forKey: .authorHandle)
        authorName = try c.decodeIfPresent(String.self, forKey: .authorName)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        extra = try c.decodeIfPresent(String.self, forKey: .extra)
        ocr = try c.decodeIfPresent(String.self, forKey: .ocr)
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt)
        savedAt = try c.decodeIfPresent(Int64.self, forKey: .savedAt) ?? 0
        media = try c.decodeIfPresent([Media].self, forKey: .media) ?? []
        links = try c.decodeIfPresent([String].self, forKey: .links) ?? []
        quote = try c.decodeIfPresent(Quote.self, forKey: .quote)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    /// Everything the views show, so SwiftUI redraws when any of it changes.
    static func == (a: Item, b: Item) -> Bool {
        a.id == b.id && a.tags == b.tags && a.note == b.note && a.media == b.media && a.text == b.text
            && a.title == b.title && a.ocr == b.ocr && a.extra == b.extra && a.savedAt == b.savedAt
            && a.links == b.links && a.quote?.item == b.quote?.item
    }

    func hash(into h: inout Hasher) { h.combine(id) }

    var author: String? {
        if let h = authorHandle, !h.isEmpty { return "@\(h)" }
        return authorName
    }

    var headline: String {
        if let t = title, !t.isEmpty { return t }
        return text
    }

    var created: Date? { createdAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    var saved: Date { Date(timeIntervalSince1970: TimeInterval(savedAt)) }

    var allMedia: [Media] { media + (quote?.item.media ?? []) }

    /// First picture to show on a card: an image, or a video's poster.
    var cover: Media? { allMedia.first { $0.file != nil } }

    /// A TikTok photo post: several pictures meant to be swiped through.
    var isPhotoCarousel: Bool { platform == "tiktok" && media.count > 1 && media.allSatisfy { !$0.isVideo } }

    /// Something is not on disk yet (an image, a poster or a video).
    var needsDownload: Bool { allMedia.contains { !$0.isOffline } }
}

struct Media: Decodable, Hashable {
    let kind: String
    let url: String
    let thumbUrl: String?
    let file: String?
    let videoFile: String?
    let width: Int?
    let height: Int?
    let alt: String?

    var isVideo: Bool { kind != "image" }

    /// X serves plain mp4 files; TikTok only a page URL.
    var canDownloadVideo: Bool {
        isVideo && (url.split(separator: "?").first.map { $0.hasSuffix(".mp4") } ?? false)
    }

    /// Fully viewable without the network.
    var isOffline: Bool {
        guard file != nil else { return false }
        return !canDownloadVideo || videoFile != nil
    }

    var aspect: CGFloat? {
        guard let w = width, let h = height, w > 0, h > 0 else { return nil }
        return CGFloat(w) / CGFloat(h)
    }
}

struct LinkRow: Decodable, Identifiable, Hashable {
    let id: Int64
    let url: String
    let host: String
    let title: String?
    let description: String?
    let image: String?
    let firstSeen: Int64
    let manual: Bool
    let itemCount: Int
}

struct SearchResult: Decodable {
    let items: [Item]
    let total: Int
    let links: [LinkRow]
}

struct TagCount: Decodable, Hashable {
    let name: String
    let key: String
    let count: Int
}

struct Stats: Decodable {
    let items: Int
    let byPlatform: [String: Int]
    let tags: Int
    let links: Int
    let mediaPending: Int
    let ocrPending: Int?
    let mediaBytes: Int64?
    /// Videos only yt-dlp / gallery-dl can fetch (TikTok): still missing,
    /// and how many of those are waiting for a try.
    let videosMissing: Int?
    let videosQueued: Int?
}

/// An outside downloader the core found (`video_tools`).
struct VideoTool: Decodable, Hashable {
    let name: String
    let path: String
}

struct ImportReport: Decodable {
    let new: Int
    let updated: Int
    let ids: [String]
}

enum Platform: String, CaseIterable, Identifiable {
    case x, tiktok, pinterest, facebook, web

    var id: String { rawValue }

    var label: String {
        switch self {
        case .x: "X"
        case .tiktok: "TikTok"
        case .pinterest: "Pinterest"
        case .facebook: "Facebook"
        case .web: "Web"
        }
    }

    var symbol: String {
        switch self {
        case .x: "bird"
        case .tiktok: "music.note"
        case .pinterest: "pin"
        case .facebook: "person.2"
        case .web: "globe"
        }
    }

    var tint: Color {
        switch self {
        case .x: .primary
        case .tiktok: .pink
        case .pinterest: .red
        case .facebook: .blue
        case .web: .teal
        }
    }
}

/// A node of the tag tree built from `a/b/c` names.
struct TagNode: Identifiable, Hashable {
    let id: String // full key path, e.g. "dev/rust"
    let name: String // last segment as the user wrote it
    var count: Int
    var children: [TagNode]?

    static func tree(_ tags: [TagCount]) -> [TagNode] {
        var roots: [TagNode] = []
        for tag in tags {
            let names = tag.name.split(separator: "/").map(String.init)
            let keys = tag.key.split(separator: "/").map(String.init)
            insert(&roots, names: names[...], keys: keys[...], prefix: "", count: tag.count)
        }
        return roots
    }

    private static func insert(_ nodes: inout [TagNode], names: ArraySlice<String>, keys: ArraySlice<String>, prefix: String, count: Int) {
        guard let name = names.first, let key = keys.first else { return }
        let path = prefix.isEmpty ? key : "\(prefix)/\(key)"
        let i: Int
        if let found = nodes.firstIndex(where: { $0.id == path }) {
            i = found
        } else {
            nodes.append(TagNode(id: path, name: name, count: 0, children: nil))
            i = nodes.count - 1
        }
        if names.count == 1 {
            nodes[i].count += count
        } else {
            var kids = nodes[i].children ?? []
            insert(&kids, names: names.dropFirst(), keys: keys.dropFirst(), prefix: path, count: count)
            nodes[i].children = kids
        }
    }
}
