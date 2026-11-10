import AppKit
import Foundation
import Observation
import Synchronization

/// What the sidebar points at.
enum Scope: Hashable, Sendable {
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

    static let links: Scope = .links(nil)

    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }

    var isLinks: Bool {
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

enum LibraryLayout: String, Sendable {
    case grid, list, feed
}

/// One choice in the clean-up view, undoable while it is recent.
struct TriageDecision: Sendable {
    let item: Item
    let delete: Bool
    var folder: Folder? = nil
    var previousFolderID: Int64? = nil
}

/// Media open in the in-app viewer. `fromQuote` says whether the media list
/// belongs to the owner item or to the post it quotes.
struct Viewer: Identifiable, Sendable {
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
            if oldValue == .triage && scope != .triage {
                enqueueTriage { await self.commitTriage() }
            }
            // Release link pool memory once the user leaves Link Pool.
            if oldValue.isLinks && !scope.isLinks {
                clearLinksState()
            }
            // A folder opened in the sidebar replaces the folder filter.
            if case .folder = scope, filters.folder != .any { filters.folder = .any }
        }
    }

    var query = ""
    var filters = AdvancedFilters()
    var showFilters = false
    var sort: SortOrder {
        didSet {
            defaults.set(sort.rawValue, forKey: "sort")
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

    /// Paginated, server-filtered links for the Link Pool view.
    var links: [LinkRow] = []
    var linkCounts = LinkCounts.empty
    var linksTotal = 0
    var linksDeadTotal = 0
    var onlyDeadLinks = false
    private(set) var reachedLinksEnd = false
    private(set) var isLoadingLinks = false

    var tags: [TagCount] = []
    var tagTree: [TagNode] = []
    var folders: [Folder] = []
    var folderTree: [FolderNode] = []
    var stats: Stats?
    var showDetailPane: Bool {
        didSet { defaults.set(showDetailPane, forKey: "show_detail_pane") }
    }
    var selection: Set<String> = []
    /// Link pool: the selected link and the posts that contain it.
    var selectedLink: LinkRow?
    var linkItems: [Item] = []
    private let linkItemsPageSize = 60
    private(set) var reachedLinkItemsEnd = false
    private(set) var isLoadingLinkItems = false

    var errorMessage: String?
    var hasError: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }
    var gridError: String?
    var linksError: String?
    var linkItemsError: String?
    var downloadsError: String?
    var metaError: String?

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
    var ocrEnabled: Bool {
        didSet {
            defaults.set(ocrEnabled, forKey: "ocr")
            if ocrEnabled {
                startOCR()
            } else {
                ocrTask?.cancel()
                ocrTask = nil
            }
        }
    }
    var isReadingText: Bool { ocrTask != nil }
    private var ocrTask: Task<Void, Never>?
    var layout: LibraryLayout {
        didSet { defaults.set(layout.rawValue, forKey: "layout") }
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
    var backupFolder: String? {
        didSet { defaults.set(backupFolder, forKey: "backupFolder") }
    }
    var autoBackup: Bool {
        didSet { defaults.set(autoBackup, forKey: "autoBackup") }
    }
    var lastBackupAt: Date? {
        didSet { defaults.set(lastBackupAt, forKey: "lastBackupAt") }
    }
    var spotlightEnabled: Bool {
        didSet {
            defaults.set(spotlightEnabled, forKey: "spotlight")
            if enableSystemIntegrations {
                spotlightEnabled ? Spotlight.reindex(force: true, core: core) : Spotlight.clear()
            }
        }
    }
    /// The "name this search" prompt.
    var showSaveSearch = false
    /// Newest saves, for the menu bar.
    var recentItems: [Item] = []

    /// Most used tags first, for the filter strip.
    var topTags: [TagCount] { Array(tags.sorted { $0.count > $1.count }.prefix(30)) }

    private let pageSize = 120
    private let linksPageSize = 100
    private(set) var reachedEnd = false
    private var hasLoadedMeta = false
    private var lastDataVersion: Int64?

    private var reloadTask: Task<Void, Never>?
    private var loadMoreTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var loadLinksTask: Task<Void, Never>?
    private var loadMoreLinksTask: Task<Void, Never>?
    private var selectLinkTask: Task<Void, Never>?
    private var loadMoreLinkItemsTask: Task<Void, Never>?
    var triageSuggestionsTask: Task<Void, Never>?
    private var triageTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    var linkCheckTask: Task<Void, Never>?
    var backupScheduleTask: Task<Void, Never>?

    /// Bumped by every load; a slower, older answer is thrown away instead
    /// of overwriting a newer one.
    private var generation = 0
    private var linkGeneration = 0
    /// Set when the OCR helper cannot run; the watcher waits until then.
    private var ocrPausedUntil: Date?
    /// The core returns at most this many items per call.
    private let maxPage = 500

    let core: any CoreClient
    private let defaults: UserDefaults
    let enableSystemIntegrations: Bool

    init(
        core: any CoreClient = Core.shared,
        defaults: UserDefaults = .standard,
        enableSystemIntegrations: Bool = true
    ) {
        self.core = core
        self.defaults = defaults
        self.enableSystemIntegrations = enableSystemIntegrations
        self.sort = SortOrder(rawValue: defaults.string(forKey: "sort") ?? "") ?? .relevance
        self.showDetailPane = defaults.object(forKey: "show_detail_pane") as? Bool ?? true
        self.ocrEnabled = defaults.bool(forKey: "ocr")
        self.layout = LibraryLayout(rawValue: defaults.string(forKey: "layout") ?? "") ?? .grid
        self.backupFolder = defaults.string(forKey: "backupFolder")
        self.autoBackup = defaults.bool(forKey: "autoBackup")
        self.lastBackupAt = defaults.object(forKey: "lastBackupAt") as? Date
        self.spotlightEnabled = defaults.object(forKey: "spotlight") as? Bool ?? true
    }

    isolated deinit {
        cancelTransientTasks()
    }

    var effectiveQuery: String {
        [scope.filter, filters.terms, query.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private var sortArg: String { sort == .random ? "random:\(shuffleSeed)" : sort.rawValue }

    private var currentLinkCategory: LinkCategory? {
        if case .links(let cat) = scope { return cat }
        return nil
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
        guard await core.ensureOpen() else {
            errorMessage = "Kütüphane açılamadı: \(core.libraryURL.path)"
            return
        }
        if enableSystemIntegrations {
            await HostInstaller.registerIfNeeded()
        }
        await loadSettings()
        await loadVideoTools()
        await reload()
        await loadSavedSearches()
        watch()
        startOCR()
        startVideoDownloads()
        startBackupSchedule()
        if enableSystemIntegrations {
            Spotlight.reindex(core: core)
            QuickSave.shared.attach(self)
        }
    }

    /// Cancels watcher/background tasks before quitting or tearing down tests.
    func stopBackgroundWork() {
        cancelTransientTasks()
        linkCheckTask?.cancel()
        linkCheckTask = nil
        isCheckingLinks = false
    }

    private func cancelTransientTasks() {
        reloadTask?.cancel()
        loadMoreTask?.cancel()
        searchTask?.cancel()
        loadLinksTask?.cancel()
        loadMoreLinksTask?.cancel()
        selectLinkTask?.cancel()
        loadMoreLinkItemsTask?.cancel()
        triageSuggestionsTask?.cancel()
        watchTask?.cancel()
        ocrTask?.cancel()
        videoTask?.cancel()
        backupScheduleTask?.cancel()
    }

    // MARK: Loading

    func reload() async {
        searchTask?.cancel()
        searchTask = nil
        loadMoreTask?.cancel()
        loadMoreTask = nil
        reloadTask?.cancel()
        generation += 1
        let gen = generation
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performReload(generation: gen)
        }
        reloadTask = task
        await task.value
    }

    private func performReload(generation gen: Int) async {
        if scope.isLinks {
            await loadLinks(reset: true)
            await refreshMeta()
            return
        }

        isLoading = true
        gridError = nil
        defer {
            if gen == generation {
                isLoading = false
            }
        }

        do {
            async let metaTask: Void = refreshMeta()
            let r: SearchResult = try await core.call(.search(q: effectiveQuery, sort: sortArg, limit: pageSize, offset: 0))
            _ = await metaTask
            guard gen == generation, !Task.isCancelled else { return }
            setIfChanged(\.items, visible(r.items))
            setIfChanged(\.total, r.total)
            reachedEnd = r.items.count < pageSize
            let ids = Set(items.map(\.id))
            setIfChanged(\.selection, scope == .triage ? (items.first.map { [$0.id] } ?? []) : selection.filter(ids.contains))
            if let id = pendingRevealID, ids.contains(id) {
                selection = [id]
                pendingRevealID = nil
            }
        } catch is CancellationError {
            return
        } catch {
            if gen == generation, !Task.isCancelled {
                gridError = error.localizedDescription
            }
        }
    }

    func loadMore() async {
        guard !reachedEnd, !isLoading, loadMoreTask == nil, !scope.isLinks else { return }
        let gen = generation
        let offset = items.count
        let q = effectiveQuery
        let sortArg = sortArg
        isLoading = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if gen == self.generation {
                    self.isLoading = false
                }
                self.loadMoreTask = nil
            }
            do {
                let r: SearchResult = try await self.core.call(.search(q: q, sort: sortArg, limit: self.pageSize, offset: offset))
                guard gen == self.generation, !Task.isCancelled else { return }
                let known = Set(self.items.map(\.id))
                self.items += self.visible(r.items).filter { !known.contains($0.id) }
                self.reachedEnd = r.items.count < self.pageSize
            } catch is CancellationError {
                return
            } catch {
                if gen == self.generation, !Task.isCancelled {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
        loadMoreTask = task
        await task.value
    }

    func refreshMeta(force: Bool = false) async {
        do {
            let s: Stats = try await core.call(.stats)
            guard !Task.isCancelled else { return }
            let previous = stats
            // Download progress changes mediaBytes/mediaPending every tick;
            // that must not re-fetch the whole tag/folder/link metadata.
            let metaChanged = force || !hasLoadedMeta
                || s.items != previous?.items
                || s.tags != previous?.tags
                || s.links != previous?.links
                || s.byPlatform != previous?.byPlatform
            setIfChanged(\.stats, s)

            if metaChanged {
                async let fetchedTags: [TagCount] = core.call(.tags)
                async let fetchedFolders: [Folder] = core.call(.folders)
                async let fetchedCounts: LinkCounts = core.call(.linkCounts)
                let (t, f, lc) = try await (fetchedTags, fetchedFolders, fetchedCounts)
                guard !Task.isCancelled else { return }
                hasLoadedMeta = true
                if t != tags {
                    tags = t
                    tagTree = TagNode.tree(t)
                }
                if f != folders {
                    folders = f
                    folderTree = FolderNode.tree(f)
                    // A renamed or deleted folder would leave the filter matching nothing.
                    if let path = filters.folder.path, !FolderNode.flattened(folderTree).contains(where: { $0.id == path }) {
                        filters.folder = .any
                    }
                }
                setIfChanged(\.linkCounts, lc)
            }

            if force || showDownloads || isFetchingVideos || activeOrQueuedDownloadsCount > 0 || (s.videosQueued ?? 0) > 0 {
                await refreshDownloads()
            }
            metaError = nil
        } catch is CancellationError {
            return
        } catch {
            metaError = error.localizedDescription
        }
    }

    /// @Observable announces every assignment, equal or not; the watcher and
    /// the download loop re-read the same values every few seconds, which
    /// would redraw the sidebar, the tag strip and the whole grid each time.
    private func setIfChanged<T: Equatable>(_ key: ReferenceWritableKeyPath<AppModel, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    private func clearLinksState() {
        loadLinksTask?.cancel()
        loadLinksTask = nil
        loadMoreLinksTask?.cancel()
        loadMoreLinksTask = nil
        selectLinkTask?.cancel()
        selectLinkTask = nil
        loadMoreLinkItemsTask?.cancel()
        loadMoreLinkItemsTask = nil
        links = []
        linksTotal = 0
        linksDeadTotal = 0
        reachedLinksEnd = false
        isLoadingLinks = false
        selectedLink = nil
        linkItems = []
        reachedLinkItemsEnd = false
        isLoadingLinkItems = false
        linksError = nil
        linkItemsError = nil
    }

    func loadLinks(onlyDead: Bool? = nil, reset: Bool = true) async {
        if let onlyDead { onlyDeadLinks = onlyDead }
        loadMoreLinksTask?.cancel()
        loadMoreLinksTask = nil
        loadLinksTask?.cancel()

        linkGeneration += 1
        let gen = linkGeneration
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let cat = currentLinkCategory?.apiKey
        let dead = onlyDeadLinks
        let limit = reset ? linksPageSize : max(links.count, linksPageSize)

        isLoadingLinks = true
        linksError = nil

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if gen == self.linkGeneration {
                    self.isLoadingLinks = false
                }
            }
            do {
                let page: LinksPage = try await self.core.call(
                    .linksPage(q: q, category: cat, onlyDead: dead, limit: min(limit, 200), offset: 0)
                )
                guard gen == self.linkGeneration, !Task.isCancelled else { return }
                self.setIfChanged(\.links, page.links)
                self.setIfChanged(\.linksTotal, page.total)
                self.setIfChanged(\.linksDeadTotal, page.deadTotal)
                self.setIfChanged(\.linkCounts, page.counts)
                self.reachedLinksEnd = self.links.count >= page.total || page.links.isEmpty
                if let sel = self.selectedLink {
                    if let updated = self.links.first(where: { $0.id == sel.id }) {
                        self.selectedLink = updated
                    } else {
                        self.selectedLink = nil
                        self.linkItems = []
                        self.linkItemsError = nil
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                if gen == self.linkGeneration, !Task.isCancelled {
                    self.linksError = error.localizedDescription
                }
            }
        }
        loadLinksTask = task
        await task.value
    }

    func loadMoreLinks() async {
        guard scope.isLinks, !reachedLinksEnd, !isLoadingLinks, loadMoreLinksTask == nil else { return }
        let gen = linkGeneration
        let offset = links.count
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let cat = currentLinkCategory?.apiKey
        let dead = onlyDeadLinks
        isLoadingLinks = true

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if gen == self.linkGeneration {
                    self.isLoadingLinks = false
                }
                self.loadMoreLinksTask = nil
            }
            do {
                let page: LinksPage = try await self.core.call(
                    .linksPage(q: q, category: cat, onlyDead: dead, limit: self.linksPageSize, offset: offset)
                )
                guard gen == self.linkGeneration, !Task.isCancelled else { return }
                let known = Set(self.links.map(\.id))
                self.links += page.links.filter { !known.contains($0.id) }
                self.setIfChanged(\.linksTotal, page.total)
                self.setIfChanged(\.linksDeadTotal, page.deadTotal)
                self.setIfChanged(\.linkCounts, page.counts)
                self.reachedLinksEnd = self.links.count >= page.total || page.links.isEmpty
            } catch is CancellationError {
                return
            } catch {
                if gen == self.linkGeneration, !Task.isCancelled {
                    self.linksError = error.localizedDescription
                }
            }
        }
        loadMoreLinksTask = task
        await task.value
    }

    func linkCategoryCount(_ category: LinkCategory) -> Int {
        linkCounts.count(for: category)
    }

    func select(link: LinkRow?) async {
        selectLinkTask?.cancel()
        loadMoreLinkItemsTask?.cancel()
        loadMoreLinkItemsTask = nil
        selectedLink = link
        selection = []
        linkItems = []
        linkItemsError = nil
        reachedLinkItemsEnd = false
        guard let link else { return }
        let targetID = link.id
        isLoadingLinkItems = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.isLoadingLinkItems = false }
            do {
                let items: [Item] = try await self.core.call(
                    .linkItems(id: targetID, limit: self.linkItemsPageSize, offset: 0)
                )
                guard !Task.isCancelled, self.selectedLink?.id == targetID else { return }
                self.linkItems = items
                self.reachedLinkItemsEnd = items.count < self.linkItemsPageSize
                self.linkItemsError = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.selectedLink?.id == targetID else { return }
                self.linkItemsError = error.localizedDescription
            }
        }
        selectLinkTask = task
        await task.value
    }

    /// Next page of posts that mention the selected link.
    func loadMoreLinkItems() async {
        guard let link = selectedLink, !reachedLinkItemsEnd, !isLoadingLinkItems,
              loadMoreLinkItemsTask == nil else { return }
        let targetID = link.id
        let offset = linkItems.count
        isLoadingLinkItems = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isLoadingLinkItems = false
                self.loadMoreLinkItemsTask = nil
            }
            do {
                let page: [Item] = try await self.core.call(
                    .linkItems(id: targetID, limit: self.linkItemsPageSize, offset: offset)
                )
                guard !Task.isCancelled, self.selectedLink?.id == targetID else { return }
                let known = Set(self.linkItems.map(\.id))
                self.linkItems += page.filter { !known.contains($0.id) }
                self.reachedLinkItemsEnd = page.count < self.linkItemsPageSize
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.selectedLink?.id == targetID else { return }
                self.linkItemsError = error.localizedDescription
            }
        }
        loadMoreLinkItemsTask = task
        await task.value
    }

    /// Debounced search-as-you-type.
    func queryChanged() {
        searchTask?.cancel()
        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(160))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            searchTask = nil
            await reload()
        }
    }

    /// Re-reads everything already loaded (keeps the scroll position and
    /// the extra pages, unlike `reload`).
    func refreshLoaded() async {
        await refreshMeta()
        if scope.isLinks {
            await loadLinks(reset: false)
            return
        }
        generation += 1
        let gen = generation
        let want = max(items.count, pageSize)
        var fresh: [Item] = []
        var first: SearchResult?
        do {
            // In pages: the core caps one call, and a long scroll holds more.
            while fresh.count < want {
                guard gen == generation, !Task.isCancelled else { return }
                let limit = min(maxPage, want - fresh.count)
                let r: SearchResult = try await core.call(.search(q: effectiveQuery, sort: sortArg, limit: limit, offset: fresh.count))
                if first == nil { first = r }
                fresh += r.items
                if r.items.count < limit { break }
            }
            guard gen == generation, !Task.isCancelled, let first else { return }
            setIfChanged(\.items, visible(fresh))
            syncViewer()
            setIfChanged(\.total, first.total)
            reachedEnd = fresh.count >= first.total
            gridError = nil
        } catch is CancellationError {
            return
        } catch {
            if gen == generation, !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Two things change the library behind the UI's back: the browser
    /// extension's host (another process — SQLite's `data_version` tells us)
    /// and the background media downloader (watched through the pending
    /// count). Both checks are microseconds and run only while frontmost.
    private func watch() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let interval: Int = NSApp.isActive ? 2 : 10
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                if self.enableSystemIntegrations && !NSApp.isActive { continue }
                do {
                    let v: Int64 = try await self.core.call(.dataVersion)
                    if let last = self.lastDataVersion, last != v {
                        await self.refreshLoaded()
                        await self.refreshMeta(force: true)
                        if self.enableSystemIntegrations {
                            Spotlight.indexRecent(core: self.core)
                        }
                    }
                    self.lastDataVersion = v
                } catch is CancellationError {
                    return
                } catch {
                    self.metaError = error.localizedDescription
                }

                if (self.stats?.ocrPending ?? 0) > 0, self.ocrPausedUntil.map({ $0 < .now }) ?? true {
                    self.startOCR()
                }
                self.startVideoDownloads()
                let pending = self.stats?.mediaPending ?? 0
                if pending > 0 {
                    do {
                        try await self.core.run(.kickMedia)
                        let nextStats: Stats = try await self.core.call(.stats)
                        let pendingChanged = nextStats.mediaPending != pending
                        self.setIfChanged(\.stats, nextStats)
                        if pendingChanged {
                            await self.refreshLoaded()
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        self.metaError = error.localizedDescription
                    }
                }
            }
        }
    }

    // MARK: Editing

    @discardableResult
    func perform(_ command: CoreCommand, network: Bool = false) async -> Bool {
        do {
            try await core.run(command, network: network)
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Replaces the item in place so the grid does not jump.
    private func refreshItem(_ id: String) async {
        do {
            let fresh: Item = try await core.call(.get(id: id))
            if let i = items.firstIndex(where: { $0.id == id }) { items[i] = fresh }
            if let i = linkItems.firstIndex(where: { $0.id == id }) { linkItems[i] = fresh }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setTags(_ id: String, _ tags: [String]) async {
        guard await perform(.setTags(id: id, tags: tags)) else { return }
        await refreshItem(id)
        await refreshMeta(force: true)
    }

    func editTags(_ ids: [String], add: [String], remove: [String]) async {
        guard await perform(.editTags(ids: ids, add: add, remove: remove)) else { return }
        for id in ids { await refreshItem(id) }
        await refreshMeta(force: true)
    }

    func renameTag(from: String, to: String) async {
        guard await perform(.renameTag(from: from, to: to)) else { return }
        if case .tag(let key) = scope, key == from || key.hasPrefix(from + "/") { scope = .all }
        await reload()
    }

    func setNote(_ id: String, _ note: String) async {
        guard await perform(.setNote(id: id, note: note)) else { return }
        await refreshItem(id)
    }

    func delete(_ ids: [String]) async {
        for id in ids { _ = await perform(.delete(id: id)) }
        if enableSystemIntegrations { Spotlight.remove(ids) }
        selection.subtract(ids)
        await reload()
    }

    func addURL(_ url: String, tags: [String], note: String) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            let item: Item = try await core.call(.addURL(url: url, tags: tags, note: note.isEmpty ? nil : note, folderID: nil), network: true)
            await reload()
            selection = [item.id]
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Saves multiple dropped/shared URLs in one batch before reloading once.
    func addURLs(_ urls: [String]) async {
        let clean = urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }

        var lastAddedID: String?
        var failures: [String] = []
        for url in clean {
            guard !Task.isCancelled else { break }
            do {
                let item: Item = try await core.call(.addURL(url: url, tags: [], note: nil, folderID: nil), network: true)
                lastAddedID = item.id
            } catch is CancellationError {
                break
            } catch {
                failures.append("\(url): \(error.localizedDescription)")
            }
        }
        await reload()
        if let lastAddedID, items.contains(where: { $0.id == lastAddedID }) {
            selection = [lastAddedID]
        }
        if !failures.isEmpty {
            errorMessage = failures.joined(separator: "\n")
        }
    }

    func addLink(_ url: String) async {
        guard !url.isEmpty, await perform(.addLink(url: url)) else { return }
        await loadLinks(reset: true)
    }

    func deleteLink(_ link: LinkRow) async {
        guard await perform(.deleteLink(id: link.id)) else { return }
        await select(link: nil)
        await loadLinks(reset: true)
    }

    /// Works through the OCR queue in the background, a batch at a time,
    /// each batch in a short-lived `wroopmark-ocr` process (see its source
    /// for why). Returns when the queue is empty or OCR is off.
    func startOCR() {
        guard ocrEnabled, ocrTask == nil else { return }
        struct Pending: Decodable, Sendable { let id: String; let files: [String] }
        ocrTask = Task(priority: .utility) { [weak self] in
            defer { self?.ocrTask = nil }
            guard let helper = await OCRHelper.executableURL() else { return }
            while let self, self.ocrEnabled, !Task.isCancelled {
                let batch: [Pending]
                do {
                    batch = try await self.core.call(.ocrPending(limit: 20))
                } catch is CancellationError {
                    break
                } catch {
                    self.metaError = error.localizedDescription
                    break
                }
                guard !batch.isEmpty else { break }
                let files = batch.flatMap(\.files)
                guard let texts = await OCRHelper.run(helper, files: files), texts.count == files.count else {
                    // The helper does not start or batch stalled completely; try again later.
                    self.ocrPausedUntil = .now + 600
                    break
                }
                var next = texts.makeIterator()
                for item in batch {
                    guard !Task.isCancelled else { break }
                    let text = item.files.compactMap { _ in next.next() }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                    _ = await self.perform(.setOCR(id: item.id, text: text))
                }
                await self.refreshMeta()
            }
        }
    }

    // MARK: Clean-up view

    var hasPendingTriage: Bool { triageHistory.contains(where: \.delete) }
    var canUndoTriage: Bool { !triageHistory.isEmpty }

    private func enqueueTriage(_ operation: @escaping @MainActor () async -> Void) {
        let prev = triageTask
        triageTask = Task { @MainActor in
            await prev?.value
            await operation()
        }
    }

    /// Waits for any queued clean-up writes to settle (used before closing the DB).
    func waitForPendingTriage() async {
        await triageTask?.value
    }

    /// Decides on the post on screen (the first in the queue) and moves on.
    /// The screen changes at once (so it can animate); the library writes
    /// execute serially in exact decision order.
    func triage(delete: Bool) {
        guard scope == .triage, let item = items.first else { return }
        items.removeFirst()
        total = max(0, total - 1)
        triageHistory.append(TriageDecision(item: item, delete: delete))
        if delete { triageDeleted += 1 } else { triageKept += 1 }
        selection = items.first.map { [$0.id] } ?? []
        let expired = triageHistory.count > triageUndoDepth ? triageHistory.removeFirst() : nil
        let refill = items.count < 15 && !reachedEnd
        enqueueTriage {
            if !delete { _ = await self.perform(.setReviewed(ids: [item.id], reviewed: true)) }
            if let expired, expired.delete {
                _ = await self.perform(.delete(id: expired.item.id))
                if self.enableSystemIntegrations { Spotlight.remove([expired.item.id]) }
            }
            if refill { await self.reload() }
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
        enqueueTriage {
            _ = await self.perform(.moveToFolder(id: item.id, folderID: folder.id))
            _ = await self.perform(.setReviewed(ids: [item.id], reviewed: true))
            if let expired, expired.delete {
                _ = await self.perform(.delete(id: expired.item.id))
                if self.enableSystemIntegrations { Spotlight.remove([expired.item.id]) }
            }
            await self.refreshMeta(force: true)
            if refill { await self.reload() }
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
            enqueueTriage {
                _ = await self.perform(.setReviewed(ids: [last.item.id], reviewed: false))
                if hadFolder {
                    _ = await self.perform(.moveToFolder(id: last.item.id, folderID: prevFolder))
                    await self.refreshMeta(force: true)
                }
            }
        }
    }

    /// Carries out the deletions still waiting for an undo.
    func commitTriage() async {
        await triageTask?.value
        let pending = triageHistory.filter(\.delete)
        triageHistory = []
        for d in pending { _ = await perform(.delete(id: d.item.id)) }
        if enableSystemIntegrations { Spotlight.remove(pending.map(\.item.id)) }
        if !pending.isEmpty { await refreshMeta(force: true) }
    }

    /// Brings every kept post back into the clean-up view.
    func resetReviewed() async {
        guard await perform(.resetReviewed) else { return }
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
        struct SettingsResp: Decodable, Sendable { let downloadVideos: Bool }
        do {
            let s: SettingsResp = try await core.call(.settings)
            downloadVideos = s.downloadVideos
        } catch is CancellationError {
            return
        } catch {
            metaError = error.localizedDescription
        }
    }

    func setDownloadVideos(_ on: Bool) async {
        downloadVideos = on
        _ = await perform(.setSettings(downloadVideos: on))
        await refreshMeta(force: true)
    }

    /// Re-queues every item whose media is missing and starts downloading.
    func retryMedia() async {
        _ = await perform(.retryMedia)
        await refreshMeta(force: true)
    }

    /// Downloads one item's media (videos included) now.
    @discardableResult
    func downloadMedia(_ id: String, browserFallback postURL: String? = nil) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            let fresh: Item = try await core.call(.downloadMedia(id: id), network: true)
            if let i = items.firstIndex(where: { $0.id == id }) { items[i] = fresh }
            if let i = linkItems.firstIndex(where: { $0.id == id }) { linkItems[i] = fresh }
            if var v = viewer, v.ownerID == id {
                v.media = v.fromQuote ? (fresh.quote?.item.media ?? []) : fresh.media
                if v.media.isEmpty {
                    viewer = nil
                } else {
                    v.index = min(v.index, v.media.count - 1)
                    viewer = v
                }
            }
            await refreshMeta(force: true)
            return !fresh.needsDownload
        } catch is CancellationError {
            return false
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
        do {
            videoTools = try await core.call(.videoTools)
        } catch is CancellationError {
            return
        } catch {
            videoTools = []
            metaError = error.localizedDescription
        }
    }

    /// Works through the queue of videos only an outside tool can fetch, a
    /// few at a time, refreshing the screen as they arrive.
    func startVideoDownloads() {
        guard downloadVideos, videoTask == nil, !videoTools.isEmpty, (stats?.videosQueued ?? 0) > 0 else { return }
        videoTask = Task(priority: .utility) { [weak self] in
            defer { self?.videoTask = nil }
            while let self, self.downloadVideos, !Task.isCancelled {
                do {
                    let n: Int = try await self.core.call(.downloadVideos(limit: 3), network: true)
                    guard n > 0 else { break }
                    await self.refreshLoaded()
                } catch is CancellationError {
                    break
                } catch {
                    self.metaError = error.localizedDescription
                    break
                }
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
        do {
            while !Task.isCancelled {
                let n: Int = try await core.call(.enrichLinks(limit: 25), network: true)
                guard n > 0 else { break }
                await loadLinks(reset: false)
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Folders

    func loadFolders() async {
        do {
            let fetched: [Folder] = try await core.call(.folders)
            guard fetched != folders else { return }
            folders = fetched
            folderTree = FolderNode.tree(fetched)
            // A renamed or deleted folder would leave the filter matching nothing.
            if let path = filters.folder.path, !FolderNode.flattened(folderTree).contains(where: { $0.id == path }) {
                filters.folder = .any
            }
        } catch is CancellationError {
            return
        } catch {
            metaError = error.localizedDescription
        }
    }

    @discardableResult
    func addFolder(name: String) async -> Folder? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        do {
            let folder: Folder = try await core.call(.addFolder(name: clean))
            await loadFolders()
            return folder
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func addSubfolder(parent: Folder, name: String) async -> Folder? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !clean.isEmpty else { return nil }
        return await addFolder(name: "\(parent.name)/\(clean)")
    }

    func renameFolder(id: Int64, name: String) async {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        guard await perform(.renameFolder(id: id, name: clean)) else { return }
        await loadFolders()
        if case .folder(let curId, _) = scope, curId == id {
            scope = .folder(id: id, name: clean)
        }
    }

    func deleteFolder(id: Int64) async {
        guard await perform(.deleteFolder(id: id)) else { return }
        await loadFolders()
        if case .folder(let curId, _) = scope, curId == id {
            scope = .all
        } else {
            await reload()
        }
    }

    func moveToFolder(id: String, folderID: Int64?) async {
        let previousItems = items
        let previousLinkItems = linkItems
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx] = items[idx].withFolder(folderID)
        }
        if let idx = linkItems.firstIndex(where: { $0.id == id }) {
            linkItems[idx] = linkItems[idx].withFolder(folderID)
        }

        guard await perform(.moveToFolder(id: id, folderID: folderID)) else {
            items = previousItems
            linkItems = previousLinkItems
            return
        }

        await refreshMeta(force: true)
        if scope.isFolder || filters.folder != .any {
            await refreshLoaded()
        }
    }

    func moveItemsToFolder(ids: [String], folderID: Int64?) async {
        guard !ids.isEmpty else { return }
        let previousItems = items
        let previousLinkItems = linkItems
        let idSet = Set(ids)
        for i in items.indices where idSet.contains(items[i].id) {
            items[i] = items[i].withFolder(folderID)
        }
        for i in linkItems.indices where idSet.contains(linkItems[i].id) {
            linkItems[i] = linkItems[i].withFolder(folderID)
        }

        guard await perform(.moveItemsToFolder(ids: ids, folderID: folderID)) else {
            items = previousItems
            linkItems = previousLinkItems
            return
        }

        await refreshMeta(force: true)
        if scope.isFolder || filters.folder != .any {
            await refreshLoaded()
        }
    }

    // MARK: - Downloads

    func refreshDownloads() async {
        do {
            let rep: DownloadsReport = try await core.call(.downloads)
            setIfChanged(\.downloads, rep)
            downloadsError = nil
        } catch is CancellationError {
            return
        } catch {
            downloadsError = error.localizedDescription
        }
    }

    func retryDownload(id: String) async {
        guard await perform(.retryDownload(id: id)) else { return }
        startVideoDownloads()
        await refreshDownloads()
        await refreshMeta(force: true)
    }

    func retryAllDownloads() async {
        guard await perform(.retryAllDownloads) else { return }
        startVideoDownloads()
        await refreshDownloads()
        await refreshMeta(force: true)
    }

    func openInFinder(fileName: String) {
        let url = core.mediaURL(fileName)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Runs the `wroopmark-ocr` helper shipped in Contents/Helpers.
enum OCRHelper {
    /// Checks helper executable availability off the main thread.
    static func executableURL() async -> URL? {
        await Task.detached(priority: .utility) {
            let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/wroopmark-ocr")
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }.value
    }

    /// Longest a single image may take. Vision occasionally deadlocks inside
    /// its text recognizer; that file is skipped instead of stalling the whole queue.
    static let perFileTimeoutSeconds: Double = 45

    /// One recognized text per file, in order ("" for files skipped after a
    /// stall); nil only if the helper cannot start at all or task was cancelled.
    static func run(_ helper: URL, files: [String]) async -> [String]? {
        await Task.detached(priority: .utility) { () -> [String]? in
            var results: [String] = []
            var remaining = files[...]
            while !remaining.isEmpty && !Task.isCancelled {
                guard let got = await runOnce(helper, files: Array(remaining)) else { return nil }
                results += got
                remaining = remaining.dropFirst(got.count)
                // The helper stopped short: it hung (or crashed) on the next
                // file. Skip that one and continue in a fresh process.
                if !remaining.isEmpty && !Task.isCancelled {
                    results.append("")
                    remaining = remaining.dropFirst()
                }
            }
            return Task.isCancelled ? nil : results
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
        let lines = Mutex<[String]>([])

        return await withTaskCancellationHandler {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    do {
                        for try await line in output.fileHandleForReading.bytes.lines {
                            if Task.isCancelled { break }
                            let parsed = (try? JSONDecoder().decode(String.self, from: Data(line.utf8))) ?? ""
                            let count = lines.withLock { store -> Int in
                                store.append(parsed)
                                return store.count
                            }
                            if count >= files.count { break }
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
            return lines.withLock { $0 }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
    }
}

/// Splits "a, b/c ,d" into tag names.
func parseTags(_ text: String) -> [String] {
    text.split(whereSeparator: { $0 == "," || $0 == "\n" })
        .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
        .filter { !$0.isEmpty }
}
