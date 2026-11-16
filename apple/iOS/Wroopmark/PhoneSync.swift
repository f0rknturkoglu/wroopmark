import SwiftUI
import UIKit

// Sync on iPhone: the user picks the `wroopmark` folder the Mac made in
// iCloud Drive once; the app keeps access through a bookmark, makes iCloud
// download the other devices' logs, and lets the core do the rest.
extension PhoneModel {
    private static let bookmarkKey = "syncFolderBookmark"

    func startSync() async {
        #if DEBUG
        // Simulator tests: a folder on the Mac, no picker.
        if let path = ProcessInfo.processInfo.environment["WROOPMARK_SYNC_DIR"], !path.isEmpty {
            syncFolder = URL(fileURLWithPath: path, isDirectory: true)
            await loadSyncStatus()
            if syncStatus?.enabled == true && syncStatus?.dir == path { await syncNow() } else { await enableSync() }
            return
        }
        #endif
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
            await loadSyncStatus()
            return
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return }
        _ = url.startAccessingSecurityScopedResource()
        if stale, let fresh = try? url.bookmarkData() { UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey) }
        syncFolder = url
        await syncNow()
    }

    /// From the folder picker.
    func useSyncFolder(_ url: URL) async {
        _ = url.startAccessingSecurityScopedResource()
        if let data = try? url.bookmarkData() { UserDefaults.standard.set(data, forKey: Self.bookmarkKey) }
        syncFolder = url
        await enableSync()
    }

    private func enableSync() async {
        guard let folder = syncFolder else { return }
        isSyncing = true
        defer { isSyncing = false }
        syncMessage = "Mac'teki kütüphane indiriliyor…"
        await Self.fetchLogs(in: folder)
        do {
            let r: SyncReport = try await core.call(.call("sync_enable", ["dir": .string(folder.path), "name": .string(UIDevice.current.name)]))
            lastSyncAt = .now
            syncMessage = r.applied > 0 ? "\(r.applied) kayıt geldi." : "Senkron açık."
            await afterSync(r)
        } catch {
            syncMessage = error.localizedDescription
        }
        await loadSyncStatus()
    }

    func disableSync() async {
        _ = await perform(.call("sync_disable", [:]))
        syncFolder?.stopAccessingSecurityScopedResource()
        syncFolder = nil
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        syncMessage = nil
        await loadSyncStatus()
    }

    func loadSyncStatus() async {
        if let s: SyncStatus = try? await core.call(.call("sync_status", [:])) { syncStatus = s }
    }

    // MARK: Videos on demand

    private struct Offload: Decodable, Sendable {
        let files: Int
        let bytes: Int64
    }

    func setVideosOnDemand(_ on: Bool) async {
        guard await perform(.call("videos_on_demand", ["on": .bool(on)])) else { return }
        await loadSyncStatus()
        await syncNow()
        await loadOffloadable()
    }

    func loadOffloadable() async {
        guard syncStatus?.videosOnDemand == true,
              let o: Offload = try? await core.call(.call("offload_videos", ["dry_run": .bool(true)]))
        else {
            offloadable = nil
            return
        }
        offloadable = (o.files, o.bytes)
    }

    func offloadVideos() async {
        guard let o: Offload = try? await core.call(.call("offload_videos", [:])) else { return }
        syncMessage = "\(o.files) video telefondan kaldırıldı, \(ByteCountFormatter.string(fromByteCount: o.bytes, countStyle: .file)) boşaldı. İzlediğinde iCloud'dan yeniden iner."
        await loadOffloadable()
        await refreshMeta()
        await checkSpace(force: true)
    }

    /// One round: send ours, take theirs. Quiet unless something came.
    func syncNow() async {
        guard let folder = syncFolder, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        await Self.fetchLogs(in: folder)
        do {
            let r: SyncReport = try await core.call(.call("sync_now", [:]))
            lastSyncAt = .now
            if r.applied > 0 { syncMessage = "\(r.applied) değişiklik geldi." }
            await afterSync(r)
        } catch {
            syncMessage = error.localizedDescription
        }
        await loadSyncStatus()
    }

    func syncSoon() {
        guard syncFolder != nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            await syncNow()
        }
    }

    private func afterSync(_ r: SyncReport) async {
        syncWaiting = r.waiting ?? 0
        if r.applied > 0 || r.mediaIn > 0 {
            await reload()
            await refreshMeta()
            Spotlight.indexRecent()
            WidgetSnapshot.refresh()
        }
        if r.applied > 0 {
            startEmbedding()
        }
        takeICloudMedia(r)
    }

    /// The Mac's pictures arrive through iCloud at their own pace; the sync
    /// never waits for them. Ask for the next ones, and while the app is
    /// open come back every little while to take what has arrived.
    private func takeICloudMedia(_ r: SyncReport) {
        // Asked again after a while: a request made before the other device
        // finished uploading the file does nothing.
        let now = Date.now
        let fresh = (r.fetch ?? []).filter { askedICloud[$0].map { now.timeIntervalSince($0) > 300 } ?? true }
        for p in fresh { askedICloud[p] = now }
        SyncReport.requestDownloads(fresh)
        guard syncWaiting > 0, mediaRound == nil else { return }
        mediaRound = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self else { return }
            self.mediaRound = nil
            if UIApplication.shared.applicationState == .active { await self.syncNow() }
        }
    }

    /// iCloud keeps files it has not downloaded as `.name.icloud`
    /// placeholders. The logs must be real files before the core reads
    /// them; pictures are left alone (missing ones download from the web).
    nonisolated static func fetchLogs(in folder: URL) async {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let coordinator = NSFileCoordinator()
            for sub in ["ops", "devices"] {
                let dir = folder.appendingPathComponent(sub, isDirectory: true)
                var files: [URL] = []
                for entry in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                    if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        files += (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? []
                    } else {
                        files.append(entry)
                    }
                }
                for f in files {
                    var target = f
                    let name = f.lastPathComponent
                    if name.hasPrefix("."), name.hasSuffix(".icloud") {
                        target = f.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst().dropLast(7)))
                        try? fm.startDownloadingUbiquitousItem(at: target)
                    }
                    // A coordinated read waits until the file is local.
                    var err: NSError?
                    coordinator.coordinate(readingItemAt: target, options: [], error: &err) { _ in }
                }
            }
        }.value
    }
}
