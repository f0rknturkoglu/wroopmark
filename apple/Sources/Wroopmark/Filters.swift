import Foundation

/// Result order; the raw value is what the core's `search` takes as `sort`.
enum SortOrder: String, CaseIterable, Identifiable {
    case relevance = ""
    case savedNewest = "saved"
    case savedOldest = "saved_asc"
    case postedNewest = "posted"
    case postedOldest = "posted_asc"
    case author
    case random

    var id: String { rawValue }

    var label: String {
        switch self {
        case .relevance: "Önerilen"
        case .savedNewest: "Kaydedilme: yeniden eskiye"
        case .savedOldest: "Kaydedilme: eskiden yeniye"
        case .postedNewest: "Paylaşılma: yeniden eskiye"
        case .postedOldest: "Paylaşılma: eskiden yeniye"
        case .author: "Kişiye göre (A–Z)"
        case .random: "Karışık"
        }
    }

    var help: String {
        switch self {
        case .relevance: "Arama varsa en uygun sonuç önce, yoksa son kaydedilen önce"
        default: label
        }
    }
}

/// The filter panel's state. It turns into ordinary search terms, so
/// everything it can do can also be typed in the search box.
struct AdvancedFilters: Equatable {
    enum Tri: String, CaseIterable, Identifiable {
        case any, yes, no
        var id: String { rawValue }
    }

    enum MediaFilter: String, CaseIterable, Identifiable {
        case any, image, video, media, none
        var id: String { rawValue }
        var label: String {
            switch self {
            case .any: "Fark etmez"
            case .image: "Fotoğraflı"
            case .video: "Videolu"
            case .media: "Herhangi bir medya"
            case .none: "Medyasız"
            }
        }
    }

    /// Which folder the posts are in. A folder includes its subfolders.
    enum FolderFilter: Hashable {
        case any
        case unfiled
        case filed
        /// Full path (`ders/matematik`); `id` is set when the path is a real
        /// folder rather than only a parent of one.
        case folder(path: String, id: Int64?)

        var path: String? {
            if case .folder(let path, _) = self { return path }
            return nil
        }
    }

    enum DateField: String, CaseIterable, Identifiable {
        case posted, saved
        var id: String { rawValue }
        var label: String { self == .posted ? "Paylaşılma tarihi" : "Kaydedilme tarihi" }
    }

    var platforms: Set<Platform> = []
    var media: MediaFilter = .any
    var folder: FolderFilter = .any
    var tagged: Tri = .any
    var link: Tri = .any
    var note: Tri = .any
    var ocr: Tri = .any
    var quote: Tri = .any
    var includeTags: [String] = []
    var excludeTags: [String] = []
    /// `@a, @b` — any of them.
    var authors = ""
    var excludeAuthors = ""
    var dateField: DateField = .posted
    var from: Date?
    var to: Date?

    var isEmpty: Bool { self == AdvancedFilters() }

    /// How many groups are set, for the toolbar badge.
    var activeCount: Int {
        var n = 0
        if !platforms.isEmpty { n += 1 }
        if media != .any { n += 1 }
        if folder != .any { n += 1 }
        n += [tagged, link, note, ocr, quote].filter { $0 != .any }.count
        if !includeTags.isEmpty || !excludeTags.isEmpty { n += 1 }
        if !handles(authors).isEmpty || !handles(excludeAuthors).isEmpty { n += 1 }
        if from != nil || to != nil { n += 1 }
        return n
    }

    /// The search terms these filters stand for.
    var terms: String {
        var t: [String] = []
        t += Platform.allCases.filter { platforms.contains($0) }.map { "platform:\($0.rawValue)" }
        switch media {
        case .any: break
        case .image: t.append("has:image")
        case .video: t.append("has:video")
        case .media: t.append("has:media")
        case .none: t.append("-has:media")
        }
        switch folder {
        case .any: break
        case .unfiled: t.append("is:unfiled")
        case .filed: t.append("is:infolder")
        case .folder(let path, let id):
            // The core reads an all-digit value as a folder id, so such a
            // name is matched by its id (without subfolders).
            if Int64(path) != nil, let id { t.append("folder:\(id)") } else { t.append("folder:" + Self.quoted(path)) }
        }
        func tri(_ v: Tri, _ term: String) {
            if v == .yes { t.append(term) } else if v == .no { t.append("-" + term) }
        }
        tri(tagged, "is:tagged")
        tri(link, "has:link")
        tri(note, "has:note")
        tri(ocr, "has:ocr")
        tri(quote, "has:quote")
        t += includeTags.map { "tag:" + Self.quoted($0) }
        t += excludeTags.map { "-tag:" + Self.quoted($0) }
        t += handles(authors).map { "from:@\($0)" }
        t += handles(excludeAuthors).map { "-from:@\($0)" }
        // The core reads `after:D` as "after day D" and `before:D` as
        // "before day D", so an inclusive range is widened by a day each way.
        let (afterKey, beforeKey) = dateField == .posted ? ("after", "before") : ("savedafter", "savedbefore")
        if let from, let day = Calendar.current.date(byAdding: .day, value: -1, to: from) {
            t.append("\(afterKey):\(Self.day(day))")
        }
        if let to, let day = Calendar.current.date(byAdding: .day, value: 1, to: to) {
            t.append("\(beforeKey):\(Self.day(day))")
        }
        return t.joined(separator: " ")
    }

    private func handles(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "@")).lowercased() }
            .filter { !$0.isEmpty }
    }

    private static func quoted(_ tag: String) -> String {
        tag.contains(" ") ? "\"\(tag)\"" : tag
    }

    private static func day(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 1, c.day ?? 1)
    }
}
