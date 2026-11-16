import CWroopmark
import Foundation
import SafariServices
import Synchronization

/// The Safari extension's native side. `browser.runtime.sendNativeMessage`
/// lands here; the request goes straight into the Rust core, which opens the
/// same library as the app and the Chromium host (SQLite WAL lets all three
/// write at once). No app has to be running.
private enum Library {
    private static let handleBits = Mutex<UInt>(0)

    /// Bounded worker queue so bursty extension requests run off the main thread
    /// without oversubscribing GCD's global pool.
    static let workerQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.wroopmark.safari.core"
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .userInitiated
        return q
    }()

    private static var libraryPath: String? {
        #if os(iOS)
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.f0rknturkoglu.wroopmark") {
            return group.appendingPathComponent("wroopmark", isDirectory: true).path
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("wroopmark", isDirectory: true).path
        #else
        guard let pw = getpwuid(getuid()) else { return nil }
        return String(cString: pw.pointee.pw_dir) + "/Library/Application Support/wroopmark"
        #endif
    }

    /// The extension is sandboxed, so `~` would be its container. On macOS
    /// the real home comes from the password database; on iOS both app and
    /// extension share an App Group container.
    private static func ensureHandle() -> OpaquePointer? {
        let bits = handleBits.withLock { current -> UInt in
            if current != 0 { return current }
            guard let path = libraryPath else { return 0 }
            #if os(iOS)
            setenv("WROOPMARK_NO_BG_MEDIA", "1", 1)
            #endif
            let opened = path.withCString { wm_open($0) }
            #if os(iOS)
            if let opened, let out = "{\"cmd\":\"set_settings\",\"download_videos\":false}".withCString({ wm_call(opened, $0) }) {
                wm_free(out)
            }
            #endif
            let openedBits = UInt(bitPattern: opened)
            current = openedBits
            return openedBits
        }
        return OpaquePointer(bitPattern: bits)
    }

    static func encodeRequest(_ request: Any?) -> Data? {
        guard let request, JSONSerialization.isValidJSONObject(request) else { return nil }
        return try? JSONSerialization.data(withJSONObject: request)
    }

    static func call(requestData: Data?) -> Any {
        guard let requestData else {
            return failure("geçersiz istek")
        }
        guard let handle = ensureHandle() else {
            return failure("wroopmark kütüphanesi açılamadı")
        }
        #if os(iOS)
        defer {
            if let paused = "{\"cmd\":\"pause\"}".withCString({ wm_call(handle, $0) }) {
                wm_free(paused)
            }
        }
        #endif
        let text = String(decoding: requestData, as: UTF8.self)
        guard let out = text.withCString({ wm_call(handle, $0) }) else {
            return failure("çekirdek yanıt vermedi")
        }
        defer { wm_free(out) }
        let data = Data(bytes: out, count: strlen(out))
        return (try? JSONSerialization.jsonObject(with: data)) ?? failure("geçersiz yanıt")
    }

    private static func failure(_ message: String) -> [String: Any] {
        ["ok": false, "error": message]
    }
}

@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        // Serialize the non-Sendable Objective-C payload synchronously before crossing threads.
        let requestData = Library.encodeRequest(item?.userInfo?[SFExtensionMessageKey])
        // Apple transfers sole ownership of the extension context to the async completion block.
        nonisolated(unsafe) let requestContext = context

        // URL captures hit the network; never block the extension's queue.
        Library.workerQueue.addOperation {
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: Library.call(requestData: requestData)]
            requestContext.completeRequest(returningItems: [response], completionHandler: nil)
        }
    }
}
