import CWroopmark
import Foundation

/// Thread-safe bridge to the Rust core using modern Swift concurrency.
actor Core {
    static let shared = Core()

    nonisolated let libraryURL: URL
    nonisolated let isOpen: Bool

    private let rawHandle: OpaquePointer?
    private var inFlightOperations = 0
    private var isTerminating = false

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = ProcessInfo.processInfo.environment["WROOPMARK_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? support.appendingPathComponent("wroopmark", isDirectory: true)
        self.libraryURL = url
        let handle = url.path.withCString { wm_open($0) }
        self.rawHandle = handle
        self.isOpen = (handle != nil)
    }

    deinit {
        if let rawHandle {
            wm_close(rawHandle)
        }
    }

    /// Local file for a stored media name (`<hash>.<ext>` → media/<ab>/…).
    nonisolated func mediaURL(_ name: String) -> URL {
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
        let raw = try await send(request, network: network)
        let envelope = try Self.decoder.decode(Envelope<T>.self, from: raw)
        guard envelope.ok, let data = envelope.data else {
            throw CoreError(message: envelope.error ?? "Bilinmeyen hata")
        }
        return data
    }

    /// For commands whose result the caller ignores.
    func run(_ request: [String: Any], network: Bool = false) async throws {
        let raw = try await send(request, network: network)
        let obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        guard obj?["ok"] as? Bool == true else {
            throw CoreError(message: obj?["error"] as? String ?? "Bilinmeyen hata")
        }
    }

    /// Called as the app quits: drains any active in-flight calls, then folds
    /// the WAL into library.sqlite so the library on disk is a single, complete file.
    func checkpointForQuit() async {
        guard let rawHandle, !isTerminating else { return }
        isTerminating = true
        while inFlightOperations > 0 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let handleBitPattern = UInt(bitPattern: rawHandle)
        await Task.detached(priority: .userInitiated) {
            guard let ptr = OpaquePointer(bitPattern: handleBitPattern) else { return }
            let out = #"{"cmd":"checkpoint"}"#.withCString { wm_call(ptr, $0) }
            if let out { wm_free(out) }
        }.value
    }

    private func send(_ request: [String: Any], network: Bool) async throws -> Data {
        guard let rawHandle, !isTerminating else {
            throw CoreError(message: "Kütüphane açık değil")
        }
        inFlightOperations += 1
        defer { inFlightOperations -= 1 }

        let body = try JSONSerialization.data(withJSONObject: request)
        let handleBitPattern = UInt(bitPattern: rawHandle)

        return try await Task.detached(priority: network ? .utility : .userInitiated) {
            guard let ptr = OpaquePointer(bitPattern: handleBitPattern) else {
                throw CoreError(message: "Geçersiz tutamaç")
            }
            let text = String(decoding: body, as: UTF8.self)
            guard let out = text.withCString({ wm_call(ptr, $0) }) else {
                throw CoreError(message: "Çekirdek yanıt vermedi")
            }
            defer { wm_free(out) }
            return Data(bytes: out, count: strlen(out))
        }.value
    }
}
