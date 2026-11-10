import CWroopmark
import Foundation
import Synchronization

/// Application directory helpers without force-indexed path lookups.
enum AppPaths {
    static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    static var defaultLibraryURL: URL {
        if let override = ProcessInfo.processInfo.environment["WROOPMARK_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return applicationSupportDirectory.appendingPathComponent("wroopmark", isDirectory: true)
    }
}

/// Typed errors surfaced from the Rust FFI layer.
enum CoreError: LocalizedError, Sendable, Equatable {
    case libraryNotOpen
    case invalidHandle
    case noResponse
    case invalidEncoding
    case emptyResult
    case server(String)

    var errorDescription: String? {
        switch self {
        case .libraryNotOpen: "Kütüphane açık değil"
        case .invalidHandle: "Geçersiz tutamaç"
        case .noResponse: "Çekirdek yanıt vermedi"
        case .invalidEncoding: "Çekirdek yanıtı geçersiz"
        case .emptyResult: "Çekirdek boş yanıt döndürdü"
        case .server(let message): message
        }
    }
}

/// Strongly-typed requests understood by the Rust `core::api` JSON dispatcher.
/// Eliminates `[String: Any]`, `NSNull`, and `JSONSerialization` crashes.
enum CoreCommand: Sendable, Encodable, Equatable {
    case stats
    case settings
    case setSettings(downloadVideos: Bool)
    case downloadMedia(id: String)
    case downloadVideos(limit: Int)
    case videoTools
    case dataVersion
    case checkpoint
    case addURL(url: String, tags: [String], note: String?, folderID: Int64?)
    case search(q: String, sort: String, limit: Int, offset: Int)
    case setReviewed(ids: [String], reviewed: Bool)
    case resetReviewed
    case get(id: String)
    case delete(id: String)
    case tags
    case setTags(id: String, tags: [String])
    case editTags(ids: [String], add: [String], remove: [String])
    case renameTag(from: String, to: String)
    case folders
    case addFolder(name: String)
    case renameFolder(id: Int64, name: String)
    case deleteFolder(id: Int64)
    case moveToFolder(id: String, folderID: Int64?)
    case moveItemsToFolder(ids: [String], folderID: Int64?)
    case downloads
    case retryDownload(id: String)
    case retryAllDownloads
    case setNote(id: String, note: String)
    case ocrPending(limit: Int)
    case setOCR(id: String, text: String)
    case links(q: String, limit: Int, offset: Int)
    case linkCounts
    case linksPage(q: String, category: String?, onlyDead: Bool, limit: Int, offset: Int)
    case linkItems(id: Int64, limit: Int, offset: Int)
    case addLink(url: String)
    case deleteLink(id: Int64)
    case enrichLinks(limit: Int)
    case checkLinks(limit: Int)
    case suggestFolders(id: String, limit: Int)
    case backup(dest: String)
    case uiGet(key: String)
    case uiSet(key: String, value: String)
    case kickMedia
    case retryMedia

    private enum CodingKeys: String, CodingKey {
        case cmd, id, ids, q, sort, limit, offset, url, tags, note, name, from, to, add, remove
        case reviewed, text, dest, key, value, category
        case downloadVideos = "download_videos"
        case folderID = "folder_id"
        case onlyDead = "only_dead"
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stats:
            try c.encode("stats", forKey: .cmd)
        case .settings:
            try c.encode("settings", forKey: .cmd)
        case .setSettings(let downloadVideos):
            try c.encode("set_settings", forKey: .cmd)
            try c.encode(downloadVideos, forKey: .downloadVideos)
        case .downloadMedia(let id):
            try c.encode("download_media", forKey: .cmd)
            try c.encode(id, forKey: .id)
        case .downloadVideos(let limit):
            try c.encode("download_videos", forKey: .cmd)
            try c.encode(limit, forKey: .limit)
        case .videoTools:
            try c.encode("video_tools", forKey: .cmd)
        case .dataVersion:
            try c.encode("data_version", forKey: .cmd)
        case .checkpoint:
            try c.encode("checkpoint", forKey: .cmd)
        case .addURL(let url, let tags, let note, let folderID):
            try c.encode("add_url", forKey: .cmd)
            try c.encode(url, forKey: .url)
            try c.encode(tags, forKey: .tags)
            let cleanNote = note.flatMap { $0.isEmpty ? nil : $0 }
            try c.encodeIfPresent(cleanNote, forKey: .note)
            try c.encodeIfPresent(folderID, forKey: .folderID)
        case .search(let q, let sort, let limit, let offset):
            try c.encode("search", forKey: .cmd)
            try c.encode(q, forKey: .q)
            try c.encode(sort, forKey: .sort)
            try c.encode(limit, forKey: .limit)
            try c.encode(offset, forKey: .offset)
        case .setReviewed(let ids, let reviewed):
            try c.encode("set_reviewed", forKey: .cmd)
            try c.encode(ids, forKey: .ids)
            try c.encode(reviewed, forKey: .reviewed)
        case .resetReviewed:
            try c.encode("reset_reviewed", forKey: .cmd)
        case .get(let id):
            try c.encode("get", forKey: .cmd)
            try c.encode(id, forKey: .id)
        case .delete(let id):
            try c.encode("delete", forKey: .cmd)
            try c.encode(id, forKey: .id)
        case .tags:
            try c.encode("tags", forKey: .cmd)
        case .setTags(let id, let tags):
            try c.encode("set_tags", forKey: .cmd)
            try c.encode(id, forKey: .id)
            try c.encode(tags, forKey: .tags)
        case .editTags(let ids, let add, let remove):
            try c.encode("edit_tags", forKey: .cmd)
            try c.encode(ids, forKey: .ids)
            try c.encode(add, forKey: .add)
            try c.encode(remove, forKey: .remove)
        case .renameTag(let from, let to):
            try c.encode("rename_tag", forKey: .cmd)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
        case .folders:
            try c.encode("folders", forKey: .cmd)
        case .addFolder(let name):
            try c.encode("add_folder", forKey: .cmd)
            try c.encode(name, forKey: .name)
        case .renameFolder(let id, let name):
            try c.encode("rename_folder", forKey: .cmd)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
        case .deleteFolder(let id):
            try c.encode("delete_folder", forKey: .cmd)
            try c.encode(id, forKey: .id)
        case .moveToFolder(let id, let folderID):
            try c.encode("move_to_folder", forKey: .cmd)
            try c.encode(id, forKey: .id)
            try c.encode(folderID, forKey: .folderID)
        case .moveItemsToFolder(let ids, let folderID):
            try c.encode("move_items_to_folder", forKey: .cmd)
            try c.encode(ids, forKey: .ids)
            try c.encode(folderID, forKey: .folderID)
        case .downloads:
            try c.encode("downloads", forKey: .cmd)
        case .retryDownload(let id):
            try c.encode("retry_download", forKey: .cmd)
            try c.encode(id, forKey: .id)
        case .retryAllDownloads:
            try c.encode("retry_all_downloads", forKey: .cmd)
        case .setNote(let id, let note):
            try c.encode("set_note", forKey: .cmd)
            try c.encode(id, forKey: .id)
            try c.encode(note, forKey: .note)
        case .ocrPending(let limit):
            try c.encode("ocr_pending", forKey: .cmd)
            try c.encode(limit, forKey: .limit)
        case .setOCR(let id, let text):
            try c.encode("set_ocr", forKey: .cmd)
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
        case .links(let q, let limit, let offset):
            try c.encode("links", forKey: .cmd)
            try c.encode(q, forKey: .q)
            try c.encode(limit, forKey: .limit)
            try c.encode(offset, forKey: .offset)
        case .linkCounts:
            try c.encode("link_counts", forKey: .cmd)
        case .linksPage(let q, let category, let onlyDead, let limit, let offset):
            try c.encode("links_page", forKey: .cmd)
            try c.encode(q, forKey: .q)
            try c.encodeIfPresent(category, forKey: .category)
            try c.encode(onlyDead, forKey: .onlyDead)
            try c.encode(limit, forKey: .limit)
            try c.encode(offset, forKey: .offset)
        case .linkItems(let id, let limit, let offset):
            try c.encode("link_items", forKey: .cmd)
            try c.encode(id, forKey: .id)
            try c.encode(limit, forKey: .limit)
            try c.encode(offset, forKey: .offset)
        case .addLink(let url):
            try c.encode("add_link", forKey: .cmd)
            try c.encode(url, forKey: .url)
        case .deleteLink(let id):
            try c.encode("delete_link", forKey: .cmd)
            try c.encode(id, forKey: .id)
        case .enrichLinks(let limit):
            try c.encode("enrich_links", forKey: .cmd)
            try c.encode(limit, forKey: .limit)
        case .checkLinks(let limit):
            try c.encode("check_links", forKey: .cmd)
            try c.encode(limit, forKey: .limit)
        case .suggestFolders(let id, let limit):
            try c.encode("suggest_folders", forKey: .cmd)
            try c.encode(id, forKey: .id)
            try c.encode(limit, forKey: .limit)
        case .backup(let dest):
            try c.encode("backup", forKey: .cmd)
            try c.encode(dest, forKey: .dest)
        case .uiGet(let key):
            try c.encode("ui_get", forKey: .cmd)
            try c.encode(key, forKey: .key)
        case .uiSet(let key, let value):
            try c.encode("ui_set", forKey: .cmd)
            try c.encode(key, forKey: .key)
            try c.encode(value, forKey: .value)
        case .kickMedia:
            try c.encode("kick_media", forKey: .cmd)
        case .retryMedia:
            try c.encode("retry_media", forKey: .cmd)
        }
    }
}

/// Abstract client for Rust FFI commands so ViewModels can be tested hermetically.
protocol CoreClient: Sendable {
    var libraryURL: URL { get }
    func mediaURL(_ name: String) -> URL
    func ensureOpen() async -> Bool
    func call<T: Decodable & Sendable>(_ command: CoreCommand, as type: T.Type, network: Bool) async throws -> T
    func callOptional<T: Decodable & Sendable>(_ command: CoreCommand, as type: T.Type, network: Bool) async throws -> T?
    func run(_ command: CoreCommand, network: Bool) async throws
}

extension CoreClient {
    func call<T: Decodable & Sendable>(_ command: CoreCommand, as type: T.Type = T.self, network: Bool = false) async throws -> T {
        try await call(command, as: type, network: network)
    }

    func callOptional<T: Decodable & Sendable>(_ command: CoreCommand, as type: T.Type = T.self, network: Bool = false) async throws -> T? {
        try await callOptional(command, as: type, network: network)
    }

    func run(_ command: CoreCommand, network: Bool = false) async throws {
        try await run(command, network: network)
    }
}

/// Thread-safe, non-blocking bridge to the Rust core (`libwroopmark_core.a`).
///
/// Blocking C FFI (`wm_open`, `wm_call`, `wm_close`) and JSON serialization
/// execute exclusively on a bounded worker queue outside `@MainActor` and outside
/// Swift's cooperative thread pool, so long downloads or DB work cannot starve
/// UI responsiveness or task scheduling.
final class Core: CoreClient, Sendable {
    static let shared = Core()

    let libraryURL: URL

    private struct State: Sendable {
        var handleBits: UInt = 0
        var openAttempted = false
        var isOpening = false
        var isTerminating = false
        var inFlight = 0
        var openWaiters: [CheckedContinuation<Bool, Never>] = []
        var drainWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private struct Envelope<T: Decodable>: Decodable {
        let ok: Bool
        let data: T?
        let error: String?
    }

    private struct StatusEnvelope: Decodable {
        let ok: Bool
        let error: String?
    }

    private enum ContinuationGate<R: Sendable> {
        case initial
        case cancelledBeforeEnqueue
        case queued(CheckedContinuation<R, any Error>)
        case running(CheckedContinuation<R, any Error>, cancelled: Bool)
        case done
    }

    private let state = Mutex(State())
    private let workerQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.wroopmark.core"
        q.maxConcurrentOperationCount = 6
        q.qualityOfService = .userInitiated
        return q
    }()

    init(libraryURL: URL = AppPaths.defaultLibraryURL) {
        self.libraryURL = libraryURL
    }

    deinit {
        let bits = state.withLock { st -> UInt in
            st.isTerminating = true
            let b = st.handleBits
            st.handleBits = 0
            let ow = st.openWaiters
            st.openWaiters.removeAll()
            let dw = st.drainWaiters
            st.drainWaiters.removeAll()
            for w in ow { w.resume(returning: false) }
            for w in dw { w.resume() }
            return b
        }
        if let ptr = OpaquePointer(bitPattern: bits) {
            wm_close(ptr)
        }
    }

    /// Local file for a stored media name (`<hash>.<ext>` -> `media/<ab>/...`).
    func mediaURL(_ name: String) -> URL {
        libraryURL.appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(String(name.prefix(2)), isDirectory: true)
            .appendingPathComponent(name)
    }

    /// Lazily opens the Rust library off `@MainActor`, coalescing concurrent callers.
    func ensureOpen() async -> Bool {
        enum Action {
            case immediate(Bool)
            case wait
            case open
        }

        let action = state.withLock { st -> Action in
            if st.isTerminating { return .immediate(false) }
            if st.handleBits != 0 { return .immediate(true) }
            if st.isOpening { return .wait }
            if st.openAttempted { return .immediate(false) }
            st.isOpening = true
            return .open
        }

        switch action {
        case .immediate(let ok):
            return ok
        case .wait:
            return await withCheckedContinuation { cont in
                let immediate: Bool? = state.withLock { st in
                    if st.isTerminating { return false }
                    if st.handleBits != 0 { return true }
                    if st.isOpening {
                        st.openWaiters.append(cont)
                        return nil
                    }
                    return false
                }
                if let immediate { cont.resume(returning: immediate) }
            }
        case .open:
            let path = libraryURL.path
            let bits = await withCheckedContinuation { (cont: CheckedContinuation<UInt, Never>) in
                workerQueue.addOperation {
                    let handle = path.withCString { wm_open($0) }
                    cont.resume(returning: UInt(bitPattern: handle))
                }
            }

            enum Outcome {
                case normal(opened: Bool, openWaiters: [CheckedContinuation<Bool, Never>], drainWaiters: [CheckedContinuation<Void, Never>])
                case cancelledByTerminate(bitsToClose: UInt, openWaiters: [CheckedContinuation<Bool, Never>], drainWaiters: [CheckedContinuation<Void, Never>])
            }

            let outcome = state.withLock { st -> Outcome in
                st.isOpening = false
                st.openAttempted = true
                let ow = st.openWaiters
                st.openWaiters.removeAll()
                let dw = st.inFlight == 0 ? st.drainWaiters : []
                if st.inFlight == 0 { st.drainWaiters.removeAll() }
                if st.isTerminating {
                    return .cancelledByTerminate(bitsToClose: bits, openWaiters: ow, drainWaiters: dw)
                }
                st.handleBits = bits
                return .normal(opened: bits != 0, openWaiters: ow, drainWaiters: dw)
            }

            switch outcome {
            case .normal(let opened, let ow, let dw):
                for w in ow { w.resume(returning: opened) }
                for w in dw { w.resume() }
                return opened
            case .cancelledByTerminate(let bitsToClose, let ow, let dw):
                if bitsToClose != 0 {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        workerQueue.addOperation {
                            if let ptr = OpaquePointer(bitPattern: bitsToClose) {
                                wm_close(ptr)
                            }
                            cont.resume()
                        }
                    }
                }
                for w in ow { w.resume(returning: false) }
                for w in dw { w.resume() }
                return false
            }
        }
    }

    func call<T: Decodable & Sendable>(_ command: CoreCommand, as type: T.Type = T.self, network: Bool = false) async throws -> T {
        try await execute(network: network) { handleBits in
            let raw = try Self.invokeFFI(command, handleBits: handleBits)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let envelope = try decoder.decode(Envelope<T>.self, from: raw)
            guard envelope.ok else {
                throw CoreError.server(envelope.error ?? "Bilinmeyen hata")
            }
            guard let data = envelope.data else {
                throw CoreError.emptyResult
            }
            return data
        }
    }

    func callOptional<T: Decodable & Sendable>(_ command: CoreCommand, as type: T.Type = T.self, network: Bool = false) async throws -> T? {
        try await execute(network: network) { handleBits in
            let raw = try Self.invokeFFI(command, handleBits: handleBits)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let envelope = try decoder.decode(Envelope<T>.self, from: raw)
            guard envelope.ok else {
                throw CoreError.server(envelope.error ?? "Bilinmeyen hata")
            }
            return envelope.data
        }
    }

    func run(_ command: CoreCommand, network: Bool = false) async throws {
        try await execute(network: network) { handleBits in
            let raw = try Self.invokeFFI(command, handleBits: handleBits)
            let envelope = try JSONDecoder().decode(StatusEnvelope.self, from: raw)
            guard envelope.ok else {
                throw CoreError.server(envelope.error ?? "Bilinmeyen hata")
            }
        }
    }

    /// Drains any in-flight FFI calls without polling, folds SQLite WAL into
    /// `library.sqlite`, and closes the core handle safely. Idempotent.
    func checkpointForQuit() async {
        let shouldWait: Bool = state.withLock { st in
            st.isTerminating = true
            return st.inFlight > 0 || st.isOpening
        }

        if shouldWait {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let wakeImmediately = state.withLock { st -> Bool in
                    if st.inFlight == 0 && !st.isOpening {
                        return true
                    }
                    st.drainWaiters.append(cont)
                    return false
                }
                if wakeImmediately { cont.resume() }
            }
        }

        let bitsToClose = state.withLock { st -> UInt in
            let b = st.handleBits
            st.handleBits = 0
            return b
        }
        guard bitsToClose != 0 else { return }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            workerQueue.addOperation {
                if let ptr = OpaquePointer(bitPattern: bitsToClose) {
                    if let out = #"{"cmd":"checkpoint"}"#.withCString({ wm_call(ptr, $0) }) {
                        wm_free(out)
                    }
                    wm_close(ptr)
                }
                cont.resume()
            }
        }
    }

    private func execute<R: Sendable>(
        network: Bool,
        work: @escaping @Sendable (_ handleBits: UInt) throws -> R
    ) async throws -> R {
        try Task.checkCancellation()
        guard await ensureOpen() else {
            throw CoreError.libraryNotOpen
        }
        try Task.checkCancellation()

        let handleBits = try state.withLock { st -> UInt in
            guard !st.isTerminating, st.handleBits != 0 else {
                throw CoreError.libraryNotOpen
            }
            st.inFlight += 1
            return st.handleBits
        }

        let gate = Mutex<ContinuationGate<R>>(.initial)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let shouldEnqueue = gate.withLock { phase -> Bool in
                    switch phase {
                    case .initial:
                        phase = .queued(cont)
                        return true
                    case .cancelledBeforeEnqueue:
                        phase = .done
                        return false
                    case .queued, .running, .done:
                        phase = .done
                        return false
                    }
                }

                guard shouldEnqueue else {
                    decrementInFlightAndWakeDrain()
                    cont.resume(throwing: CancellationError())
                    return
                }

                let op = BlockOperation {
                    let entered = gate.withLock { phase -> Bool in
                        switch phase {
                        case .queued(let c):
                            phase = .running(c, cancelled: false)
                            return true
                        case .initial, .cancelledBeforeEnqueue, .running, .done:
                            return false
                        }
                    }
                    guard entered else { return }

                    let result: Result<R, any Error>
                    do {
                        result = .success(try work(handleBits))
                    } catch {
                        result = .failure(error)
                    }
                    self.decrementInFlightAndWakeDrain()

                    let completion = gate.withLock { phase -> (CheckedContinuation<R, any Error>, Bool)? in
                        switch phase {
                        case .running(let c, let cancelled):
                            phase = .done
                            return (c, cancelled)
                        case .initial, .cancelledBeforeEnqueue, .queued, .done:
                            phase = .done
                            return nil
                        }
                    }

                    if let (cont, cancelled) = completion {
                        if cancelled {
                            cont.resume(throwing: CancellationError())
                        } else {
                            cont.resume(with: result)
                        }
                    }
                }
                op.queuePriority = network ? .low : .normal
                op.qualityOfService = network ? .utility : .userInitiated
                workerQueue.addOperation(op)
            }
        } onCancel: {
            let queuedCont = gate.withLock { phase -> CheckedContinuation<R, any Error>? in
                switch phase {
                case .initial:
                    phase = .cancelledBeforeEnqueue
                    return nil
                case .queued(let c):
                    phase = .done
                    return c
                case .running(let c, _):
                    phase = .running(c, cancelled: true)
                    return nil
                case .cancelledBeforeEnqueue, .done:
                    return nil
                }
            }
            if let queuedCont {
                decrementInFlightAndWakeDrain()
                queuedCont.resume(throwing: CancellationError())
            }
        }
    }

    private func decrementInFlightAndWakeDrain() {
        let waiters = state.withLock { st -> [CheckedContinuation<Void, Never>] in
            st.inFlight = max(0, st.inFlight - 1)
            if st.inFlight == 0 && !st.isOpening {
                let w = st.drainWaiters
                st.drainWaiters.removeAll()
                return w
            }
            return []
        }
        for w in waiters { w.resume() }
    }

    private static func invokeFFI(_ command: CoreCommand, handleBits: UInt) throws -> Data {
        guard let ptr = OpaquePointer(bitPattern: handleBits) else {
            throw CoreError.invalidHandle
        }
        let body = try JSONEncoder().encode(command)
        guard let text = String(data: body, encoding: .utf8) else {
            throw CoreError.invalidEncoding
        }
        guard let out = text.withCString({ wm_call(ptr, $0) }) else {
            throw CoreError.noResponse
        }
        defer { wm_free(out) }
        return Data(bytes: out, count: strlen(out))
    }
}
