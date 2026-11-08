import AppKit
import Foundation
import Observation

/// What the sidebar points at.
enum Scope: Hashable {
    case all
    case untagged
    case platform(Platform)
    case tag(String) // tag key path
    case folder(id: Int64, name: String)
    case links(LinkCategory? = nil)
    case photos
    case videos
    /// One post at a time: ← delete, → keep.
    case triage
    /// A search kept in the sidebar.
    case saved(SavedSearch)

    public static let links: Scope = .links(nil)

    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }

    public var isLinks: Bool {
        if case .links = self { return true }
        return false
    }

    /// Filter terms this scope adds to the search box query.
    var filter: String {
        switch self {
        case .all, .links: ""
        case .triage: "-is:reviewed"
        case .untagged: "is:untagged"
        case .photos: "has:image"
        case .videos: "has:video"
        case .platform(let p): "platform:\(p.rawValue)"
        case .tag(let key): key.contains(" ") ? "tag:\"\(key)\"" : "tag:\(key)"
        // By path, so a parent folder shows its subfolders' posts too
        // (an all-digit name would read as an id; those go by id).
        case .folder(let id, let name): Int64(name) == nil && !name.isEmpty
            ? "folder:" + (name.contains(" ") ? "\"\(name)\"" : name) : "folder:\(id)"
        case .saved(let s): s.query
        }
    }
}

enum LibraryLayout: String {
    case grid, list, feed
}

/// One choice in the clean-up view, undoable while it is recent.
struct TriageDecision {
    let item: Item
    let delete: Bool
    var folder: Folder? = nil
    var previousFolderID: Int64? = nil
}

/// Media open in the in-app viewer. `fromQuote` says whether the media list
/// belongs to the owner item or to the post it quotes.
struct Viewer: Identifiable {
    let id = UUID()
    let ownerID: String
    let fromQuote: Bool
    var media: [Media]
    var index: Int
    let postURL: String
}

/// UI state. Holds a few pages of items; media is read from disk lazily by
/// the views (see `Thumbnails`).
@MainActor
@Observable
final class AppModel {
    var scope: Scope = .all {
        didSet {
            // Leaving the clean-up view makes its deletions final.
            if oldValue == .triage && scope != .triage { Task { await commitTriage() } }
            // A folder opened in the sidebar replaces the folder filter.
            if case .folder = scope, filters.folder != .any { filters.folder = .any }
        }
    }
    var query = ""
    var filters = AdvancedFilters()
    var showFilters = false
    var sort: SortOrder = SortOrder(rawValue: UserDefaults.standard.string(forKey: "sort") ?? "") ?? .relevance {
        didSet {
            UserDefaults.standard.set(sort.rawValue, forKey: "sort")
            if sort == .random { shuffleSeed = Int.random(in: 1..<1_000_000) }
        }
    }
    /// Which shuffle "Karışık" shows; a new one each time it is picked.
    private var shuffleSeed = Int.random(in: 1..<1_000_000)
    /// Recent clean-up choices, newest last. Deletions wait here (undoable)
    /// until they fall off the end, the view is left or the app quits.
    private(set) var triageHistory: [TriageDecision] = []
    private(set) var triageDeleted = 0
    private(set) var triageKept = 0
    private let triageUndoDepth = 10
    var items: [Item] = []
    var total = 0
    /// Links matching the search (items view) or the whole pool (links view).
    var links: [LinkRow] = []
    /// All links in the library, cached for sidebar category counters so they never reset to 0.
    var allLinks: [LinkRow] = [] {
        didSet { linkCounts = Self.countCategories(allLinks) }
    }
    /// Per-category link counts, worked out once per link load instead of on
    /// every sidebar redraw.
    private var linkCounts: [LinkCategory: Int] = [:]
    var tags: [TagCount] = []
    var tagTree: [TagNode] = []
    var folders: [Folder] = []
    var folderTree: [FolderNode] = []
    var theme: AppTheme = {
        if let saved = UserDefaults.standard.string(forKey: "app_theme"), let t = AppTheme(rawValue: saved) {
            return t
        }
        return .system
    }() {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: "app_theme")
        }
    }
    var stats: Stats?
    var showDetailPane: Bool = {
        UserDefaults.standard.object(forKey: "show_detail_pane") as? Bool ?? true
    }() {
        didSet {
            UserDefaults.standard.set(showDetailPane, forKey: "show_detail_pane")
        }
    }
    var selection: Set<String> = []
    /// Link pool: the selected link and the posts that contain it.
    var selectedLink: LinkRow?
    var linkItems: [Item] = []
    var errorMessage: String?
    var hasError: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }
    var selectedScope: Scope? {
        get { scope }
        set { if let newValue { scope = newValue } }
    }
    var confirmDeleteIDs: [String]?
    var hasConfirmDelete: Bool {
        get { confirmDeleteIDs != nil }
        set { if !newValue { confirmDeleteIDs = nil } }
    }
    func requestDelete(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        confirmDeleteIDs = ids
    }
    var isLoading = false
    var isBusy = false
    var showAdd = false
    var showBulkTags = false
    var showDownloads = false
    var downloads: DownloadsReport?
    var isDownloading: Bool { !(downloads?.active.isEmpty ?? true) || isFetchingVideos }
    var activeOrQueuedDownloadsCount: Int { (downloads?.active.count ?? 0) + (downloads?.queued.count ?? 0) }
    var viewer: Viewer?
    var downloadVideos = true
    /// Reads text in saved pictures so it becomes searchable. App-only:
    /// the extensions' processes are too short-lived for it.
    var ocrEnabled: Bool = UserDefaults.standard.bool(forKey: "ocr") {
        didSet {
            UserDefaults.standard.set(ocrEnabled, forKey: "ocr")
            if ocrEnabled { startOCR() }
        }
    }
    var isReadingText: Bool { ocrTask != nil }
    private var ocrTask: Task<Void, Never>?
    var layout: LibraryLayout = LibraryLayout(rawValue: UserDefaults.standard.string(forKey: "layout") ?? "") ?? .grid {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: "layout") }
    }

    // MARK: Added features (see Features.swift)

    /// Searches kept in the sidebar.
    var savedSearches: [SavedSearch] = []
    /// Folders offered for the post on screen in the clean-up view.
    var triageSuggestions: [FolderSuggestion] = []
    /// An item to select as soon as it is on screen (Spotlight, links).
    var pendingRevealID: String?
    var isCheckingLinks = false
    var linksChecked = 0
    var isBackingUp = false
    var lastBackupReport: BackupReport?
    var backupError: String?
    var backupFolder: String? = UserDefaults.standard.string(forKey: "backupFolder") {
        didSet { UserDefaults.standard.set(backupFolder, forKey: "backupFolder") }
    }
    var autoBackup: Bool = UserDefaults.standard.bool(forKey: "autoBackup") {
        didSet { UserDefaults.standard.set(autoBackup, forKey: "autoBackup") }
    }
    var lastBackupAt: Date? = UserDefaults.standard.object(forKey: "lastBackupAt") as? Date {
        didSet { UserDefaults.standard.set(lastBackupAt, forKey: "lastBackupAt") }
    }
    var spotlightEnabled: Bool = UserDefaults.standard.object(forKey: "spotlight") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(spotlightEnabled, forKey: "spotlight")
            spotlightEnabled ? Spotlight.reindex(force: true) : Spotlight.clear()
        }
    }
    /// The "name this search" prompt.
    var showSaveSearch = false
    /// Newest saves, for the menu bar.
    var recentItems: [Item] = []

    /// Most used tags first, for the filter strip.
    var topTags: [TagCount] { Array(tags.sorted { $0.count > $1.count }.prefix(30)) }

    private let pageSize = 120
    private(set) var reachedEnd = false
    private var lastDataVersion: Int64?
    private var searchTask: Task<Void, Never>?
    /// Bumped by every load; a slower, older answer is thrown away instead
    /// of overwriting a newer one.
    private var generation = 0
    /// Set when the OCR helper cannot run; the watcher waits until then.
    private var ocrPausedUntil: Date?
    /// The core returns at most this many items per call.
    private let maxPage = 500

    let core = Core.shared

    var effectiveQuery: String {
        [scope.filter, filters.terms, query.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private var sortArg: String { sort == .random ? "random:\(shuffleSeed)" : sort.rawValue }

    private func searchRequest(limit: Int, offset: Int) -> [String: Any] {
        ["cmd": "search", "q": effectiveQuery, "sort": sortArg, "limit": limit, "offset": offset]
    }

    /// Items waiting to be deleted are hidden everywhere.
    private var pendingDeleteIDs: Set<String> { Set(triageHistory.filter(\.delete).map(\.item.id)) }

    private func visible(_ items: [Item]) -> [Item] {
        let hidden = pendingDeleteIDs
        return hidden.isEmpty ? items : items.filter { !hidden.contains($0.id) }
    }

    /// Picks a new shuffle for "Karışık".
    func reshuffle() {
        shuffleSeed = Int.random(in: 1..<1_000_000)
        Task { await reload() }
    }

    /// The single selected item, if exactly one is selected.
    var selectedItem: Item? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return items.first { $0.id == id } ?? linkItems.first { $0.id == id }
    }

    func start() async {
        guard core.isOpen else {
            errorMessage = "Kütüphane açılamadı: \(core.libraryURL.path)"
            return
        }
        await HostInstaller.registerIfNeeded()
        await loadSettings()
        await loadVideoTools()
        await loadFolders()
        await loadLinks()
        await refreshDownloads()
        await reload()
        watch()
        startOCR()
        startVideoDownloads()
        await loadSavedSearches()
        startBackupSchedule()
        Spotlight.reindex()
        QuickSave.shared.attach(self)
    }

    // MARK: Loading

    func reload() async {
        await refreshMeta()
        if scope.isLinks {
            await loadLinks()
            return
        }
        isLoading = true
        defer { isLoading = false }
        generation += 1
        let gen = generation
        do {
            let r: SearchResult = try await core.call(searchRequest(limit: pageSize, offset: 0))
            guard gen == generation else { return }
            setIfChanged(\.items, visible(r.items))
            setIfChanged(\.total, r.total)
            if !r.links.isEmpty || !query.isEmpty {
                setIfChanged(\.links, r.links)
            }
            reachedEnd = r.items.count < pageSize
            let ids = Set(items.map(\.id))
            setIfChanged(\.selection, scope == .triage ? (items.first.map { [$0.id] } ?? []) : selection.filter(ids.contains))
            if let id = pendingRevealID, ids.contains(id) {
                selection = [id]
                pendingRevealID = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard !reachedEnd, !isLoading, !scope.isLinks else { return }
        isLoading = true
        defer { isLoading = false }
        let gen = generation
        do {
            let r: SearchResult = try await core.call(searchRequest(limit: pageSize, offset: items.count))
            guard gen == generation else { return }
            let known = Set(items.map(\.id))
            items += visible(r.items).filter { !known.contains($0.id) }
            reachedEnd = r.items.count < pageSize
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshMeta() async {
        if let s: Stats = try? await core.call(["cmd": "stats"]) { setIfChanged(\.stats, s) }
        if let t: [TagCount] = try? await core.call(["cmd": "tags"]), t != tags {
            tags = t
            tagTree = TagNode.tree(t)
        }
        await loadFolders()
        await refreshDownloads()
    }

    /// @Observable announces every assignment, equal or not; the watcher and
    /// the download loop re-read the same values every few seconds, which
    /// would redraw the sidebar, the tag strip and the whole grid each time.
    private func setIfChanged<T: Equatable>(_ key: ReferenceWritableKeyPath<AppModel, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    private var loadLinksTask: Task<Void, Never>?

    func loadLinks() async {
        loadLinksTask?.cancel()
        let q = query
        let task = Task {
            do {
                let fetched: [LinkRow] = try await core.call(["cmd": "links", "q": q, "limit": 1000])
                guard !Task.isCancelled else { return }
                setIfChanged(\.links, fetched)
                if q.isEmpty {
                    setIfChanged(\.allLinks, fetched)
                }
                if let sel = selectedLink, !links.contains(where: { $0.id == sel.id }) {
                    selectedLink = nil
                    linkItems = []
                }
            } catch {
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
        }
        loadLinksTask = task
        await task.value
    }

    func linkCategoryCount(_ category: LinkCategory) -> Int {
        allLinks.isEmpty ? links.filter { category.matches(host: $0.host, url: $0.url) }.count : linkCounts[category, default: 0]
    }

    private static func countCategories(_ links: [LinkRow]) -> [LinkCategory: Int] {
        var counts: [LinkCategory: Int] = [:]
        let named = LinkCategory.allCases.filter { $0 != .other }
        for link in links {
            let hit = named.first { $0.matches(host: link.host, url: link.url) } ?? .other
            counts[hit, default: 0] += 1
        }
        return counts
    }

    private var selectLinkTask: Task<Void, Never>?

    func select(link: LinkRow?) async {
        selectLinkTask?.cancel()
        selectedLink = link
        selection = []
        guard let link else {
            linkItems = []
            return
        }
        let targetID = link.id
        let task = Task {
            let items: [Item] = (try? await core.call(["cmd": "link_items", "id": targetID])) ?? []
            guard !Task.isCancelled, selectedLink?.id == targetID else { return }
            linkItems = items
        }
        selectLinkTask = task
        await task.value
    }

    /// Debounced search-as-you-type.
    func queryChanged() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    /// Re-reads everything already loaded (keeps the scroll position and
    /// the extra pages, unlike `reload`).
    func refreshLoaded() async {
        await refreshMeta()
        guard !scope.isLinks else { return }
        generation += 1
        let gen = generation
        let want = max(items.count, pageSize)
        var fresh: [Item] = []
        var first: SearchResult?
        // In pages: the core caps one call, and a long scroll holds more.
        while fresh.count < want {
            let limit = min(maxPage, want - fresh.count)
            guard let r: SearchResult = try? await core.call(searchRequest(limit: limit, offset: fresh.count)) else { return }
            if first == nil { first = r }
            fresh += r.items
            if r.items.count < limit { break }
        }
        guard gen == generation, let first else { return }
        setIfChanged(\.items, visible(fresh))
        syncViewer()
        setIfChanged(\.total, first.total)
        setIfChanged(\.links, first.links)
        reachedEnd = fresh.count >= first.total
    }

    /// Two things change the library behind the UI's back: the browser
    /// extension's host (another process — SQLite's `data_version` tells us)
    /// and the background media downloader (watched through the pending
    /// count). Both checks are microseconds and run only while frontmost.
    private func watch() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, NSApp.isActive else { continue }
                if let v: Int64 = try? await self.core.call(["cmd": "data_version"]) {
                    if let last = self.lastDataVersion, last != v {
                        await self.refreshLoaded()
                        Spotlight.indexRecent()
                    }
                    self.lastDataVersion = v
                }
                if (self.stats?.ocrPending ?? 0) > 0, self.ocrPausedUntil.map({ $0 < .now }) ?? true { self.startOCR() }
                self.startVideoDownloads()
                let pending = self.stats?.mediaPending ?? 0
                if pending > 0 {
                    try? await self.core.run(["cmd": "kick_media"])
                    await self.refreshMeta()
                    if (self.stats?.mediaPending ?? 0) != pending { await self.refreshLoaded() }
                }
            }
        }
    }

    // MARK: Editing

    func perform(_ request: [String: Any], network: Bool = false) async -> Bool {
        do {
            try await core.run(request, network: network)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Replaces the item in place so the grid does not jump.
    private func refreshItem(_ id: String) async {
        guard let fresh: Item = try? await core.call(["cmd": "get", "id": id]) else { return }
        if let i = items.firstIndex(where: { $0.id == id }) { items[i] = fresh }
        if let i = linkItems.firstIndex(where: { $0.id == id }) { linkItems[i] = fresh }
    }

    func setTags(_ id: String, _ tags: [String]) async {
        guard await perform(["cmd": "set_tags", "id": id, "tags": tags]) else { return }
        await refreshItem(id)
        await refreshMeta()
    }

    func editTags(_ ids: [String], add: [String], remove: [String]) async {
        guard await perform(["cmd": "edit_tags", "ids": ids, "add": add, "remove": remove]) else { return }
        for id in ids { await refreshItem(id) }
        await refreshMeta()
    }

    func renameTag(from: String, to: String) async {
        guard await perform(["cmd": "rename_tag", "from": from, "to": to]) else { return }
        if case .tag(let key) = scope, key == from || key.hasPrefix(from + "/") { scope = .all }
        await reload()
    }

    func setNote(_ id: String, _ note: String) async {
        guard await perform(["cmd": "set_note", "id": id, "note": note]) else { return }
        await refreshItem(id)
    }

    func delete(_ ids: [String]) async {
        for id in ids { _ = await perform(["cmd": "delete", "id": id]) }
        Spotlight.remove(ids)
        selection.subtract(ids)
        await reload()
    }

    func addURL(_ url: String, tags: [String], note: String) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            let item: Item = try await core.call(["cmd": "add_url", "url": url, "tags": tags, "note": note.isEmpty ? NSNull() : note], network: true)
            await reload()
            selection = [item.id]
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func addLink(_ url: String) async {
        guard await perform(["cmd": "add_link", "url": url]) else { return }
        await loadLinks()
    }

    func deleteLink(_ link: LinkRow) async {
        guard await perform(["cmd": "delete_link", "id": link.id]) else { return }
        await select(link: nil)
        await loadLinks()
    }

    /// Works through the OCR queue in the background, a batch at a time,
    /// each batch in a short-lived `wroopmark-ocr` process (see its source
    /// for why). Returns when the queue is empty or OCR is off.
    func startOCR() {
        guard ocrEnabled, ocrTask == nil, let helper = OCRHelper.url else { return }
        struct Pending: Decodable { let id: String; let files: [String] }
        ocrTask = Task(priority: .utility) { [weak self] in
            defer { Task { @MainActor in self?.ocrTask = nil } }
            while let self, self.ocrEnabled, !Task.isCancelled {
                guard let batch: [Pending] = try? await self.core.call(["cmd": "ocr_pending", "limit": 20]), !batch.isEmpty else { break }
                let files = batch.flatMap(\.files)
                guard let texts = await OCRHelper.run(helper, files: files), texts.count == files.count else {
                    // The helper does not start; trying every 2 s will not help.
                    self.ocrPausedUntil = .now + 600
                    break
                }
                var next = texts.makeIterator()
                for item in batch {
                    let text = item.files.compactMap { _ in next.next() }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                    try? await self.core.run(["cmd": "set_ocr", "id": item.id, "text": text])
                }
                await self.refreshMeta()
            }
        }
    }

    // MARK: Clean-up view

    var hasPendingTriage: Bool { triageHistory.contains(where: \.delete) }
    var canUndoTriage: Bool { !triageHistory.isEmpty }

    /// Decides on the post on screen (the first in the queue) and moves on.
    /// The screen changes at once (so it can animate); the library is
    /// updated right after.
    func triage(delete: Bool) {
        guard scope == .triage, let item = items.first else { return }
        items.removeFirst()
        total = max(0, total - 1)
        triageHistory.append(TriageDecision(item: item, delete: delete))
        if delete { triageDeleted += 1 } else { triageKept += 1 }
        selection = items.first.map { [$0.id] } ?? []
        let expired = triageHistory.count > triageUndoDepth ? triageHistory.removeFirst() : nil
        let refill = items.count < 15 && !reachedEnd
        Task {
            if !delete { _ = await perform(["cmd": "set_reviewed", "ids": [item.id], "reviewed": true]) }
            if let expired, expired.delete {
                _ = await perform(["cmd": "delete", "id": expired.item.id])
                Spotlight.remove([expired.item.id])
            }
            if refill { await reload() }
        }
    }

    /// Moves the post on screen to a folder in one click, marks it kept, and advances.
    func triageMoveToFolder(_ folder: Folder) {
        guard scope == .triage, let item = items.first else { return }
        items.removeFirst()
        total = max(0, total - 1)
        triageHistory.append(TriageDecision(item: item, delete: false, folder: folder, previousFolderID: item.folderId))
        triageKept += 1
        selection = items.first.map { [$0.id] } ?? []
        let expired = triageHistory.count > triageUndoDepth ? triageHistory.removeFirst() : nil
        let refill = items.count < 15 && !reachedEnd
        Task {
            _ = await perform(["cmd": "move_to_folder", "id": item.id, "folder_id": folder.id])
            _ = await perform(["cmd": "set_reviewed", "ids": [item.id], "reviewed": true])
            if let expired, expired.delete {
                _ = await perform(["cmd": "delete", "id": expired.item.id])
                Spotlight.remove([expired.item.id])
            }
            await refreshMeta()
            if refill { await reload() }
        }
    }

    /// Takes back the last decision and shows that post again.
    func undoTriage() {
        guard let last = triageHistory.popLast() else { return }
        if last.delete { triageDeleted -= 1 } else { triageKept -= 1 }
        items.insert(last.item, at: 0)
        total += 1
        selection = [last.item.id]
        if !last.delete {
            let prevFolder = last.previousFolderID
            let hadFolder = last.folder != nil
            Task {
                _ = await perform(["cmd": "set_reviewed", "ids": [last.item.id], "reviewed": false])
                if hadFolder {
                    _ = await perform(["cmd": "move_to_folder", "id": last.item.id, "folder_id": prevFolder as Any])
                    await refreshMeta()
                }
            }
        }
    }

    /// Carries out the deletions still waiting for an undo.
    func commitTriage() async {
        let pending = triageHistory.filter(\.delete)
        triageHistory = []
        for d in pending { _ = await perform(["cmd": "delete", "id": d.item.id]) }
        Spotlight.remove(pending.map(\.item.id))
        if !pending.isEmpty { await refreshMeta() }
    }

    /// Brings every kept post back into the clean-up view.
    func resetReviewed() async {
        _ = await perform(["cmd": "reset_reviewed"])
        triageKept = 0
        triageDeleted = 0
        await reload()
    }

    func filter(tag name: String) {
        let key = tags.first { $0.name == name }?.key ?? name.lowercased()
        query = ""
        scope = .tag(key)
    }

    func loadSettings() async {
        struct S: Decodable { let downloadVideos: Bool }
        if let s: S = try? await core.call(["cmd": "settings"]) { downloadVideos = s.downloadVideos }
    }

    func setDownloadVideos(_ on: Bool) async {
        downloadVideos = on
        _ = await perform(["cmd": "set_settings", "download_videos": on])
        await refreshMeta()
    }

    /// Re-queues every item whose media is missing and starts downloading.
    func retryMedia() async {
        _ = await perform(["cmd": "retry_media"])
        await refreshMeta()
    }

    /// Downloads one item's media (videos included) now.
    /// Downloads one item's media now: direct files, then videos through
    /// yt-dlp / gallery-dl (in the core). If that fails and `browserFallback`
    /// is given, the post is loaded in the browser for the extension to
    /// save. True when everything is on disk.
    @discardableResult
    func downloadMedia(_ id: String, browserFallback postURL: String? = nil) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            let fresh: Item = try await core.call(["cmd": "download_media", "id": id], network: true)
            if let i = items.firstIndex(where: { $0.id == id }) { items[i] = fresh }
            if let i = linkItems.firstIndex(where: { $0.id == id }) { linkItems[i] = fresh }
            if var v = viewer, v.ownerID == id {
                v.media = v.fromQuote ? (fresh.quote?.item.media ?? []) : fresh.media
                v.index = min(v.index, v.media.count - 1)
                viewer = v.media.isEmpty ? nil : v
            }
            await refreshMeta()
            return !fresh.needsDownload
        } catch {
            if let postURL {
                fetchViaBrowser(postURL)
            } else {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    // MARK: Outside video downloads

    /// yt-dlp / gallery-dl as found by the core; empty when none is installed.
    var videoTools: [VideoTool] = []
    var isFetchingVideos: Bool { videoTask != nil }
    private var videoTask: Task<Void, Never>?

    func loadVideoTools() async {
        videoTools = (try? await core.call(["cmd": "video_tools"])) ?? []
    }

    /// Works through the queue of videos only an outside tool can fetch, a
    /// few at a time, refreshing the screen as they arrive.
    func startVideoDownloads() {
        guard downloadVideos, videoTask == nil, !videoTools.isEmpty, (stats?.videosQueued ?? 0) > 0 else { return }
        videoTask = Task(priority: .utility) { [weak self] in
            defer { Task { @MainActor in self?.videoTask = nil } }
            while let self, self.downloadVideos, !Task.isCancelled {
                guard let n: Int = try? await self.core.call(["cmd": "download_videos", "limit": 3], network: true), n > 0 else { break }
                await self.refreshLoaded()
            }
        }
    }

    /// Loads a post in the default browser without bringing it forward, so
    /// the extension can save what only the site's own page may fetch.
    func fetchViaBrowser(_ postURL: String) {
        guard let url = URL(string: postURL) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.open(url, configuration: config)
    }

    /// Keeps an open viewer in step with a re-read item (a video arrived).
    private func syncViewer() {
        guard var v = viewer, let item = items.first(where: { $0.id == v.ownerID }) else { return }
        let media = v.fromQuote ? (item.quote?.item.media ?? []) : item.media
        guard media != v.media, !media.isEmpty else { return }
        v.media = media
        v.index = min(v.index, media.count - 1)
        viewer = v
    }

    func openViewer(owner: Item, fromQuote: Bool, index: Int) {
        let media = fromQuote ? (owner.quote?.item.media ?? []) : owner.media
        guard media.indices.contains(index) else { return }
        let url = fromQuote ? (owner.quote?.item.url ?? owner.url) : owner.url
        viewer = Viewer(ownerID: owner.id, fromQuote: fromQuote, media: media, index: index, postURL: url)
    }

    /// Fetches titles for links that have none; network-bound, in batches.
    func enrichLinks() async {
        isBusy = true
        defer { isBusy = false }
        while let n: Int = try? await core.call(["cmd": "enrich_links", "limit": 25], network: true), n > 0 {
            await loadLinks()
        }
    }

    // MARK: - Folders

    func loadFolders() async {
        guard let fetched: [Folder] = try? await core.call(["cmd": "folders"]), fetched != folders else { return }
        folders = fetched
        folderTree = FolderNode.tree(fetched)
        // A renamed or deleted folder would leave the filter matching nothing.
        if let path = filters.folder.path, !FolderNode.flattened(folderTree).contains(where: { $0.id == path }) {
            filters.folder = .any
        }
    }

    @discardableResult
    func addFolder(name: String) async -> Folder? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        guard let folder: Folder = try? await core.call(["cmd": "add_folder", "name": clean]) else { return nil }
        await loadFolders()
        return folder
    }

    @discardableResult
    func addSubfolder(parent: Folder, name: String) async -> Folder? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !clean.isEmpty else { return nil }
        let fullPath = "\(parent.name)/\(clean)"
        return await addFolder(name: fullPath)
    }

    func renameFolder(id: Int64, name: String) async {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        _ = await perform(["cmd": "rename_folder", "id": id, "name": clean])
        await loadFolders()
        if case .folder(let curId, _) = scope, curId == id {
            scope = .folder(id: id, name: clean)
        }
    }

    func deleteFolder(id: Int64) async {
        _ = await perform(["cmd": "delete_folder", "id": id])
        await loadFolders()
        if case .folder(let curId, _) = scope, curId == id {
            scope = .all
        }
        await reload()
    }

    func moveToFolder(id: String, folderID: Int64?) async {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx] = items[idx].withFolder(folderID)
        }
        var params: [String: Any] = ["cmd": "move_to_folder", "id": id]
        if let folderID {
            params["folder_id"] = folderID
        }
        _ = await perform(params)
        await refreshLoaded()
    }

    func moveItemsToFolder(ids: [String], folderID: Int64?) async {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        for i in items.indices {
            if idSet.contains(items[i].id) {
                items[i] = items[i].withFolder(folderID)
            }
        }
        var params: [String: Any] = ["cmd": "move_items_to_folder", "ids": ids]
        if let folderID {
            params["folder_id"] = folderID
        }
        _ = await perform(params)
        await refreshLoaded()
    }

    // MARK: - Downloads

    func refreshDownloads() async {
        if let rep: DownloadsReport = try? await core.call(["cmd": "downloads"]) {
            setIfChanged(\.downloads, rep)
        }
    }

    func retryDownload(id: String) async {
        _ = await perform(["cmd": "retry_download", "id": id])
        startVideoDownloads()
        await refreshDownloads()
        await refreshMeta()
    }

    func retryAllDownloads() async {
        _ = await perform(["cmd": "retry_all_downloads"])
        startVideoDownloads()
        await refreshDownloads()
        await refreshMeta()
    }

    func openInFinder(fileName: String) {
        let url = core.mediaURL(fileName)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Runs the `wroopmark-ocr` helper shipped in Contents/Helpers.
enum OCRHelper {
    static var url: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/wroopmark-ocr")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Longest a single image may take. Vision occasionally deadlocks inside
    /// its text recognizer; that file is skipped instead of stalling the whole queue.
    static let perFileTimeoutSeconds: Double = 45

    /// One recognized text per file, in order ("" for files skipped after a
    /// stall); nil only if the helper cannot start at all.
    static func run(_ helper: URL, files: [String]) async -> [String]? {
        await Task.detached(priority: .utility) { () -> [String]? in
            var results: [String] = []
            var remaining = files[...]
            while !remaining.isEmpty {
                guard let got = await runOnce(helper, files: Array(remaining)) else { return nil }
                results += got
                remaining = remaining.dropFirst(got.count)
                // The helper stopped short: it hung (or crashed) on the next
                // file. Skip that one and continue in a fresh process.
                if !remaining.isEmpty {
                    results.append("")
                    remaining = remaining.dropFirst()
                }
            }
            return results
        }.value
    }

    private static func runOnce(_ helper: URL, files: [String]) async -> [String]? {
        let p = Process()
        p.executableURL = helper
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice

        do { try p.run() } catch { return nil }
        if let data = (files.joined(separator: "\n") + "\n").data(using: .utf8) {
            try? input.fileHandleForWriting.write(contentsOf: data)
        }
        try? input.fileHandleForWriting.close()

        let timeoutSeconds = min(perFileTimeoutSeconds * Double(files.count), 300.0)

        // Lines read so far; on a stall the reader is abandoned and these
        // are what the helper managed, so the caller skips just the file it
        // hung on instead of treating the whole helper as broken.
        let box = LineBox()
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    for try await line in output.fileHandleForReading.bytes.lines {
                        let parsed = (try? JSONSerialization.jsonObject(with: Data(line.utf8), options: [.fragmentsAllowed]) as? String) ?? ""
                        if box.append(parsed) >= files.count { break }
                    }
                } catch {}
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                return false
            }
            _ = await group.next()
            if p.isRunning { p.terminate() }
            group.cancelAll()
        }
        return box.lines
    }
}

/// Lines from the OCR helper, shared between its reader and the timeout.
private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    /// Adds one and returns how many there are now.
    func append(_ line: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        stored.append(line)
        return stored.count
    }

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

/// Splits "a, b/c ,d" into tag names.
func parseTags(_ text: String) -> [String] {
    text.split(whereSeparator: { $0 == "," || $0 == "\n" })
        .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
        .filter { !$0.isEmpty }
}
