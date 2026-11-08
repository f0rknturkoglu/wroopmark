import AppKit
import Foundation

// Saved searches, backups, deep links, folder suggestions and link checks.
// State lives in AppModel (stored properties cannot go in an extension);
// the behavior is here.
extension AppModel {
    // MARK: - Saved searches

    private static let savedSearchesKey = "ui.saved_searches"

    func loadSavedSearches() async {
        // Nothing saved yet comes back as null, which `call` reports as an error.
        guard let raw: String = try? await core.call(["cmd": "ui_get", "key": Self.savedSearchesKey]),
              let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([SavedSearch].self, from: data) else { return }
        if list != savedSearches { savedSearches = list }
    }

    private func storeSavedSearches() async {
        guard let data = try? JSONEncoder().encode(savedSearches), let text = String(data: data, encoding: .utf8) else { return }
        _ = await perform(["cmd": "ui_set", "key": Self.savedSearchesKey, "value": text])
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
        guard scope == .triage, let item = items.first, !folders.isEmpty else {
            if !triageSuggestions.isEmpty { triageSuggestions = [] }
            return
        }
        let id = item.id
        let found: [FolderSuggestion] = (try? await core.call(["cmd": "suggest_folders", "id": id, "limit": 3])) ?? []
        guard items.first?.id == id else { return }
        if found != triageSuggestions { triageSuggestions = found }
    }

    // MARK: - Link checks

    /// Checks every link not checked this week, ten at a time.
    func checkLinks() async {
        guard !isCheckingLinks else { return }
        isCheckingLinks = true
        linksChecked = 0
        defer { isCheckingLinks = false }
        while isCheckingLinks, let n: Int = try? await core.call(["cmd": "check_links", "limit": 10], network: true), n > 0 {
            linksChecked += n
            await loadLinks()
        }
        await loadLinks()
    }

    func stopCheckingLinks() { isCheckingLinks = false }

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
        // An unplugged disk: skip quietly until it is back.
        guard FileManager.default.fileExists(atPath: folder) else {
            backupError = "Yedek klasörü şu an yok (disk takılı mı?): \(folder)"
            return
        }
        isBackingUp = true
        defer { isBackingUp = false }
        do {
            let report: BackupReport = try await core.call(["cmd": "backup", "dest": target.path], network: true)
            lastBackupReport = report
            lastBackupAt = .now
            backupError = nil
        } catch {
            backupError = error.localizedDescription
        }
    }

    /// Once a day while the app runs, when automatic backups are on.
    func startBackupSchedule() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                guard let self else { return }
                if self.autoBackup, self.backupFolder != nil, (self.lastBackupAt.map { Date.now.timeIntervalSince($0) > 86_400 } ?? true) {
                    await self.runBackup()
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    // MARK: - Menu bar

    func loadRecent() async {
        struct R: Decodable { let items: [Item] }
        if let r: R = try? await core.call(["cmd": "search", "q": "", "sort": "saved", "limit": 6]), r.items != recentItems {
            recentItems = r.items
        }
    }
}
