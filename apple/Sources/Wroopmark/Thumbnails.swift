import AppKit
import ImageIO
import SwiftUI
import Synchronization

/// Downsampled images from the media store.
///
/// The cache lives on `@MainActor`, so a cell scrolling back into view displays
/// its picture in the first frame without flashing a placeholder. ImageIO
/// decoding runs off the main thread on a bounded queue, disables ImageIO's
/// redundant backing cache (`kCGImageSourceShouldCache: false`), keeps grid
/// thumbnails separate from full-resolution lightbox images, and clears buffers
/// on memory pressure or view disappearance.
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()

    static let fullSizePixelThreshold = 1000

    private let thumbnailCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 64 << 20
        c.countLimit = 400
        return c
    }()

    private let fullSizeCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 64 << 20
        c.countLimit = 4
        return c
    }()

    private let mediaURL: @Sendable (String) -> URL
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    private var hideObserver: NSObjectProtocol?

    private nonisolated let decodeQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.wroopmark.thumbnails"
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .userInitiated
        return q
    }()

    private enum DecodePhase: @unchecked Sendable {
        case initial
        case cancelledBeforeEnqueue
        case queued(CheckedContinuation<CGImage?, Never>)
        case running(CheckedContinuation<CGImage?, Never>, cancelled: Bool)
        case done
    }

    init(
        mediaURL: @escaping @Sendable (String) -> URL = { Core.shared.mediaURL($0) },
        observeSystemNotifications: Bool = true
    ) {
        self.mediaURL = mediaURL
        guard observeSystemNotifications else { return }

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            self.handleMemoryPressure(source.data)
        }
        source.resume()
        self.memoryPressureSource = source

        self.hideObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.clearFullSizeCache()
            }
        }
    }

    isolated deinit {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        if let hideObserver {
            NotificationCenter.default.removeObserver(hideObserver)
        }
        hideObserver = nil
    }

    private static func key(_ file: String, _ maxPixel: Int) -> NSString { "\(file)@\(maxPixel)" as NSString }

    private func targetCache(for maxPixel: Int) -> NSCache<NSString, NSImage> {
        maxPixel > Self.fullSizePixelThreshold ? fullSizeCache : thumbnailCache
    }

    func cached(file: String, maxPixel: Int) -> NSImage? {
        targetCache(for: maxPixel).object(forKey: Self.key(file, maxPixel))
    }

    func clearFullSizeCache() {
        fullSizeCache.removeAllObjects()
    }

    func clearAllCaches() {
        fullSizeCache.removeAllObjects()
        thumbnailCache.removeAllObjects()
    }

    func handleMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
        fullSizeCache.removeAllObjects()
        if event.contains(.critical) {
            thumbnailCache.removeAllObjects()
        } else if event.contains(.warning) {
            // Keep the grid responsive under pressure instead of immediately
            // restoring the old limit (which made the warning a no-op).
            thumbnailCache.countLimit = 100
        }
    }

    func image(file: String, maxPixel: Int) async -> NSImage? {
        let clampedPixel = max(1, maxPixel)
        let key = Self.key(file, clampedPixel)
        let cache = targetCache(for: clampedPixel)
        if let hit = cache.object(forKey: key) { return hit }
        guard !Task.isCancelled else { return nil }
        let url = mediaURL(file)
        guard let cg = await Self.decode(url: url, maxPixel: clampedPixel, on: decodeQueue), !Task.isCancelled else {
            return nil
        }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key, cost: cg.width * cg.height * 4)
        return image
    }

    nonisolated static func downsample(url: URL, maxPixel: Int) -> CGImage? {
        autoreleasepool {
            let sourceOptions: [CFString: Any] = [
                kCGImageSourceShouldCache: false,
            ]
            guard let src = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
                return nil
            }
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions as CFDictionary)
        }
    }

    private nonisolated static func decode(url: URL, maxPixel: Int, on queue: OperationQueue) async -> CGImage? {
        let gate = Mutex<DecodePhase>(.initial)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
                let shouldEnqueue = gate.withLock { phase -> Bool in
                    switch phase {
                    case .initial:
                        phase = .queued(cont)
                        return true
                    case .cancelledBeforeEnqueue, .queued, .running, .done:
                        phase = .done
                        return false
                    }
                }
                guard shouldEnqueue else {
                    cont.resume(returning: nil)
                    return
                }
                queue.addOperation {
                    let entered = gate.withLock { phase -> Bool in
                        switch phase {
                        case .queued(let c):
                            phase = .running(c, cancelled: false)
                            return true
                        default:
                            return false
                        }
                    }
                    guard entered else { return }

                    let decoded = Self.downsample(url: url, maxPixel: maxPixel)

                    let contToResume = gate.withLock { phase -> (CheckedContinuation<CGImage?, Never>, Bool)? in
                        switch phase {
                        case .running(let c, let cancelled):
                            phase = .done
                            return (c, cancelled)
                        default:
                            phase = .done
                            return nil
                        }
                    }
                    if let (c, cancelled) = contToResume {
                        c.resume(returning: cancelled ? nil : decoded)
                    }
                }
            }
        } onCancel: {
            let queued = gate.withLock { phase -> CheckedContinuation<CGImage?, Never>? in
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
            queued?.resume(returning: nil)
        }
    }
}

/// A local media file, filled to its frame.
struct LocalImage: View, Equatable {
    let file: String
    var maxPixel = 480
    var contentMode: ContentMode = .fill
    /// Grey box while loading; off where the backdrop should show through.
    var placeholder = true
    @State private var image: NSImage?

    nonisolated static func == (lhs: LocalImage, rhs: LocalImage) -> Bool {
        lhs.file == rhs.file
            && lhs.maxPixel == rhs.maxPixel
            && lhs.contentMode == rhs.contentMode
            && lhs.placeholder == rhs.placeholder
    }

    init(file: String, maxPixel: Int = 480, contentMode: ContentMode = .fill, placeholder: Bool = true) {
        self.file = file
        self.maxPixel = maxPixel
        self.contentMode = contentMode
        self.placeholder = placeholder
        _image = State(initialValue: Thumbnails.shared.cached(file: file, maxPixel: maxPixel))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
            } else if placeholder {
                Rectangle().fill(.quaternary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .onAppear {
            if image == nil, let hit = Thumbnails.shared.cached(file: file, maxPixel: maxPixel) {
                image = hit
            }
        }
        .onDisappear {
            image = nil
        }
        .task(id: "\(file)@\(maxPixel)") {
            if let hit = Thumbnails.shared.cached(file: file, maxPixel: maxPixel) {
                if hit !== image { image = hit }
                return
            }
            image = nil
            image = await Thumbnails.shared.image(file: file, maxPixel: maxPixel)
        }
    }
}
