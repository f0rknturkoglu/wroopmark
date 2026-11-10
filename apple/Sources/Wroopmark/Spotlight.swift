import CoreSpotlight
import Foundation
import os
import UniformTypeIdentifiers

/// Puts saved posts in Spotlight: text, author, tags and the text read from
/// pictures, with the post's own picture as the thumbnail. Choosing one
/// opens it in the app (see `WroopmarkApp`). All of it stays on the Mac.
@MainActor
enum Spotlight {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "spotlight") as? Bool ?? true }

    private static let indexedAtKey = "spotlightIndexedAt"
    private nonisolated static let page = 500
    private nonisolated static let logger = Logger(subsystem: "com.wroopmark", category: "Spotlight")
    private static var fullTask: Task<Void, Never>?
    private static var recentTask: Task<Void, Never>?

    private struct Page: Decodable, Sendable { let items: [Item] }

    /// Indexes the whole library, at most every six hours unless forced.
    /// Ensures the library can open before clearing the index so DB failures
    /// or cancellations do not wipe existing Spotlight entries.
    static func reindex(force: Bool = false, core: any CoreClient = Core.shared) {
        guard enabled, fullTask == nil else { return }
        if !force, let last = UserDefaults.standard.object(forKey: indexedAtKey) as? Date, Date.now.timeIntervalSince(last) < 6 * 3600 {
            return
        }
        fullTask = Task(priority: .background) {
            defer { fullTask = nil }
            let completed = await performFullReindex(core: core)
            if completed && !Task.isCancelled {
                UserDefaults.standard.set(Date.now, forKey: indexedAtKey)
            }
        }
    }

    private nonisolated static func performFullReindex(core: any CoreClient) async -> Bool {
        guard await core.ensureOpen(), !Task.isCancelled else { return false }
        do {
            try await CSSearchableIndex.default().deleteAllSearchableItems()
            var offset = 0
            while !Task.isCancelled {
                let r: Page = try await core.call(.search(q: "", sort: "saved", limit: page, offset: offset))
                guard !r.items.isEmpty, !Task.isCancelled else { break }
                let entries = r.items.map { entry($0, core: core) }
                try await CSSearchableIndex.default().indexSearchableItems(entries)
                offset += r.items.count
                if r.items.count < page { break }
            }
            return !Task.isCancelled
        } catch is CancellationError {
            return false
        } catch {
            logger.error("Spotlight full reindex failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The newest saves, after the library changed behind the app's back
    /// (the browser extension).
    static func indexRecent(core: any CoreClient = Core.shared) {
        guard enabled else { return }
        recentTask?.cancel()
        recentTask = Task(priority: .background) {
            defer { recentTask = nil }
            await performRecentIndex(core: core)
        }
    }

    private nonisolated static func performRecentIndex(core: any CoreClient) async {
        do {
            let r: Page = try await core.call(.search(q: "", sort: "saved", limit: 50, offset: 0))
            guard !Task.isCancelled, !r.items.isEmpty else { return }
            let entries = r.items.map { entry($0, core: core) }
            try await CSSearchableIndex.default().indexSearchableItems(entries)
        } catch is CancellationError {
            return
        } catch {
            logger.error("Spotlight recent index failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func remove(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: ids) { error in
            if let error {
                logger.error("Spotlight delete failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func clear() {
        fullTask?.cancel()
        fullTask = nil
        recentTask?.cancel()
        recentTask = nil
        UserDefaults.standard.removeObject(forKey: indexedAtKey)
        CSSearchableIndex.default().deleteAllSearchableItems { error in
            if let error {
                logger.error("Spotlight clear failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private nonisolated static func entry(_ item: Item, core: any CoreClient) -> CSSearchableItem {
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
        if let file = item.cover?.file { a.thumbnailURL = core.mediaURL(file) }
        return CSSearchableItem(uniqueIdentifier: item.id, domainIdentifier: item.platform, attributeSet: a)
    }
}
