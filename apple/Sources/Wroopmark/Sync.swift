import AppKit
import Foundation

// v0.5: sync through a shared folder (iCloud Drive by default). The core
// does the work (`sync_now`); the app runs it now and then and after local
// changes, and shows the state in Settings → Senkron.
extension AppModel {
    /// `~/Library/Mobile Documents/com~apple~CloudDocs/wroopmark`, when iCloud Drive is on.
    static var iCloudFolder: URL? {
        let drive = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: drive.path) ? drive.appendingPathComponent("wroopmark", isDirectory: true) : nil
    }

    func loadSyncStatus() async {
        if let s: SyncStatus = try? await core.call(.call("sync_status", [:])), s != syncStatus { syncStatus = s }
    }

    func enableSync(at folder: URL) async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            let r: SyncReport = try await core.call(.call("sync_enable", [
                "dir": .string(folder.path), "name": .string(Host.current().localizedName ?? "Mac"),
            ]))
            syncMessage = "Senkron açıldı: \(r.pushed) kayıt gönderildi, \(r.applied) değişiklik alındı."
            await afterSync(r)
            startSyncLoop()
        } catch {
            syncMessage = error.localizedDescription
        }
        await loadSyncStatus()
    }

    func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.title = "Senkron klasörü"
        panel.message = "Diğer cihazların da gördüğü bir klasör seç (iCloud Drive, Syncthing, Dropbox…)."
        panel.prompt = "Bu klasörü kullan"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await enableSync(at: url) }
    }

    func disableSync() async {
        syncTask?.cancel()
        syncTask = nil
        _ = await perform(.call("sync_disable", [:]))
        syncMessage = nil
        await loadSyncStatus()
    }

    func setSyncMedia(_ mode: String) async {
        _ = await perform(.call("sync_set_media", ["media": .string(mode)]))
        await loadSyncStatus()
    }

    /// One round: send ours, take theirs.
    func syncNow(quiet: Bool = true) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let r: SyncReport = try await core.call(.call("sync_now", [:]))
            lastSyncAt = .now
            if !quiet || r.applied > 0 {
                syncMessage = r.applied > 0 ? "Diğer cihazlardan \(r.applied) değişiklik geldi." : "Her şey güncel."
            }
            await afterSync(r)
        } catch {
            syncMessage = error.localizedDescription
        }
    }

    private func afterSync(_ r: SyncReport) async {
        // Pictures iCloud has not downloaded yet ("Optimize Mac Storage"):
        // the next round takes them.
        SyncReport.requestDownloads(r.fetch ?? [])
        if r.applied > 0 {
            await refreshLoaded()
            await refreshMeta(force: true)
            await loadFolders()
            await loadSavedSearches()
            startEmbedding()
        }
    }

    /// Every minute while sync is on, and soon after local changes (the
    /// watcher calls `syncSoon`). Cheap when nothing changed.
    func startSyncLoop() {
        guard enableSystemIntegrations, syncTask == nil else { return }
        syncTask = Task(priority: .utility) { [weak self] in
            defer { self?.syncTask = nil }
            await self?.loadSyncStatus()
            while let self, self.syncStatus?.enabled == true, !Task.isCancelled {
                await self.syncNow()
                await self.loadSyncStatus()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func syncSoon() {
        guard syncStatus?.enabled == true else { return }
        syncDebounce?.cancel()
        syncDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
            await self?.loadSyncStatus()
        }
    }
}
