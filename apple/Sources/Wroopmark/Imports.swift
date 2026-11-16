import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

// Getting things in and out (v0.2): data downloads and bookmark files,
// pictures and videos from disk, Markdown / CSV / JSON export, and posters
// for videos that came without one.
extension AppModel {
    static let mediaExtensions: Set<String> = ["mp4", "mov", "m4v", "3gp", "jpg", "jpeg", "png", "heic", "gif", "webp", "avif"]
    private static let dataExtensions: Set<String> = ["zip", "html", "htm", "json", "js", "csv", "txt"]

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// A folder is a data download when it holds JSON / HTML / CSV / TXT
    /// files; otherwise it is taken as a folder of pictures and videos.
    private static func holdsData(_ dir: URL) -> Bool {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return false }
        var seen = 0
        for case let url as URL in e {
            seen += 1
            if seen > 5000 { break }
            if dataExtensions.contains(url.pathExtension.lowercased()), url.pathExtension.lowercased() != "zip" { return true }
        }
        return false
    }

    func chooseImport() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "İçe aktar")
        panel.message = String(localized: "Veri paketi (.zip ya da klasör), bookmarks.html, Pocket/Raindrop CSV, ya da video ve görseller")
        panel.prompt = String(localized: "İçe aktar")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importURLs(urls) }
    }

    /// Sorts what was picked or dropped: media goes in as files, everything
    /// else is read as an archive (bookmarks, platform data, CSV).
    func importURLs(_ urls: [URL]) async {
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty else { return }
        var media: [URL] = []
        var archives: [URL] = []
        for url in files {
            if Self.isDirectory(url) {
                (Self.holdsData(url) ? { archives.append(url) } : { media.append(url) })()
            } else if Self.mediaExtensions.contains(url.pathExtension.lowercased()) {
                media.append(url)
            } else {
                archives.append(url)
            }
        }
        isTransferring = true
        defer { isTransferring = false }
        var lines: [String] = []
        for url in archives {
            transferStatus = String(localized: "\(url.lastPathComponent) okunuyor…")
            do {
                let r: ArchiveReport = try await core.call(.call("import_archive", ["path": .string(url.path)]))
                var line = String(localized: "\(url.lastPathComponent): \(r.found) kayıt bulundu, \(r.new) yeni")
                if r.existing > 0 { line += String(localized: ", \(r.existing) zaten vardı") }
                if r.new > 0 { line += String(localized: ". Metin, yazar ve medya arka planda gelecek.") }
                lines.append(line)
            } catch {
                lines.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !media.isEmpty {
            transferStatus = String(localized: "Dosyalar kopyalanıyor…")
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
        transferStatus = lines.joined(separator: "\n")
        await refreshLoaded()
        await refreshMeta(force: true)
        await loadFolders()
        startPosters()
        startEmbedding()
        await loadAIStatus()
    }

    // MARK: - Export

    enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
        case markdown = "md", csv, json, html
        var id: String { rawValue }
        var label: String {
            switch self {
            case .markdown: "Markdown (Obsidian)"
            case .csv: String(localized: "CSV (tablo)")
            case .json: String(localized: "JSON satırları")
            case .html: String(localized: "Tek sayfa (HTML)")
            }
        }
    }

    /// The name of what is on screen, for a page made of it.
    private var scopeTitle: String {
        switch scope {
        case .folder(_, let name): name.split(separator: "/").last.map(String.init) ?? name
        case .tag(let key): "#\(key)"
        case .platform(let p): p.label
        case .saved(let s): s.name
        default: "wroopmark"
        }
    }

    /// One HTML page (pictures inside it) of what `query` finds, saved
    /// where the user says: something to send to someone, opens anywhere.
    func exportPage(query: String, title: String) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Tek sayfa olarak dışa aktar")
        panel.nameFieldStringValue = "\(title).html"
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        let english = Locale.current.language.languageCode?.identifier == "en"
        Task {
            isTransferring = true
            defer { isTransferring = false }
            transferStatus = String(localized: "Sayfa hazırlanıyor…")
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wm-page-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            do {
                let r: ExportReport = try await core.call(.call("export", [
                    "q": .string(query), "format": .string("html"), "dest": .string(tmp.path),
                    "title": .string(title), "lang": .string(english ? "en" : "tr"),
                ]))
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: URL(fileURLWithPath: r.path), to: target)
                transferStatus = String(localized: "\(r.count) kayıt tek sayfada") + (r.media > 0 ? String(localized: ", \(r.media) görsel") : "")
                NSWorkspace.shared.activateFileViewerSelecting([target])
            } catch {
                transferStatus = error.localizedDescription
            }
        }
    }

    /// Exports what is on screen (view + filters + search) to a folder.
    func chooseExport(_ format: ExportFormat) {
        if format == .html {
            exportPage(query: effectiveQuery, title: scopeTitle)
            return
        }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Dışa aktar")
        panel.message = String(localized: "\(total) kayıt (şu anki görünüm ve arama) \(format.label) olarak bu klasöre yazılacak")
        panel.prompt = String(localized: "Buraya aktar")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, var dest = panel.url else { return }
        if format == .markdown {
            // One note per item: keep them together in a folder of their own.
            let stamp = Date().formatted(.iso8601.year().month().day())
            dest.append(path: "wroopmark \(stamp)", directoryHint: .isDirectory)
        }
        let q = effectiveQuery
        Task {
            isTransferring = true
            defer { isTransferring = false }
            transferStatus = String(localized: "Dışa aktarılıyor…")
            do {
                let r: ExportReport = try await core.call(.call("export", [
                    "q": .string(q), "format": .string(format.rawValue), "dest": .string(dest.path), "media": .bool(true),
                ]))
                transferStatus = String(localized: "\(r.count) kayıt aktarıldı") + (r.media > 0 ? String(localized: ", \(r.media) medya dosyası") : "")
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.path)])
            } catch {
                transferStatus = error.localizedDescription
            }
        }
    }

    // MARK: - Posters

    /// Videos imported from disk have no poster; one is drawn from the
    /// video itself (AVFoundation, a frame at half a second).
    func startPosters() {
        guard posterTask == nil else { return }
        struct Row: Decodable, Sendable {
            let id: String
            let videoFile: String
            let path: String
        }
        posterTask = Task(priority: .utility) { [weak self] in
            defer { self?.posterTask = nil }
            while let self, !Task.isCancelled {
                guard let rows: [Row] = try? await self.core.call(.call("posterless", ["limit": .int(20)])), !rows.isEmpty else { break }
                var made = 0
                for row in rows {
                    guard !Task.isCancelled else { break }
                    guard let jpg = await Poster.make(from: URL(fileURLWithPath: row.path)) else { continue }
                    let ok = await self.perform(.call("set_poster", ["id": .string(row.id), "video_file": .string(row.videoFile), "path": .string(jpg.path)]))
                    try? FileManager.default.removeItem(at: jpg)
                    if ok { made += 1 }
                }
                if made == 0 { break }
                await self.refreshLoaded()
            }
        }
    }
}

enum Poster {
    /// A JPEG of one frame, in a temporary file the caller removes.
    static func make(from video: URL) async -> URL? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1280, height: 1280)
        guard let (cg, _) = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("wroopmark-poster-\(UUID().uuidString).jpg")
        do {
            try data.write(to: out)
            return out
        } catch {
            return nil
        }
    }
}
