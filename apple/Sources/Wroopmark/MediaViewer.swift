import AppKit
import AVKit
import SwiftUI
import VisionKit

/// What the Mac viewer/feed remembers locally: where each video was left and
/// which ones reached 90% watched.
@MainActor
enum MacFeedMemory {
    private static let positionsKey = "macFeedPositions"
    private static let watchedKey = "macFeedWatched"
    private static var positions: [String: Double] = UserDefaults.standard.dictionary(forKey: positionsKey) as? [String: Double] ?? [:]
    private(set) static var watched: Set<String> = Set(UserDefaults.standard.stringArray(forKey: watchedKey) ?? [])

    static func position(_ key: String) -> Double? { positions[key] }

    static func remember(_ key: String, at seconds: Double, of duration: Double) {
        if seconds > 3 && duration > 0 && seconds < duration - 3 {
            positions[key] = seconds
        } else {
            positions[key] = nil
        }
        if positions.count > 500 { positions.removeValue(forKey: positions.keys.first ?? "") }
        UserDefaults.standard.set(positions, forKey: positionsKey)
    }

    static func markWatched(_ key: String) {
        guard watched.insert(key).inserted else { return }
        var list = UserDefaults.standard.stringArray(forKey: watchedKey) ?? []
        list.append(key)
        if list.count > 5000 { list.removeFirst(list.count - 5000) }
        UserDefaults.standard.set(list, forKey: watchedKey)
    }

    static func forgetWatched() {
        watched = []
        UserDefaults.standard.removeObject(forKey: watchedKey)
    }
}

/// Full-size images and offline video playback, entirely from the media
/// store, as a lightbox over the window: a click on the dark backdrop (or
/// Esc) closes it, ← → move within the post, ↑ ↓ move across posts.
struct MediaViewer: View {
    @Environment(AppModel.self) private var model
    let viewer: Viewer
    /// The outside tools failed and the browser extension is on it.
    @State private var viaBrowser = false
    /// The video's own shape, read from the file; the player is sized to it
    /// so the area around a portrait video is backdrop, not player.
    @State private var videoAspect: CGFloat?
    @State private var copied = false
    @AppStorage("macVideoRate") private var playbackRate: Double = 1.0

    private static let rateOptions: [Double] = [1.0, 1.25, 1.5, 2.0]
    private let arrowSize: CGFloat = 44
    private var arrowClearance: CGFloat { Theme.Spacing.lg + arrowSize + Theme.Spacing.md }
    private let thumbSize: CGFloat = 56

    private var media: Media? {
        guard !viewer.media.isEmpty else { return nil }
        return viewer.media.indices.contains(viewer.index) ? viewer.media[viewer.index] : viewer.media.first
    }

    private var rateLabel: String {
        playbackRate == floor(playbackRate) ? "\(Int(playbackRate))×" : String(format: "%.2g×", playbackRate)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.88)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Görüntüleyiciyi kapat")

            VStack(spacing: 0) {
                topBar
                ZStack {
                    content
                        .padding(.horizontal, arrowClearance)
                        .padding(.vertical, Theme.Spacing.sm)
                    arrows
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if viewer.media.count > 1 { strip }
            }
        }
        .environment(\.colorScheme, .dark)
        .onChange(of: viewer.index) { _, _ in viaBrowser = false }
        .onChange(of: viewer.ownerID) { _, _ in viaBrowser = false }
        .task(id: media?.videoFile) {
            videoAspect = nil
            guard let file = media?.videoFile else { return }
            videoAspect = await LocalVideo.aspect(of: Core.shared.mediaURL(file))
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let media {
            if media.isVideo, let file = media.videoFile {
                LocalVideo(
                    url: Core.shared.mediaURL(file),
                    loops: true,
                    rate: Float(playbackRate),
                    memoryKey: file
                )
                    .id(file)
                    .aspectRatio(videoAspect ?? media.aspect ?? 9.0 / 16.0, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: Theme.Radius.sm))
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
            } else if let file = media.file, !media.isVideo {
                ZoomableMacImage(file: file, aspect: media.aspect)
                    .id(file)
                    .aspectRatio(media.aspect, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: Theme.Radius.sm))
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
            } else if let file = media.file {
                LocalImage(file: file, maxPixel: 3200, contentMode: .fit, placeholder: false)
                    .id(file)
                    .aspectRatio(media.aspect, contentMode: .fit)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
                    .overlay { notDownloaded(for: media) }
            } else {
                notDownloaded(for: media)
            }
        }
    }

    /// A video behind a post page (TikTok): yt-dlp / gallery-dl fetch it,
    /// and if they cannot, the post is loaded in the browser behind this
    /// window for the extension; it plays here as soon as it arrives.
    private func isPageVideo(_ media: Media) -> Bool {
        media.isVideo && !media.canDownloadVideo
    }

    private func notDownloaded(for media: Media) -> some View {
        let pageVideo = isPageVideo(media)
        return VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.largeTitle)
                .foregroundStyle(.white.opacity(0.85))
            Text(model.isBusy ? "İndiriliyor…" : viaBrowser ? "Tarayıcıyla indiriliyor…" : "Henüz indirilmedi")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
            if viaBrowser {
                Text("İndirici başaramadı; gönderi tarayıcıda arka planda açıldı, video gelince burada oynar.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            if (media.canDownloadVideo || media.file == nil || pageVideo) && !viaBrowser {
                Button {
                    Task {
                        let done = await model.downloadMedia(viewer.ownerID, browserFallback: pageVideo ? viewer.postURL : nil)
                        if !done && pageVideo { viaBrowser = true }
                    }
                } label: {
                    Label("İndir", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(model.isBusy)
            }
            if model.isBusy || viaBrowser { ProgressView().controlSize(.small) }
        }
        .padding(Theme.Spacing.xl)
        .background(.black.opacity(0.7), in: .rect(cornerRadius: Theme.Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(Theme.Stroke.darkOverlayBorder, lineWidth: Theme.Stroke.hairlineWidth)
        }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(spacing: Theme.Spacing.md) {
            if viewer.media.count > 1 {
                Text("\(viewer.index + 1) / \(viewer.media.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(.white.opacity(0.12), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(Theme.Stroke.darkOverlayBorder, lineWidth: Theme.Stroke.hairlineWidth)
                    }
            }
            if !viewer.title.isEmpty {
                Text(viewer.title)
                    .lineLimit(1)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
            } else if let alt = media?.alt, !alt.isEmpty {
                Text(alt)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            if copied {
                Label("Panoya kopyalandı", systemImage: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(Theme.accent, in: Capsule())
                    .transition(.opacity)
            }
            Spacer(minLength: Theme.Spacing.md)
            GlassEffectContainer(spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.sm) {
                    if media?.isVideo == true, media?.videoFile != nil {
                        Button(action: cycleRate) {
                            Text(rateLabel)
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, Theme.Spacing.sm)
                                .frame(height: 32)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .help("Oynatma hızı")
                        .accessibilityLabel("Oynatma hızı \(rateLabel)")
                    }
                    if model.canStepViewerItem(-1) || model.canStepViewerItem(1) {
                        chromeButton("chevron.up", label: String(localized: "Önceki gönderi (↑)")) {
                            model.stepViewerItem(-1)
                        }
                        .disabled(!model.canStepViewerItem(-1))
                        .opacity(model.canStepViewerItem(-1) ? 1 : 0.4)

                        chromeButton("chevron.down", label: String(localized: "Sonraki gönderi (↓)")) {
                            model.stepViewerItem(1)
                        }
                        .disabled(!model.canStepViewerItem(1))
                        .opacity(model.canStepViewerItem(1) ? 1 : 0.4)
                    }
                    if let file = media?.videoFile ?? media?.file {
                        chromeButton("doc.on.doc", label: String(localized: "Panoya kopyala (⌘C)"), action: copyCurrentMedia)
                            .keyboardShortcut("c", modifiers: .command)
                        MacShareButton(url: Core.shared.mediaURL(file))
                        chromeButton("folder", label: String(localized: "Finder'da göster")) {
                            NSWorkspace.shared.activateFileViewerSelecting([Core.shared.mediaURL(file)])
                        }
                    }
                    if let url = URL(string: viewer.postURL), url.scheme?.hasPrefix("http") == true {
                        chromeButton("arrow.up.right.square", label: String(localized: "Kaynağında aç")) { NSWorkspace.shared.open(url) }
                    }
                    chromeButton("xmark", label: String(localized: "Kapat (Esc)"), action: close)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.xs)
    }

    private var arrows: some View {
        HStack {
            arrow("chevron.left", label: String(localized: "Önceki medya"), enabled: viewer.index > 0) { move(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Spacer()
            arrow("chevron.right", label: String(localized: "Sonraki medya"), enabled: viewer.index < viewer.media.count - 1) { move(1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    /// Thumbnails of every medium in the post; the current one is outlined.
    private var strip: some View {
        // Centered while it fits, scrolling once a post has more media than
        // the window is wide.
        GeometryReader { geo in
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(Array(viewer.media.enumerated()), id: \.offset) { i, m in
                        Button { go(to: i) } label: {
                            Color.clear
                                .frame(width: thumbSize, height: thumbSize)
                                .overlay {
                                    if let file = m.file {
                                        LocalImage(file: file, maxPixel: 160)
                                    } else {
                                        Rectangle().fill(.white.opacity(0.08))
                                    }
                                }
                                .overlay(alignment: .bottomTrailing) {
                                    if m.isVideo {
                                        Image(systemName: "play.fill")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                            .padding(Theme.Spacing.xs)
                                            .background(.black.opacity(0.65), in: Circle())
                                            .padding(Theme.Spacing.xs)
                                    }
                                }
                                .clipShape(.rect(cornerRadius: Theme.Radius.sm))
                                .overlay {
                                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                        .strokeBorder(
                                            i == viewer.index ? Color.white : .white.opacity(0.14),
                                            lineWidth: i == viewer.index ? Theme.Stroke.selectionWidth : Theme.Stroke.hairlineWidth
                                        )
                                }
                                .opacity(i == viewer.index ? 1 : 0.6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Medya \(i + 1)")
                        .id(i)
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
                .frame(minWidth: geo.size.width)
            }
            .onChange(of: viewer.index) { _, i in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(i, anchor: .center) }
            }
        }
        }
        .frame(height: thumbSize + Theme.Spacing.md * 2)
    }

    private func chromeButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(label)
        .accessibilityLabel(label)
    }

    private func arrow(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: arrowSize, height: arrowSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: Actions

    private func close() { model.viewer = nil }

    private func move(_ step: Int) { go(to: viewer.index + step) }

    private func go(to index: Int) {
        guard var v = model.viewer, v.media.indices.contains(index), index != v.index else { return }
        v.index = index
        model.viewer = v
    }

    private func cycleRate() {
        let idx = Self.rateOptions.firstIndex(where: { abs($0 - playbackRate) < 0.05 }) ?? 0
        playbackRate = Self.rateOptions[(idx + 1) % Self.rateOptions.count]
    }

    private func copyCurrentMedia() {
        guard let file = media?.videoFile ?? media?.file else { return }
        let fileURL = Core.shared.mediaURL(file)
        let pb = NSPasteboard.general
        pb.clearContents()
        if media?.isVideo != true, let img = NSImage(contentsOf: fileURL) {
            pb.writeObjects([img])
        } else {
            pb.writeObjects([fileURL as NSURL])
        }
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.2)) { copied = false }
        }
    }
}

/// Share sheet trigger using AppKit's native sharing picker (AirDrop, Messages, Photos, Notes).
private struct MacShareButton: NSViewRepresentable {
    let url: URL

    @MainActor
    final class Coordinator: NSObject {
        var url: URL
        init(url: URL) { self.url = url }

        @objc func share(_ sender: NSButton) {
            let picker = NSSharingServicePicker(items: [url])
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeNSView(context: Context) -> NSButton {
        let btn = NSButton(
            image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: String(localized: "Paylaş")) ?? NSImage(),
            target: context.coordinator,
            action: #selector(Coordinator.share(_:))
        )
        btn.bezelStyle = .glass
        btn.controlSize = .regular
        btn.toolTip = String(localized: "Paylaş")
        return btn
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.url = url
    }
}

/// Zoomable image view (pinch + double click) with macOS Live Text overlay.
private struct ZoomableMacImage: NSViewRepresentable {
    let file: String
    let aspect: CGFloat?

    @MainActor
    final class MagnifyingScrollView: NSScrollView {
        override func layout() {
            super.layout()
            if magnification <= 1.01, let doc = documentView {
                doc.frame = contentView.bounds
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        let imageView = NSImageView()
        let overlay = ImageAnalysisOverlayView()
        var currentFile = ""
        var analyzeTask: Task<Void, Never>?

        override init() {
            super.init()
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.imageAlignment = .alignCenter
            imageView.autoresizingMask = [.width, .height]

            overlay.trackingImageView = imageView
            overlay.preferredInteractionTypes = [.textSelection, .dataDetectors]
            overlay.autoresizingMask = [.width, .height]
        }

        @objc func doubleClick(_ sender: NSClickGestureRecognizer) {
            guard let scroll = sender.view as? NSScrollView else { return }
            let target: CGFloat = scroll.magnification > 1.05 ? 1.0 : 2.5
            let point = sender.location(in: scroll.documentView ?? scroll)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                scroll.animator().setMagnification(target, centeredAt: point)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MagnifyingScrollView {
        let scroll = MagnifyingScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.allowsMagnification = true
        scroll.minMagnification = 1.0
        scroll.maxMagnification = 5.0

        let container = NSView(frame: scroll.bounds)
        container.autoresizingMask = [.width, .height]
        let iv = context.coordinator.imageView
        iv.frame = container.bounds
        container.addSubview(iv)

        let ov = context.coordinator.overlay
        ov.frame = iv.bounds
        iv.addSubview(ov)

        scroll.documentView = container

        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleClick(_:)))
        click.numberOfClicksRequired = 2
        scroll.addGestureRecognizer(click)
        return scroll
    }

    func updateNSView(_ scroll: MagnifyingScrollView, context: Context) {
        guard context.coordinator.currentFile != file else { return }
        context.coordinator.currentFile = file
        context.coordinator.analyzeTask?.cancel()
        context.coordinator.overlay.analysis = nil
        scroll.magnification = 1.0

        let url = Core.shared.mediaURL(file)
        if let hit = Thumbnails.shared.cached(file: file, maxPixel: 3200) {
            context.coordinator.imageView.image = hit
        }
        context.coordinator.analyzeTask = Task {
            let full: NSImage? = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: url)
            }.value
            guard !Task.isCancelled else { return }
            let img = full ?? context.coordinator.imageView.image
            if let full { context.coordinator.imageView.image = full }
            guard let img, ImageAnalyzer.isSupported else { return }
            let analyzer = ImageAnalyzer()
            let config = ImageAnalyzer.Configuration([.text, .machineReadableCode])
            if let analysis = try? await analyzer.analyze(img, orientation: .up, configuration: config),
               !Task.isCancelled {
                context.coordinator.overlay.analysis = analysis
            }
        }
    }
}

/// Inline player sized to the video, so a landscape clip has no tall black
/// bars. It pauses itself while the lightbox is open so two copies never
/// play at once.
struct InlineVideoPlayer: View {
    @Environment(AppModel.self) private var model
    let file: String
    var alt: String? = nil
    var aspect: CGFloat? = nil
    var maxHeight: CGFloat = 380
    var autoplay = false
    @State private var fileAspect: CGFloat?

    var body: some View {
        LocalVideo(url: Core.shared.mediaURL(file), autoplay: autoplay, controlsStyle: .inline, paused: model.viewer != nil)
            .aspectRatio(fileAspect ?? aspect ?? 16.0 / 9.0, contentMode: .fit)
            .frame(maxHeight: maxHeight)
            .background(Color.black)
            .clipShape(.rect(cornerRadius: Theme.Radius.sm))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .strokeBorder(Theme.Stroke.surfaceBorder, lineWidth: Theme.Stroke.hairlineWidth)
            }
            .frame(maxWidth: .infinity)
            .task(id: file) { fileAspect = await LocalVideo.aspect(of: Core.shared.mediaURL(file)) }
    }
}

/// AppKit's own player view. SwiftUI's `VideoPlayer` lives in the
/// `_AVKit_SwiftUI` overlay, which aborts at runtime when built with the
/// Command Line Tools; `AVPlayerView` has no such overlay and also brings
/// the QuickTime controls, full screen and picture in picture.
struct LocalVideo: NSViewRepresentable {
    let url: URL
    var autoplay = true
    var isMuted = false
    var loops = false
    var rate: Float = 1.0
    var memoryKey: String? = nil
    var controlsStyle: AVPlayerViewControlsStyle = .floating
    /// While true the player is held paused (it does not resume by itself).
    var paused = false

    @MainActor
    final class Coordinator {
        nonisolated(unsafe) var loopObserver: NSObjectProtocol?
        var timeObserver: Any?
        weak var observedPlayer: AVPlayer?
        var memoryKey: String?
        var duration: Double = 0
        var activeRate: Float = 1.0

        @MainActor
        func stop() {
            if let key = memoryKey, let p = observedPlayer, duration > 0 {
                MacFeedMemory.remember(key, at: p.currentTime().seconds, of: duration)
            }
            if let timeObserver, let p = observedPlayer {
                p.removeTimeObserver(timeObserver)
            }
            timeObserver = nil
            observedPlayer = nil
            memoryKey = nil
            duration = 0
            if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
            loopObserver = nil
        }

        @MainActor
        func watch(player: AVPlayer, loops: Bool, memoryKey: String?, rate: Float) {
            stop()
            self.memoryKey = memoryKey
            self.observedPlayer = player
            self.activeRate = rate
            if loops, let item = player.currentItem {
                loopObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
                ) { [weak player, weak self] _ in
                    Task { @MainActor in
                        let r = self?.activeRate ?? 1.0
                        player?.seek(to: .zero)
                        player?.play()
                        player?.rate = r
                    }
                }
            }
            guard let memoryKey else { return }
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self, weak player] t in
                MainActor.assumeIsolated {
                    guard let self, let player, let item = player.currentItem else { return }
                    let d = item.duration.seconds
                    guard d.isFinite, d > 0 else { return }
                    self.duration = d
                    if t.seconds / d >= 0.9 {
                        MacFeedMemory.markWatched(memoryKey)
                    }
                }
            }
        }

        deinit {
            if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = controlsStyle
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        // Live Text analysis of paused frames: costly, and its overlay takes
        // clicks meant for the controls around the player.
        view.allowsVideoFrameAnalysis = false
        attach(url, to: view, context: context)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard let player = view.player, (player.currentItem?.asset as? AVURLAsset)?.url == url else {
            view.player?.pause()
            attach(url, to: view, context: context)
            return
        }
        context.coordinator.activeRate = rate
        player.defaultRate = rate
        if player.isMuted != isMuted { player.isMuted = isMuted }
        if paused {
            if player.rate != 0 { player.pause() }
        } else if player.rate > 0, abs(player.rate - rate) > 0.01 {
            player.rate = rate
        }
    }

    private func attach(_ url: URL, to view: AVPlayerView, context: Context) {
        let player = AVPlayer(url: url)
        player.isMuted = isMuted
        player.defaultRate = rate
        player.actionAtItemEnd = loops ? .none : .pause
        view.player = player
        context.coordinator.watch(player: player, loops: loops, memoryKey: memoryKey, rate: rate)
        if let memoryKey, let at = MacFeedMemory.position(memoryKey) {
            player.seek(to: CMTime(seconds: at, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if autoplay && !paused {
            player.play()
            player.rate = rate
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
        coordinator.stop()
        view.player = nil
    }

    /// Width over height of the file's video track as displayed (rotation
    /// applied), nil when it cannot be read.
    static func aspect(of url: URL) async -> CGFloat? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let loaded = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let shown = loaded.0.applying(loaded.1)
        let w = abs(shown.width), h = abs(shown.height)
        return w > 0 && h > 0 ? w / h : nil
    }
}
