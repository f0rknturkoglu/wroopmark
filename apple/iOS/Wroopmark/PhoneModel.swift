import AVFoundation
import Observation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What the list shows besides the search box.
enum PhoneScope: Hashable, Sendable {
    case all
    case today
    case untagged
    case platform(String)
    case tag(String)
    case folder(Int64, String)
    case saved(SavedSearch)

    var filter: String {
        switch self {
        case .all, .today: ""
        case .untagged: "is:untagged"
        case .platform(let p): "platform:\(p)"
        case .tag(let t): t.contains(" ") ? "tag:\"\(t)\"" : "tag:\(t)"
        case .folder(let id, _): "folder:\(id)"
        case .saved(let s): s.query
        }
    }

    var title: String {
        switch self {
        case .all: "wroopmark"
        case .today: String(localized: "Bugün")
        case .untagged: String(localized: "Etiketsiz")
        case .platform(let p): Platform(rawValue: p)?.label ?? p
        case .tag(let t): "#\(t)"
        case .folder(_, let name): name.split(separator: "/").last.map(String.init) ?? name
        case .saved(let s): s.name
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
    var sort = ""
    var filterTokens: Set<String> = []
    var activeModal: String?
    var scope: PhoneScope = .all
    var tags: [TagCount] = []
    var folders: [Folder] = []
    var savedSearches: [SavedSearch] = []
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

    // On-device AI & Today (v0.8)
    var semanticSearch = false
    var aiStatus: AIStatus?
    var onThisDay: [Item] = []
    var rediscover: [Item] = []
    var summarizing = Set<String>()
    @ObservationIgnored private var embedTask: Task<Void, Never>?
    @ObservationIgnored var ocrTask: Task<Void, Never>?
    @ObservationIgnored var pageCopyTask: Task<Void, Never>?
    @ObservationIgnored private var embedPausedUntil: Date?

    // A page to share (one HTML file)
    var sharedPage: SharedPage?
    var makingPage = false

    // Import (v0.9)
    var isImporting = false
    var importMessage: String?

    // Sync (PhoneSync.swift)
    var syncStatus: SyncStatus?
    var syncFolder: URL? { didSet { PhoneMedia.syncFolder = syncFolder } }
    @ObservationIgnored var syncAccessFolder: URL?
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

    /// `wroopmark://item/<id>`, `wroopmark://search?q=…`, `wroopmark://add-clipboard`, `wroopmark://add`, `wroopmark://triage`, `wroopmark://feed`.
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
        case "add-clipboard":
            clipboardSaveTask?.cancel()
            clipboardSaveTask = Task { await saveFromClipboard() }
        case "add", "triage", "feed":
            activeModal = url.host
        default:
            break
        }
    }

    /// Set by Shortcuts or Home Screen Quick Actions before the app comes up.
    static var pendingQuery: String?
    static var pendingItemID: String?
    static var pendingAction: String?
    @ObservationIgnored private var clipboardSaveTask: Task<Void, Never>?

    var effectiveQuery: String {
        [
            scope.filter,
            filterTokens.sorted().joined(separator: " "),
            query.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    func start() async {
        PhoneAI.register()
        ReaderView.onEdit = { [weak self] in self?.syncSoon() }
        guard await core.ensureOpen() else {
            errorMessage = String(localized: "Kütüphane açılamadı")
            return
        }
        // The phone never downloads videos from the sites themselves; a
        // video plays here only if the Mac put its file in the sync folder.
        _ = try? await core.run(.setSettings(downloadVideos: false))
        Self.keepMediaOutOfBackups(core.libraryURL)
        await checkSpace(force: true)
        fetchShared()
        await makePosters()
        takePendingQuery()
        await reload()
        await refreshMeta()
        await startSync()
        await loadAIStatus()
        startEmbedding()
        startOCR()
        startPageCopies()
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

    func saveFromClipboard() async {
        _ = await core.ensureOpen()
        let pb = UIPasteboard.general
        guard let link = pb.url?.absoluteString ?? pb.string.flatMap(firstLink(in:)) else {
            notice = String(localized: "Panoda kaydedilecek bağlantı bulunamadı.")
            return
        }
        dismissClipboard()
        if await addURL(link, tags: []) {
            notice = String(localized: "Panodaki bağlantı kaydedildi.")
        }
    }

    func becameActive() async {
        takePendingQuery()
        await checkClipboard()
        // Links saved from the share sheet meanwhile: show them, fill them in.
        await reload()
        await checkSpace()
        fetchShared()
        await makePosters()
        await syncNow()
        startEmbedding()
        startOCR()
        startPageCopies()
    }

    /// Going to the background: stop downloads and settle the database, so
    /// iOS does not find the shared library locked while the app sleeps.
    func enteredBackground() {
        embedTask?.cancel()
        stopOCR()
        stopPageCopies()
        embedTask = nil
        PhoneAI.unload()
        let task = BackgroundTask(name: "wroopmark-pause")
        Task {
            // What was changed just before leaving goes out now, not on
            // the next open.
            await syncNow()
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
                startPageCopies()
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
        if let id = Self.pendingItemID {
            Self.pendingItemID = nil
            openRequest = id
        }
        if let action = Self.pendingAction {
            Self.pendingAction = nil
            if action == "clipboard" {
                clipboardSaveTask?.cancel()
                clipboardSaveTask = Task { await saveFromClipboard() }
            } else {
                activeModal = action
            }
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

    // MARK: On-device AI

    static func hasWords(_ q: String) -> Bool {
        q.split(whereSeparator: \.isWhitespace).contains { tok in
            let t = String(tok)
            if t.hasPrefix("\"") { return true }
            return !t.hasPrefix("-") && !t.hasPrefix("@") && !t.contains(":")
        }
    }

    func searchCommand(q: String, sort: String, limit: Int, offset: Int) -> CoreCommand {
        guard semanticSearch, Self.hasWords(q) else {
            return .search(q: q, sort: sort, limit: limit, offset: offset)
        }
        return .call("semantic_search", ["q": .string(q), "sort": .string(sort), "limit": .int(Int64(limit)), "offset": .int(Int64(offset))])
    }

    func loadAIStatus() async {
        aiStatus = try? await core.call(.call("ai_status", [:]), network: true)
    }

    func startEmbedding() {
        guard !lowSpace, embedTask == nil, embedPausedUntil.map({ $0 < .now }) ?? true else { return }
        embedTask = Task(priority: .background) { [weak self] in
            defer {
                PhoneAI.unload()
                self?.embedTask = nil
            }
            while let self, !self.lowSpace, !Task.isCancelled {
                do {
                    let r: EmbedReport = try await self.core.call(.call("embed_pending", ["limit": .int(32)]), network: true)
                    if r.done == 0 || r.remaining == 0 { break }
                    try? await Task.sleep(for: .milliseconds(300))
                } catch is CancellationError {
                    break
                } catch {
                    self.embedPausedUntil = .now + 1800
                    break
                }
            }
            await self?.loadAIStatus()
        }
    }

    @discardableResult
    func summarize(_ id: String) async -> Item? {
        guard !summarizing.contains(id) else { return nil }
        summarizing.insert(id)
        defer { summarizing.remove(id) }
        do {
            let item: Item = try await core.call(.call("summarize", ["id": .string(id)]), network: true)
            if let i = items.firstIndex(where: { $0.id == id }) { items[i] = item }
            syncSoon()
            return item
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func related(for id: String) async -> [Item] {
        (try? await core.call(.call("related", ["id": .string(id), "limit": .int(6)]))) ?? []
    }

    func transcribeVideo(for item: Item) async throws -> String {
        guard let vf = item.media.first(where: { $0.isVideo && $0.videoFile != nil })?.videoFile else {
            return ""
        }
        let url = core.mediaURL(vf)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "wroopmark", code: 2, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Video dosyası henüz cihazda değil."),
            ])
        }
        let transcript = try await VideoSpeech.transcribe(url: url)
        guard !transcript.isEmpty else { return "" }
        _ = await perform(.appendExtra(id: item.id, text: transcript))
        syncSoon()
        return transcript
    }

    func suggestBatch(q: String = "", limit: Int = 25) async -> [BatchSuggestion] {
        (try? await core.call(.call("suggest_batch", ["q": .string(q), "limit": .int(Int64(limit))]))) ?? []
    }

    func applyBatch(_ entries: [BatchSuggestion]) async -> Int {
        guard !entries.isEmpty else { return 0 }
        let payload: [CoreArg] = entries.map { e in
            var obj: [String: CoreArg] = [
                "id": .string(e.id),
                "tags": .strings(e.tags),
            ]
            if let fid = e.folderId {
                obj["folder_id"] = .int(fid)
            }
            return .object(obj)
        }
        let count: Int = (try? await core.call(.call("apply_batch", ["items": .array(payload)]))) ?? 0
        await reload()
        await refreshMeta()
        return count
    }

    // MARK: Loading

    func reload() async {
        generation += 1
        let gen = generation
        isLoading = true
        defer { if gen == generation { isLoading = false } }
        do {
            if scope == .today && effectiveQuery.isEmpty && sort.isEmpty {
                let r: TodayResult = try await core.call(.call("today", [:]))
                guard gen == generation else { return }
                onThisDay = r.onThisDay
                rediscover = r.rediscover
                items = r.items
                total = r.total
                reachedEnd = true
                errorMessage = nil
            } else {
                let r: SearchResult = try await core.call(searchCommand(q: effectiveQuery, sort: sort, limit: pageSize, offset: 0))
                guard gen == generation else { return }
                onThisDay = []
                rediscover = []
                items = r.items
                total = r.total
                reachedEnd = r.items.count < pageSize
                errorMessage = nil
            }
        } catch is CancellationError {
            return
        } catch {
            if gen == generation { errorMessage = error.localizedDescription }
        }
    }

    func loadMore() async {
        guard !reachedEnd, !isLoading, !(scope == .today && effectiveQuery.isEmpty && sort.isEmpty) else { return }
        let gen = generation
        isLoading = true
        defer { isLoading = false }
        if let r: SearchResult = try? await core.call(searchCommand(q: effectiveQuery, sort: sort, limit: pageSize, offset: items.count)), gen == generation {
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

    private static let savedSearchesKey = "ui.saved_searches"

    var searchToSave: String {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [scope.filter, typed].filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    func loadSavedSearches() async {
        guard let raw: String = try? await core.callOptional(.uiGet(key: Self.savedSearchesKey), as: String.self),
              let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([SavedSearch].self, from: data) else { return }
        if list != savedSearches { savedSearches = list }
    }

    private func storeSavedSearches() async {
        guard let data = try? JSONEncoder().encode(savedSearches),
              let text = String(data: data, encoding: .utf8) else { return }
        _ = try? await core.run(.uiSet(key: Self.savedSearchesKey, value: text))
    }

    func saveSearch(name: String) async {
        let q = searchToSave
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !clean.isEmpty else { return }
        let saved = SavedSearch(id: UUID().uuidString, name: clean, query: q)
        savedSearches.append(saved)
        await storeSavedSearches()
        query = ""
        scope = .saved(saved)
    }

    func deleteSavedSearch(_ s: SavedSearch) async {
        savedSearches.removeAll { $0.id == s.id }
        if case .saved(let cur) = scope, cur.id == s.id { scope = .all }
        await storeSavedSearches()
    }

    func refreshMeta() async {
        if let t: [TagCount] = try? await core.call(.tags) { tags = t.sorted { $0.count > $1.count } }
        if let f: [Folder] = try? await core.call(.folders) { folders = f.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        if let s: Stats = try? await core.call(.stats) { stats = s }
        await loadSavedSearches()
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

    func addURL(_ url: String, tags: [String], folderID: Int64? = nil) async -> Bool {
        do {
            let item: Item = try await core.call(.addURL(url: url, tags: tags, note: nil, folderID: folderID), network: true)
            items.removeAll { $0.id == item.id }
            items.insert(item, at: 0)
            total += 1
            syncSoon()
            await refreshMeta()
            return true
        } catch {
            // No network (or the site would not answer): keep the link now,
            // fetch the rest later, like the share sheet does.
            if (try? await Self.saveLinkOnly(url, tags: tags, folderID: folderID)) != nil {
                notice = String(localized: "Sayfaya ulaşılamadı; bağlantı kaydedildi, ayrıntılar sonra gelecek.")
                await reload()
                syncSoon()
                return true
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func addNote(title: String?, text: String, tags: [String], folderID: Int64? = nil) async -> Bool {
        do {
            var args: [String: CoreArg] = [
                "text": .string(text),
                "tags": .strings(tags),
            ]
            if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                args["title"] = .string(title.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if let folderID {
                args["folder_id"] = .int(folderID)
            }
            let item: Item = try await core.call(.call("add_note", args))
            items.removeAll { $0.id == item.id }
            items.insert(item, at: 0)
            total += 1
            syncSoon()
            await refreshMeta()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Stores just the link (no network); used offline and by the share sheet.
    nonisolated static func saveLinkOnly(_ url: String, tags: [String], folderID: Int64? = nil) async throws -> String {
        struct Saved: Decodable, Sendable { let id: String }
        var args: [String: CoreArg] = ["url": .string(url), "tags": .strings(tags)]
        if let folderID { args["folder_id"] = .int(folderID) }
        let r: Saved = try await Core.shared.call(.call("save_link", args))
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

    func moveItems(_ ids: [String], to folderID: Int64?) async {
        guard !ids.isEmpty else { return }
        if await perform(.moveItemsToFolder(ids: ids, folderID: folderID)) {
            syncSoon()
            await reload()
            await refreshMeta()
        }
    }

    func tagItems(_ ids: [String], add: [String], remove: [String] = []) async {
        guard !ids.isEmpty else { return }
        if await perform(.editTags(ids: ids, add: add, remove: remove)) {
            syncSoon()
            await reload()
            await refreshMeta()
        }
    }

    func deleteItems(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        for id in ids { _ = await perform(.delete(id: id)) }
        Spotlight.remove(ids)
        let idSet = Set(ids)
        items.removeAll { idSet.contains($0.id) }
        total = max(0, total - ids.count)
        syncSoon()
        await refreshMeta()
    }

    @discardableResult
    func addFolder(name: String) async -> Folder? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let created: Folder? = try? await core.call(.addFolder(name: clean))
        syncSoon()
        await refreshMeta()
        return created
    }

    func renameFolder(id: Int64, name: String) async {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if await perform(.renameFolder(id: id, name: clean)) {
            if case .folder(let fid, _) = scope, fid == id {
                scope = .folder(id, clean)
            }
            syncSoon()
            await refreshMeta()
            await reload()
        }
    }

    func deleteFolder(id: Int64) async {
        if await perform(.deleteFolder(id: id)) {
            if case .folder(let fid, _) = scope, fid == id {
                scope = .all
            }
            syncSoon()
            await refreshMeta()
            await reload()
        }
    }

    func renameTag(from: String, to: String) async {
        let clean = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if await perform(.renameTag(from: from, to: clean)) {
            if case .tag(let cur) = scope, cur == from || cur.hasPrefix(from + "/") {
                scope = .all
            }
            syncSoon()
            await refreshMeta()
            await reload()
        }
    }

    // MARK: Share as one page

    struct SharedPage: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    /// One HTML page (pictures inside) of what `query` finds, for the share sheet.
    func sharePage(query: String, title: String) async {
        guard !makingPage else { return }
        makingPage = true
        defer { makingPage = false }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wm-share", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        let english = Locale.current.language.languageCode?.identifier == "en"
        do {
            let r: ExportReport = try await core.call(.call("export", [
                "q": .string(query), "format": .string("html"), "dest": .string(dir.path),
                "title": .string(title), "lang": .string(english ? "en" : "tr"),
            ]))
            sharedPage = SharedPage(url: URL(fileURLWithPath: r.path))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Import from Files (v0.9)

    static let mediaExtensions: Set<String> = ["mp4", "mov", "m4v", "3gp", "jpg", "jpeg", "png", "heic", "gif", "webp", "avif"]
    private static let dataExtensions: Set<String> = ["html", "htm", "json", "js", "csv", "txt"]

    func importURLs(_ urls: [URL]) async {
        guard !urls.isEmpty, !isImporting else { return }
        isImporting = true
        importMessage = nil
        defer { isImporting = false }

        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("wm-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)

        let staged: [URL] = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let coordinator = NSFileCoordinator()
            var copied: [URL] = []
            for (idx, src) in urls.enumerated() {
                let accessed = src.startAccessingSecurityScopedResource()
                defer { if accessed { src.stopAccessingSecurityScopedResource() } }
                let dst = stage.appendingPathComponent("\(idx)-\(src.lastPathComponent)")
                var coordErr: NSError?
                coordinator.coordinate(readingItemAt: src, options: [], error: &coordErr) { readURL in
                    try? fm.copyItem(at: readURL, to: dst)
                }
                if fm.fileExists(atPath: dst.path) { copied.append(dst) }
            }
            return copied
        }.value

        guard !staged.isEmpty else {
            importMessage = String(localized: "Seçilen dosya okunamadı.")
            return
        }

        var media: [URL] = []
        var archives: [URL] = []
        for url in staged {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDir {
                (Self.directoryHoldsData(url) ? archives.append(url) : media.append(url))
            } else if Self.mediaExtensions.contains(url.pathExtension.lowercased()) {
                media.append(url)
            } else {
                archives.append(url)
            }
        }

        var lines: [String] = []
        for url in archives {
            let displayName = url.lastPathComponent.replacingOccurrences(of: #"^\d+-"#, with: "", options: .regularExpression)
            do {
                let r: ArchiveReport = try await core.call(.call("import_archive", ["path": .string(url.path)]))
                var line = String(localized: "\(displayName): \(r.found) kayıt bulundu, \(r.new) yeni")
                if r.existing > 0 { line += String(localized: ", \(r.existing) zaten vardı") }
                if r.new > 0 { line += String(localized: ". Ayrıntılar arka planda gelecek.") }
                lines.append(line)
            } catch {
                lines.append("\(displayName): \(error.localizedDescription)")
            }
        }
        if !media.isEmpty {
            do {
                let r: FilesReport = try await core.call(.call("import_files", ["paths": .strings(media.map(\.path))]))
                var line = String(localized: "\(r.files) dosya: \(r.new) yeni kayıt")
                if r.attached > 0 { line += String(localized: ", \(r.attached) tanesi arşivdeki gönderisine bağlandı") }
                if r.existing > 0 { line += String(localized: ", \(r.existing) zaten vardı") }
                if r.failed > 0 { line += String(localized: ", \(r.failed) okunamadı") }
                lines.append(line)
            } catch {
                lines.append(error.localizedDescription)
            }
        }

        importMessage = lines.joined(separator: "\n")
        await makePosters()
        await reload()
        await refreshMeta()
        fetchShared()
        startEmbedding()
        startOCR()
        syncSoon()
    }

    func importPhotos(_ chosen: [PhotosPickerItem]) async {
        guard !chosen.isEmpty, !isImporting else { return }
        isImporting = true
        importMessage = nil
        defer { isImporting = false }

        var dirs: [URL] = []
        var paths: [String] = []
        defer { for d in dirs { try? FileManager.default.removeItem(at: d) } }
        for p in chosen {
            guard let file = try? await p.loadTransferable(type: PickedFile.self) else { continue }
            dirs.append(file.url.deletingLastPathComponent())
            paths.append(file.url.path)
        }
        guard !paths.isEmpty else {
            importMessage = String(localized: "Seçilen dosya okunamadı.")
            return
        }
        do {
            let r: FilesReport = try await core.call(.call("import_files", ["paths": .strings(paths)]))
            var line = String(localized: "\(r.files) dosya: \(r.new) yeni kayıt")
            if r.attached > 0 { line += String(localized: ", \(r.attached) tanesi arşivdeki gönderisine bağlandı") }
            if r.existing > 0 { line += String(localized: ", \(r.existing) zaten vardı") }
            if r.failed > 0 { line += String(localized: ", \(r.failed) okunamadı") }
            importMessage = line
        } catch {
            importMessage = error.localizedDescription
        }
        await makePosters()
        await reload()
        await refreshMeta()
        startEmbedding()
        startOCR()
        syncSoon()
    }

    private static func directoryHoldsData(_ dir: URL) -> Bool {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return false
        }
        var seen = 0
        for case let url as URL in e {
            seen += 1
            if seen > 5000 { break }
            if dataExtensions.contains(url.pathExtension.lowercased()) { return true }
        }
        return false
    }

    func makePosters() async {
        struct Row: Decodable, Sendable {
            let id: String
            let videoFile: String
            let path: String
        }
        guard let rows: [Row] = try? await core.call(.call("posterless", ["limit": .int(20)])), !rows.isEmpty else { return }
        for row in rows {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: row.path)))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 1280, height: 1280)
            guard let (cg, _) = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)),
                  let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.82) else { continue }
            let jpg = FileManager.default.temporaryDirectory.appendingPathComponent("wm-poster-\(UUID().uuidString).jpg")
            defer { try? FileManager.default.removeItem(at: jpg) }
            guard (try? data.write(to: jpg)) != nil else { continue }
            _ = try? await core.run(.call("set_poster", ["id": .string(row.id), "video_file": .string(row.videoFile), "path": .string(jpg.path)]))
        }
    }
}

/// A video or picture from Photos, copied to a temporary folder with its
/// own extension (the media store names files by content and type).
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in try Self(copying: received.file) }
        FileRepresentation(importedContentType: .image) { received in try Self(copying: received.file) }
    }

    init(copying src: URL) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pick-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(src.lastPathComponent)
        try FileManager.default.copyItem(at: src, to: url)
    }
}

/// Splits "a, b/c ,d" into tag names.
func phoneTags(_ text: String) -> [String] {
    text.split(whereSeparator: { $0 == "," || $0 == "\n" })
        .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
        .filter { !$0.isEmpty }
}
