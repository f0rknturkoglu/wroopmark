import AVKit
import SwiftUI

/// Full-size images and offline video playback, entirely from the media
/// store, as a lightbox over the window: a click on the dark backdrop (or
/// Esc) closes it, ← → move, the strip at the bottom jumps.
struct MediaViewer: View {
    @Environment(AppModel.self) private var model
    let viewer: Viewer
    /// The outside tools failed and the browser extension is on it.
    @State private var viaBrowser = false
    /// The video's own shape, read from the file; the player is sized to it
    /// so the area around a portrait video is backdrop, not player.
    @State private var videoAspect: CGFloat?

    private let arrowSize: CGFloat = 44
    private var arrowClearance: CGFloat { Theme.Spacing.lg + arrowSize + Theme.Spacing.md }
    private let thumbSize: CGFloat = 56

    private var media: Media? {
        guard !viewer.media.isEmpty else { return nil }
        return viewer.media.indices.contains(viewer.index) ? viewer.media[viewer.index] : viewer.media.first
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
                LocalVideo(url: Core.shared.mediaURL(file), loops: true)
                    .id(file)
                    .aspectRatio(videoAspect ?? media.aspect ?? 9.0 / 16.0, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: Theme.Radius.sm))
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
            } else if let file = media.file {
                LocalImage(file: file, maxPixel: 3200, contentMode: .fit, placeholder: false)
                    .id(file)
                    .aspectRatio(media.aspect, contentMode: .fit)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
                    .overlay {
                        if media.isVideo { notDownloaded(for: media) }
                    }
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
            if let alt = media?.alt, !alt.isEmpty {
                Text(alt)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            Spacer(minLength: Theme.Spacing.md)
            GlassEffectContainer(spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.sm) {
                    if let file = media?.videoFile ?? media?.file {
                        chromeButton("folder", label: "Finder'da göster") {
                            NSWorkspace.shared.activateFileViewerSelecting([Core.shared.mediaURL(file)])
                        }
                    }
                    if let url = URL(string: viewer.postURL) {
                        chromeButton("arrow.up.right.square", label: "Kaynağında aç") { NSWorkspace.shared.open(url) }
                    }
                    chromeButton("xmark", label: "Kapat (Esc)", action: close)
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
            arrow("chevron.left", label: "Önceki medya", enabled: viewer.index > 0) { move(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Spacer()
            arrow("chevron.right", label: "Sonraki medya", enabled: viewer.index < viewer.media.count - 1) { move(1) }
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
    var controlsStyle: AVPlayerViewControlsStyle = .floating
    /// While true the player is held paused (it does not resume by itself).
    var paused = false

    final class Coordinator {
        var loopObserver: NSObjectProtocol?

        func stop() {
            if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
            loopObserver = nil
        }

        func watchEnd(of player: AVPlayer, loops: Bool) {
            stop()
            guard loops, let item = player.currentItem else { return }
            loopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak player] _ in
                player?.seek(to: .zero)
                player?.play()
            }
        }

        deinit { stop() }
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
        if player.isMuted != isMuted { player.isMuted = isMuted }
        if paused && player.rate != 0 { player.pause() }
    }

    private func attach(_ url: URL, to view: AVPlayerView, context: Context) {
        let player = AVPlayer(url: url)
        player.isMuted = isMuted
        player.actionAtItemEnd = loops ? .none : .pause
        view.player = player
        context.coordinator.watchEnd(of: player, loops: loops)
        if autoplay && !paused { player.play() }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
        view.player = nil
        coordinator.stop()
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
