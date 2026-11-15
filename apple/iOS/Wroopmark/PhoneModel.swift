import Observation
import SwiftUI
import UIKit

/// What the list shows besides the search box.
enum PhoneScope: Hashable, Sendable {
    case all
    case untagged
    case platform(String)
    case tag(String)
    case folder(Int64, String)

    var filter: String {
        switch self {
        case .all: ""
        case .untagged: "is:untagged"
        case .platform(let p): "platform:\(p)"
        case .tag(let t): t.contains(" ") ? "tag:\"\(t)\"" : "tag:\(t)"
        case .folder(let id, _): "folder:\(id)"
        }
    }

    var title: String {
        switch self {
        case .all: "wroopmark"
        case .untagged: "Etiketsiz"
        case .platform(let p): Platform(rawValue: p)?.label ?? p
        case .tag(let t): "#\(t)"
        case .folder(_, let name): name.split(separator: "/").last.map(String.init) ?? name
        }
    }
}

@MainActor
@Observable
final class PhoneModel {
    let core = Core.shared

    var items: [Item] = []
    var total = 0
    var query = ""
    var scope: PhoneScope = .all
    var tags: [TagCount] = []
    var folders: [Folder] = []
    var stats: Stats?
    var isLoading = false
    var errorMessage: String?
    /// Note shown above the list (a link saved without the network…).
    var notice: String?
    /// Free space on the phone; below `lowSpaceLimit` new pictures wait.
    var freeSpace: Int64?
    var lowSpace = false
    private static let lowSpaceLimit: Int64 = 1_000_000_000
    private(set) var reachedEnd = false
    private var generation = 0
    private var searchTask: Task<Void, Never>?
    private let pageSize = 60

    // Sync (PhoneSync.swift)
    var syncStatus: SyncStatus?
    var syncFolder: URL? { didSet { PhoneMedia.syncFolder = syncFolder } }
    /// A link waits on the clipboard (detected without reading it, so iOS
    /// shows no paste prompt; the paste button reads it).
    var clipboardHasLink = false
    @ObservationIgnored private var clipboardChange = 0
    /// Videos copied to the phone that the sync folder also has.
    var offloadable: (files: Int, bytes: Int64)?
    var isSyncing = false
    var syncMessage: String?
    var lastSyncAt: Date?
    /// Pictures from the Mac still coming down from iCloud.
    var syncWaiting = 0
    /// When each file was last asked of iCloud.
    @ObservationIgnored var askedICloud: [String: Date] = [:]
    @ObservationIgnored var mediaRound: Task<Void, Never>?

    /// An item to show (from a `wroopmark://item/<id>` link).
    var openRequest: String?

    /// `wroopmark://item/<id>`, `wroopmark://search?q=…`.
    func open(_ url: URL) {
        guard url.scheme == "wroopmark" else { return }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        switch url.host {
        case "item":
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !id.isEmpty { openRequest = id }
        case "search":
            scope = .all
            query = parts?.queryItems?.first { $0.name == "q" }?.value ?? ""
        default:
            break
        }
    }

    /// Set by the "search wroopmark" shortcut before the app comes up.
    static var pendingQuery: String?

    var effectiveQuery: String {
        [scope.filter, query.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }.joined(separator: " ")
    }

    func start() async {
        guard await core.ensureOpen() else {
            errorMessage = "Kütüphane açılamadı"
            return
        }
        // The phone never downloads videos from the sites themselves; a
        // video plays here only if the Mac put its file in the sync folder.
        _ = try? await core.run(.setSettings(downloadVideos: false))
        Self.keepMediaOutOfBackups(core.libraryURL)
        await checkSpace(force: true)
        fetchShared()
        takePendingQuery()
        await reload()
        await refreshMeta()
        await startSync()
        Spotlight.reindex()
        // Posts in the widget's new format (folders) after the update.
        WidgetSnapshot.refresh(force: UserDefaults.standard.integer(forKey: "widgetFormat") < 2)
        UserDefaults.standard.set(2, forKey: "widgetFormat")
        await checkClipboard()
        #if DEBUG
        if let id = ProcessInfo.processInfo.environment["WROOPMARK_OPEN_ITEM"], !id.isEmpty { openRequest = id }
        #endif
    }

    func checkClipboard() async {
        let pb = UIPasteboard.general
        let change = pb.changeCount
        guard change != UserDefaults.standard.integer(forKey: "clipboardOffered"), pb.hasURLs || pb.hasStrings else {
            clipboardHasLink = false
            return
        }
        let found = (try? await pb.detectedPatterns(for: [\.probableWebURL])) ?? []
        clipboardChange = change
        clipboardHasLink = found.contains(\.probableWebURL)
    }

    /// The same clipboard is not offered again.
    func dismissClipboard() {
        UserDefaults.standard.set(clipboardChange, forKey: "clipboardOffered")
        clipboardHasLink = false
    }

    func becameActive() async {
        takePendingQuery()
        await checkClipboard()
        // Links saved from the share sheet meanwhile: show them, fill them in.
        await reload()
        await checkSpace()
        fetchShared()
        await syncNow()
    }

    /// Going to the background: stop downloads and settle the database, so
    /// iOS does not find the shared library locked while the app sleeps.
    func enteredBackground() {
        let task = BackgroundTask(name: "wroopmark-pause")
        Task {
            _ = try? await core.run(.call("pause", [:]))
            task.end()
        }
    }

    /// Low on space: pictures stop downloading until there is room again.
    func checkSpace(force: Bool = false) async {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        freeSpace = free
        let low = (free ?? .max) < Self.lowSpaceLimit
        guard force || low != lowSpace else { return }
        lowSpace = low
        _ = try? await core.run(.call("set_media_paused", ["on": .bool(low)]))
    }

    /// Text, author and pictures for links saved from the share sheet (and
    /// any media still missing), in the core's background worker. Refreshes
    /// the list as they come in.
    func fetchShared() {
        Task {
            _ = try? await core.run(.kickMedia)
            for _ in 0..<6 {
                try? await Task.sleep(for: .seconds(5))
                guard let r: SearchResult = try? await core.call(.search(q: "is:stub", sort: "", limit: 1, offset: 0)) else { return }
                await reload()
                if r.total == 0 { return }
            }
        }
    }

    private func takePendingQuery() {
        if let q = Self.pendingQuery {
            Self.pendingQuery = nil
            scope = .all
            query = q
        }
    }

    /// Pictures can be downloaded again; only the database belongs in
    /// the iCloud backup (Apple's storage guidelines).
    nonisolated static func keepMediaOutOfBackups(_ library: URL) {
        var media = library.appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? media.setResourceValues(values)
    }

    // MARK: Loading

    func reload() async {
        generation += 1
        let gen = generation
        isLoading = true
        defer { if gen == generation { isLoading = false } }
        do {
            let r: SearchResult = try await core.call(.search(q: effectiveQuery, sort: "", limit: pageSize, offset: 0))
            guard gen == generation else { return }
            items = r.items
            total = r.total
            reachedEnd = r.items.count < pageSize
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            if gen == generation { errorMessage = error.localizedDescription }
        }
    }

    func loadMore() async {
        guard !reachedEnd, !isLoading else { return }
        let gen = generation
        isLoading = true
        defer { isLoading = false }
        if let r: SearchResult = try? await core.call(.search(q: effectiveQuery, sort: "", limit: pageSize, offset: items.count)), gen == generation {
            let known = Set(items.map(\.id))
            items += r.items.filter { !known.contains($0.id) }
            reachedEnd = r.items.count < pageSize
        }
    }

    func queryChanged() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    func refreshMeta() async {
        if let t: [TagCount] = try? await core.call(.tags) { tags = t.sorted { $0.count > $1.count } }
        if let f: [Folder] = try? await core.call(.folders) { folders = f.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        if let s: Stats = try? await core.call(.stats) { stats = s }
    }

    /// Re-reads one item after an edit and puts it back in place.
    func refresh(_ id: String) async -> Item? {
        guard let item: Item = try? await core.call(.get(id: id)) else { return nil }
        if let i = items.firstIndex(where: { $0.id == id }) { items[i] = item }
        return item
    }

    // MARK: Editing

    @discardableResult
    func perform(_ command: CoreCommand, network: Bool = false) async -> Bool {
        do {
            try await core.run(command, network: network)
            syncSoon()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func addURL(_ url: String, tags: [String]) async -> Bool {
        do {
            let item: Item = try await core.call(.addURL(url: url, tags: tags, note: nil, folderID: nil), network: true)
            items.removeAll { $0.id == item.id }
            items.insert(item, at: 0)
            total += 1
            syncSoon()
            await refreshMeta()
            return true
        } catch {
            // No network (or the site would not answer): keep the link now,
            // fetch the rest later, like the share sheet does.
            if (try? await Self.saveLinkOnly(url, tags: tags)) != nil {
                notice = "Sayfaya ulaşılamadı; bağlantı kaydedildi, ayrıntılar sonra gelecek."
                await reload()
                syncSoon()
                return true
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Stores just the link (no network); used offline and by the share sheet.
    nonisolated static func saveLinkOnly(_ url: String, tags: [String]) async throws -> String {
        struct Saved: Decodable, Sendable { let id: String }
        let r: Saved = try await Core.shared.call(.call("save_link", ["url": .string(url), "tags": .strings(tags)]))
        return r.id
    }

    func delete(_ id: String) async {
        if await perform(.delete(id: id)) {
            Spotlight.remove([id])
            items.removeAll { $0.id == id }
            total = max(0, total - 1)
            await refreshMeta()
        }
    }
}

/// Splits "a, b/c ,d" into tag names.
func phoneTags(_ text: String) -> [String] {
    text.split(whereSeparator: { $0 == "," || $0 == "\n" })
        .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
        .filter { !$0.isEmpty }
}
