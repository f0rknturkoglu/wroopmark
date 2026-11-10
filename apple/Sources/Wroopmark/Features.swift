import AppKit
import Foundation

// Saved searches, backups, deep links, folder suggestions and link checks.
// State lives in AppModel (stored properties cannot go in an extension);
// the behavior is here.
extension AppModel {
    // MARK: - Saved searches

    private static let savedSearchesKey = "ui.saved_searches"

    func loadSavedSearches() async {
        do {
            guard let raw: String = try await core.callOptional(.uiGet(key: Self.savedSearchesKey), as: String.self),
                  let data = raw.data(using: .utf8) else { return }
            let list = try JSONDecoder().decode([SavedSearch].self, from: data)
            if list != savedSearches { savedSearches = list }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func storeSavedSearches() async {
        do {
            let data = try JSONEncoder().encode(savedSearches)
            guard let text = String(data: data, encoding: .utf8) else { return }
            _ = try await core.run(.uiSet(key: Self.savedSearchesKey, value: text))
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// What "save this search" would keep: the view, the filters and the
    /// search box together. Empty when there is nothing worth saving.
    var searchToSave: String {
        switch scope {
        case .links, .triage: return ""
        default: break
        }
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty || !filters.isEmpty, !typed.hasPrefix("id:") else { return "" }
        return effectiveQuery
    }

    func saveSearch(name: String) async {
        let q = searchToSave
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !clean.isEmpty else { return }
        let saved = SavedSearch(id: UUID().uuidString, name: clean, query: q)
        savedSearches.append(saved)
        await storeSavedSearches()
        query = ""
        filters = AdvancedFilters()
        scope = .saved(saved)
    }

    func renameSavedSearch(_ s: SavedSearch, to name: String) async {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = savedSearches.firstIndex(where: { $0.id == s.id }) else { return }
        savedSearches[i].name = clean
        if case .saved(let cur) = scope, cur.id == s.id { scope = .saved(savedSearches[i]) }
        await storeSavedSearches()
    }

    func deleteSavedSearch(_ s: SavedSearch) async {
        savedSearches.removeAll { $0.id == s.id }
        if case .saved(let cur) = scope, cur.id == s.id { scope = .all }
        await storeSavedSearches()
    }

    // MARK: - Deep links (wroopmark://, Spotlight, the extension)

    /// Shows one item, selected, whatever was on screen before. The search
    /// box keeps `id:…`, so clearing it goes back to the whole library.
    func reveal(id: String) {
        NSApp.activate(ignoringOtherApps: true)
        filters = AdvancedFilters()
        pendingRevealID = id
        showDetailPane = true
        query = "id:\(id)"
        if scope != .all { scope = .all } else { Task { await reload() } }
    }

    /// `wroopmark://item/<id>`, `wroopmark://search?q=…`, `wroopmark://add?url=…`.
    func open(url: URL) {
        guard url.scheme == "wroopmark" else { return }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let param = { (name: String) in parts?.queryItems?.first { $0.name == name }?.value }
        switch url.host {
        case "item":
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).removingPercentEncoding ?? ""
            if !id.isEmpty { reveal(id: id) }
        case "search":
            NSApp.activate(ignoringOtherApps: true)
            filters = AdvancedFilters()
            query = param("q") ?? ""
            if scope != .all { scope = .all }
        case "add":
            if let link = param("url") { Task { await QuickSave.shared.save(link) } }
        default:
            break
        }
    }

    // MARK: - Clean-up: folder suggestions

    func loadTriageSuggestions() async {
        triageSuggestionsTask?.cancel()
        guard scope == .triage, let item = items.first, !folders.isEmpty else {
            if !triageSuggestions.isEmpty { triageSuggestions = [] }
            return
        }
        let id = item.id
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let found: [FolderSuggestion] = try await self.core.call(.suggestFolders(id: id, limit: 3))
                guard !Task.isCancelled, self.items.first?.id == id else { return }
                if found != self.triageSuggestions { self.triageSuggestions = found }
            } catch is CancellationError {
                return
            } catch {
                self.metaError = error.localizedDescription
            }
        }
        triageSuggestionsTask = task
        await task.value
    }

    // MARK: - Link checks

    /// Checks every link not checked this week, ten at a time.
    func checkLinks() async {
        guard linkCheckTask == nil else { return }
        isCheckingLinks = true
        linksChecked = 0
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isCheckingLinks = false
                self.linkCheckTask = nil
            }
            do {
                while !Task.isCancelled {
                    let n: Int = try await self.core.call(.checkLinks(limit: 10), network: true)
                    guard n > 0, !Task.isCancelled else { break }
                    self.linksChecked += n
                    await self.loadLinks(reset: false)
                }
                if !Task.isCancelled {
                    await self.loadLinks(reset: false)
                }
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
        linkCheckTask = task
        await task.value
    }

    func stopCheckingLinks() {
        linkCheckTask?.cancel()
        linkCheckTask = nil
        isCheckingLinks = false
    }

    // MARK: - Backups

    /// Asks where backups go (an external disk, a synced folder…).
    func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Seç"
        panel.message = "Yedeğin konacağı klasörü seç. İçinde bir \"wroopmark-yedek\" klasörü oluşur."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backupFolder = url.path
        backupError = nil
    }

    /// The folder the backup is written to.
    var backupTarget: URL? {
        backupFolder.map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("wroopmark-yedek", isDirectory: true) }
    }

    func runBackup() async {
        guard !isBackingUp, let folder = backupFolder, let target = backupTarget else { return }
        // Check off the main thread so slow/unmounted disks don't hang UI.
        guard await HostInstaller.fileExists(atPath: folder) else {
            backupError = "Yedek klasörü şu an yok (disk takılı mı?): \(folder)"
            return
        }
        isBackingUp = true
        defer { isBackingUp = false }
        do {
            let report: BackupReport = try await core.call(.backup(dest: target.path), network: true)
            lastBackupReport = report
            lastBackupAt = .now
            backupError = nil
        } catch is CancellationError {
            return
        } catch {
            backupError = error.localizedDescription
        }
    }

    /// Once a day while the app runs, when automatic backups are on.
    func startBackupSchedule() {
        backupScheduleTask?.cancel()
        backupScheduleTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(30))
                while !Task.isCancelled {
                    guard let self else { return }
                    if self.autoBackup, self.backupFolder != nil, (self.lastBackupAt.map { Date.now.timeIntervalSince($0) > 86_400 } ?? true) {
                        await self.runBackup()
                    }
                    try await Task.sleep(for: .seconds(3600))
                }
            } catch is CancellationError {
                return
            } catch {}
        }
    }

    // MARK: - Menu bar

    func loadRecent() async {
        struct R: Decodable, Sendable { let items: [Item] }
        do {
            let r: R = try await core.call(.search(q: "", sort: "saved", limit: 6, offset: 0))
            if r.items != recentItems {
                recentItems = r.items
            }
        } catch is CancellationError {
            return
        } catch {
            metaError = error.localizedDescription
        }
    }
}
