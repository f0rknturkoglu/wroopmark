import CWroopmark
import Foundation
import SafariServices

/// The Safari extension's native side. `browser.runtime.sendNativeMessage`
/// lands here; the request goes straight into the Rust core, which opens the
/// same library as the app and the Chromium host (SQLite WAL lets all three
/// write at once). No app has to be running.
private enum Library {
    /// The extension is sandboxed, so `~` would be its container. The real
    /// home comes from the password database; the entitlements grant access
    /// to the library folder inside it.
    static let handle: OpaquePointer? = {
        guard let pw = getpwuid(getuid()) else { return nil }
        let path = String(cString: pw.pointee.pw_dir) + "/Library/Application Support/wroopmark"
        return path.withCString { wm_open($0) }
    }()

    private static let lock = NSLock()

    static func call(_ request: Any?) -> Any {
        guard let handle else { return failure("wroopmark kütüphanesi açılamadı") }
        guard let request, JSONSerialization.isValidJSONObject(request),
              let body = try? JSONSerialization.data(withJSONObject: request) else {
            return failure("geçersiz istek")
        }
        lock.lock()
        defer { lock.unlock() }
        let text = String(decoding: body, as: UTF8.self)
        guard let out = text.withCString({ wm_call(handle, $0) }) else { return failure("çekirdek yanıt vermedi") }
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
        let message = item?.userInfo?[SFExtensionMessageKey]
        // URL captures hit the network; never block the extension's queue.
        DispatchQueue.global(qos: .userInitiated).async {
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: Library.call(message)]
            context.completeRequest(returningItems: [response], completionHandler: nil)
        }
    }
}
