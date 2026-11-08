import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Puts saved posts in Spotlight: text, author, tags and the text read from
/// pictures, with the post's own picture as the thumbnail. Choosing one
/// opens it in the app (see `WroopmarkApp`). All of it stays on the Mac.
@MainActor
enum Spotlight {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "spotlight") as? Bool ?? true }

    private static let indexedAtKey = "spotlightIndexedAt"
    private static let page = 500
    private static var fullTask: Task<Void, Never>?

    private struct Page: Decodable { let items: [Item] }

    /// Indexes the whole library, at most every six hours unless forced.
    /// Starts from an empty index, so posts deleted elsewhere (the CLI,
    /// another copy of the library) do not linger in Spotlight.
    static func reindex(force: Bool = false) {
        guard enabled, fullTask == nil else { return }
        if !force, let last = UserDefaults.standard.object(forKey: indexedAtKey) as? Date, Date.now.timeIntervalSince(last) < 6 * 3600 { return }
        fullTask = Task(priority: .background) {
            defer { fullTask = nil }
            try? await CSSearchableIndex.default().deleteAllSearchableItems()
            var offset = 0
            while !Task.isCancelled {
                guard let r: Page = try? await Core.shared.call(["cmd": "search", "q": "", "sort": "saved", "limit": page, "offset": offset]),
                      !r.items.isEmpty else { break }
                await index(r.items)
                offset += r.items.count
                if r.items.count < page { break }
            }
            UserDefaults.standard.set(Date.now, forKey: indexedAtKey)
        }
    }

    /// The newest saves, after the library changed behind the app's back
    /// (the browser extension).
    static func indexRecent() {
        guard enabled else { return }
        Task(priority: .background) {
            guard let r: Page = try? await Core.shared.call(["cmd": "search", "q": "", "sort": "saved", "limit": 50]) else { return }
            await index(r.items)
        }
    }

    static func remove(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: ids) { _ in }
    }

    static func clear() {
        fullTask?.cancel()
        UserDefaults.standard.removeObject(forKey: indexedAtKey)
        CSSearchableIndex.default().deleteAllSearchableItems { _ in }
    }

    private nonisolated static func index(_ items: [Item]) async {
        try? await CSSearchableIndex.default().indexSearchableItems(items.map(entry))
    }

    private nonisolated static func entry(_ item: Item) -> CSSearchableItem {
        let a = CSSearchableItemAttributeSet(contentType: .text)
        let who = item.authorName ?? item.authorHandle.map { "@\($0)" }
        let firstLine = item.text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
        a.title = item.title ?? firstLine.map { String($0.prefix(120)) } ?? who ?? item.url
        a.contentDescription = String(item.text.prefix(400))
        a.textContent = [item.text, item.note, item.ocr].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        a.keywords = item.tags + [item.platform] + (item.authorHandle.map { [$0] } ?? [])
        if let who { a.authorNames = [who] }
        a.contentCreationDate = Date(timeIntervalSince1970: TimeInterval(item.createdAt ?? item.savedAt))
        a.contentURL = URL(string: item.url)
        if let file = item.cover?.file { a.thumbnailURL = Core.shared.mediaURL(file) }
        return CSSearchableItem(uniqueIdentifier: item.id, domainIdentifier: item.platform, attributeSet: a)
    }
}
