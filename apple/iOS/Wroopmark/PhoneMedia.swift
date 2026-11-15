import Foundation

/// Where a media file can be read on the phone: the library, or, for a
/// video kept on demand, the sync folder in iCloud Drive once iCloud has
/// brought it down. iOS may later remove such downloads to free space;
/// they come back the next time.
enum PhoneMedia {
    /// The sync folder the app has access to (set by `PhoneModel`).
    nonisolated(unsafe) static var syncFolder: URL?

    static func local(_ file: String) -> URL? {
        let u = Core.shared.mediaURL(file)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static func shared(_ file: String) -> URL? {
        syncFolder?.appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(String(file.prefix(2)), isDirectory: true)
            .appendingPathComponent(file)
    }

    /// A URL to play `file` from, downloading it from iCloud first when
    /// needed; nil if it is nowhere or does not come within `timeout`.
    static func playable(_ file: String, timeout: TimeInterval = 90) async -> URL? {
        if let u = local(file) { return u }
        guard let s = shared(file) else { return nil }
        return await download(s, timeout: timeout) ? s : nil
    }

    /// Starts bringing a file down without waiting (the feed's next pages).
    static func prefetch(_ file: String) {
        guard local(file) == nil, let s = shared(file) else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: s)
    }

    /// A coordinated read waits until iCloud has the file on the device.
    private static func download(_ url: URL, timeout: TimeInterval) async -> Bool {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = Once()
            NSFileCoordinator().coordinate(with: [.readingIntent(with: url, options: [])], queue: OperationQueue()) { error in
                once.run { cont.resume(returning: error == nil && FileManager.default.fileExists(atPath: url.path)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.run { cont.resume(returning: false) }
            }
        }
    }
}

/// Runs its block the first time only (a result and a timeout racing).
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ block: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { block() }
    }
}
