import Foundation
import SwiftUI

/// Mirrors `model::Item` in the core.
struct Item: Decodable, Identifiable, Hashable, Sendable {
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
    let folderId: Int64?

    /// Boxed so `Item` can contain an `Item`. Immutable and thread-safe.
    final class Quote: Decodable, Sendable {
        let item: Item
        init(from decoder: Decoder) throws { item = try Item(from: decoder) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, platform, url, authorHandle, authorName, title, text, extra, ocr, createdAt, savedAt, media, links, quote, tags, note
        case folderId = "folder_id"
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
        folderId = try c.decodeIfPresent(Int64.self, forKey: .folderId)
    }

    init(
        id: String,
        platform: String,
        url: String,
        authorHandle: String?,
        authorName: String?,
        title: String?,
        text: String,
        extra: String?,
        ocr: String?,
        createdAt: Int64?,
        savedAt: Int64,
        media: [Media],
        links: [String],
        quote: Quote?,
        tags: [String],
        note: String?,
        folderId: Int64?
    ) {
        self.id = id
        self.platform = platform
        self.url = url
        self.authorHandle = authorHandle
        self.authorName = authorName
        self.title = title
        self.text = text
        self.extra = extra
        self.ocr = ocr
        self.createdAt = createdAt
        self.savedAt = savedAt
        self.media = media
        self.links = links
        self.quote = quote
        self.tags = tags
        self.note = note
        self.folderId = folderId
    }

    func withFolder(_ newFolderId: Int64?) -> Item {
        Item(
            id: id,
            platform: platform,
            url: url,
            authorHandle: authorHandle,
            authorName: authorName,
            title: title,
            text: text,
            extra: extra,
            ocr: ocr,
            createdAt: createdAt,
            savedAt: savedAt,
            media: media,
            links: links,
            quote: quote,
            tags: tags,
            note: note,
            folderId: newFolderId
        )
    }

    /// Everything the views show, so SwiftUI redraws when any of it changes.
    static func == (a: Item, b: Item) -> Bool {
        a.id == b.id && a.tags == b.tags && a.note == b.note && a.media == b.media && a.text == b.text
            && a.title == b.title && a.ocr == b.ocr && a.extra == b.extra && a.savedAt == b.savedAt
            && a.links == b.links && a.quote?.item == b.quote?.item && a.folderId == b.folderId
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

struct Media: Decodable, Hashable, Sendable {
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

struct LinkRow: Decodable, Identifiable, Hashable, Sendable {
    let id: Int64
    let url: String
    let host: String
    let title: String?
    let description: String?
    let image: String?
    let firstSeen: Int64
    let manual: Bool
    let itemCount: Int
    /// The last check found the page gone (404, 410, unknown host).
    let dead: Bool
    /// HTTP status of the last check; 0 when the host did not answer.
    let status: Int?
    let checkedAt: Int64?
}

/// A search kept in the sidebar. Stored in the library (so in its backups).
struct SavedSearch: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var query: String
}

/// A folder offered for the post on screen in the clean-up view.
struct FolderSuggestion: Decodable, Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
    let score: Double
    let reason: String

    var reasonLabel: String {
        switch reason {
        case "author": "aynı kişi"
        case "tag": "benzer etiket"
        default: "aynı site"
        }
    }
}

struct BackupReport: Decodable, Equatable, Sendable {
    let path: String
    let dbBytes: Int64
    let items: Int
    let filesTotal: Int
    let filesCopied: Int
    let bytesCopied: Int64
}

struct SearchResult: Decodable, Sendable {
    let items: [Item]
    let total: Int
    let links: [LinkRow]
}

struct TagCount: Decodable, Hashable, Sendable {
    let name: String
    let key: String
    let count: Int
}

struct Stats: Decodable, Equatable, Sendable {
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
struct VideoTool: Decodable, Hashable, Sendable {
    let name: String
    let path: String
}

struct ImportReport: Decodable, Sendable {
    let new: Int
    let updated: Int
    let ids: [String]
}

enum Platform: String, CaseIterable, Identifiable, Sendable {
    case x, tiktok, pinterest, facebook, reddit, youtube, instagram, github, hackernews, arxiv, web

    var id: String { rawValue }

    var label: String {
        switch self {
        case .x: "X"
        case .tiktok: "TikTok"
        case .pinterest: "Pinterest"
        case .facebook: "Facebook"
        case .reddit: "Reddit"
        case .youtube: "YouTube"
        case .instagram: "Instagram"
        case .github: "GitHub"
        case .hackernews: "Hacker News"
        case .arxiv: "arXiv"
        case .web: "Web"
        }
    }

    var symbol: String {
        switch self {
        case .x: "bird"
        case .tiktok: "music.note"
        case .pinterest: "pin"
        case .facebook: "person.2"
        case .reddit: "bubble.left.and.bubble.right.fill"
        case .youtube: "play.rectangle.fill"
        case .instagram: "camera.fill"
        case .github: "chevron.left.forwardslash.chevron.right"
        case .hackernews: "y.square.fill"
        case .arxiv: "doc.text.fill"
        case .web: "globe"
        }
    }

    var tint: Color {
        switch self {
        case .x: .primary
        case .tiktok: .pink
        case .pinterest: .red
        case .facebook: .blue
        case .reddit: .orange
        case .youtube: .red
        case .instagram: .purple
        case .github: .primary
        case .hackernews: .orange
        case .arxiv: .red
        case .web: .teal
        }
    }
}

/// A node of the tag tree built from `a/b/c` names.
struct TagNode: Identifiable, Hashable, Sendable {
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

enum AppTheme: String, CaseIterable, Identifiable, Codable, Sendable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "Sistem"
        case .light: "Açık Tema"
        case .dark: "Koyu Tema"
        }
    }
    var iconName: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.stars.fill"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct Folder: Identifiable, Decodable, Hashable, Sendable {
    let id: Int64
    let name: String
    let count: Int
    let createdAt: Int64?

    private enum CodingKeys: String, CodingKey {
        case id, name, count
        case createdAt = "created_at"
    }
}

/// A node in the folder tree built from `parent/child` folder names.
struct FolderNode: Identifiable, Hashable, Sendable {
    let id: String // full path e.g. "ders/matematik"
    let name: String // leaf name e.g. "matematik"
    let folder: Folder?
    var count: Int
    var children: [FolderNode]?

    /// Every node depth-first, for flat pickers.
    static func flattened(_ nodes: [FolderNode]) -> [FolderNode] {
        nodes.flatMap { [$0] + flattened($0.children ?? []) }
    }

    /// `ders › matematik`, for menus.
    var displayPath: String { id.replacingOccurrences(of: "/", with: " › ") }

    static func tree(_ folders: [Folder]) -> [FolderNode] {
        var roots: [FolderNode] = []
        for f in folders {
            let parts = f.name.split(separator: "/").map(String.init)
            insert(&roots, parts: parts[...], folder: f, prefix: "")
        }
        return roots
    }

    private static func insert(_ nodes: inout [FolderNode], parts: ArraySlice<String>, folder: Folder, prefix: String) {
        guard let name = parts.first else { return }
        let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
        let i: Int
        if let found = nodes.firstIndex(where: { $0.id == path }) {
            i = found
        } else {
            nodes.append(FolderNode(id: path, name: name, folder: parts.count == 1 ? folder : nil, count: 0, children: nil))
            i = nodes.count - 1
        }
        if parts.count == 1 {
            nodes[i] = FolderNode(id: path, name: name, folder: folder, count: folder.count, children: nodes[i].children)
        } else {
            var kids = nodes[i].children ?? []
            insert(&kids, parts: parts.dropFirst(), folder: folder, prefix: path)
            nodes[i].children = kids
            nodes[i].count += folder.count
        }
    }
}

struct DownloadItem: Identifiable, Decodable, Hashable, Sendable {
    let id: String
    let platform: String
    let url: String
    let authorHandle: String?
    let authorName: String?
    let title: String?
    let text: String
    let progress: Double?
    let speed: String?
    let eta: String?
    let status: String
    let tries: Int?
    let videoFile: String?
    let fileSize: Int64?
    let savedAt: Int64

    private enum CodingKeys: String, CodingKey {
        case id, platform, url, title, text, progress, speed, eta, status, tries
        case authorHandle = "author_handle"
        case authorName = "author_name"
        case videoFile = "video_file"
        case fileSize = "file_size"
        case savedAt = "saved_at"
    }

    var author: String? {
        if let h = authorHandle, !h.isEmpty { return "@\(h)" }
        return authorName
    }

    var headline: String {
        if let t = title, !t.isEmpty { return t }
        return text
    }

    var isCompleted: Bool { status == "completed" }
    var isDownloading: Bool { status == "downloading" }
    var isFailed: Bool { status == "failed" }
    var isQueued: Bool { status == "queued" }
}

struct DownloadsReport: Decodable, Equatable, Sendable {
    let active: [DownloadItem]
    let queued: [DownloadItem]
    let completed: [DownloadItem]
    let failed: [DownloadItem]

    var totalActiveOrQueued: Int { active.count + queued.count }
}
