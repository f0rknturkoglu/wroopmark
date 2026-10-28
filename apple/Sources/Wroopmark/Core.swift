import CWroopmark
import Foundation

/// Thin bridge to the Rust core. Every call is a JSON request on a private
/// serial queue, so the main thread never waits on SQLite or the network.
final class Core: @unchecked Sendable {
    static let shared = Core()

    private let queue = DispatchQueue(label: "wroopmark.core", qos: .userInitiated)
    /// URL captures and link enrichment hit the network; they run here so
    /// browsing is not queued behind them. The core guards its own state.
    private let networkQueue = DispatchQueue(label: "wroopmark.core.network", qos: .utility, attributes: .concurrent)
    private struct Handle: @unchecked Sendable { let ptr: OpaquePointer }
    private let handle: Handle?
    /// Same directory the CLI and the browser extension's host use;
    /// `WROOPMARK_HOME` points the app at another library (testing).
    let libraryURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        libraryURL = ProcessInfo.processInfo.environment["WROOPMARK_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? support.appendingPathComponent("wroopmark", isDirectory: true)
        handle = libraryURL.path.withCString { wm_open($0) }.map(Handle.init)
    }

    deinit {
        if let handle { wm_close(handle.ptr) }
    }

    var isOpen: Bool { handle != nil }

    /// Called as the app quits: waits for the call in flight on the main
    /// queue, then folds the WAL into library.sqlite so the library on disk
    /// is a single, complete file.
    func checkpointForQuit() {
        queue.sync { [handle] in
            guard let handle, let out = #"{"cmd":"checkpoint"}"#.withCString({ wm_call(handle.ptr, $0) }) else { return }
            wm_free(out)
        }
    }

    /// Local file for a stored media name (`<hash>.<ext>` → media/<ab>/…).
    func mediaURL(_ name: String) -> URL {
        libraryURL.appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(String(name.prefix(2)), isDirectory: true)
            .appendingPathComponent(name)
    }

    struct CoreError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Envelope<T: Decodable>: Decodable {
        let ok: Bool
        let data: T?
        let error: String?
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    func call<T: Decodable>(_ request: [String: Any], as type: T.Type = T.self, network: Bool = false) async throws -> T {
        let raw = try await send(request, on: network ? networkQueue : queue)
        let envelope = try Self.decoder.decode(Envelope<T>.self, from: raw)
        guard envelope.ok, let data = envelope.data else {
            throw CoreError(message: envelope.error ?? "Bilinmeyen hata")
        }
        return data
    }

    /// For commands whose result the caller ignores.
    func run(_ request: [String: Any], network: Bool = false) async throws {
        let raw = try await send(request, on: network ? networkQueue : queue)
        let obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        guard obj?["ok"] as? Bool == true else {
            throw CoreError(message: obj?["error"] as? String ?? "Bilinmeyen hata")
        }
    }

    private func send(_ request: [String: Any], on queue: DispatchQueue) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: request)
        return try await withCheckedThrowingContinuation { cont in
            queue.async { [handle] in
                guard let handle else {
                    cont.resume(throwing: CoreError(message: "Kütüphane açılamadı"))
                    return
                }
                let text = String(decoding: body, as: UTF8.self)
                guard let out = text.withCString({ wm_call(handle.ptr, $0) }) else {
                    cont.resume(throwing: CoreError(message: "Çekirdek yanıt vermedi"))
                    return
                }
                let data = Data(bytes: out, count: strlen(out))
                wm_free(out)
                cont.resume(returning: data)
            }
        }
    }
}
