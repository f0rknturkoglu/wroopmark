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

    private var media: Media { viewer.media[viewer.index] }

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
                        .padding(.horizontal, 72)
                        .padding(.vertical, 8)
                    arrows
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if viewer.media.count > 1 { strip }
            }
        }
        .environment(\.colorScheme, .dark)
        .onChange(of: viewer.index) { _, _ in viaBrowser = false }
        .task(id: media.videoFile) {
            videoAspect = nil
            guard let file = media.videoFile else { return }
            videoAspect = await LocalVideo.aspect(of: Core.shared.mediaURL(file))
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if media.isVideo, let file = media.videoFile {
            LocalVideo(url: Core.shared.mediaURL(file), loops: true)
                .id(file)
                .aspectRatio(videoAspect ?? media.aspect ?? 9.0 / 16.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        } else if let file = media.file {
            LocalImage(file: file, maxPixel: 3200, contentMode: .fit, placeholder: false)
                .id(file)
                .aspectRatio(media.aspect, contentMode: .fit)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
                .overlay {
                    if media.isVideo { notDownloaded }
                }
        } else {
            notDownloaded
        }
    }

    /// A video behind a post page (TikTok): yt-dlp / gallery-dl fetch it,
    /// and if they cannot, the post is loaded in the browser behind this
    /// window for the extension; it plays here as soon as it arrives.
    private var pageVideo: Bool { media.isVideo && !media.canDownloadVideo }

    private var notDownloaded: some View {
        VStack(spacing: 12) {
            Image(systemName: "icloud.and.arrow.down").font(.system(size: 34)).foregroundStyle(.white.opacity(0.85))
            Text(model.isBusy ? "İndiriliyor…" : viaBrowser ? "Tarayıcıyla indiriliyor…" : "Henüz indirilmedi")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            if viaBrowser {
                Text("İndirici başaramadı; gönderi tarayıcıda arka planda açıldı, video gelince burada oynar.")
                    .font(.caption).foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            if (media.canDownloadVideo || media.file == nil || pageVideo) && !viaBrowser {
                Button("İndir") {
                    Task {
                        let done = await model.downloadMedia(viewer.ownerID, browserFallback: pageVideo ? viewer.postURL : nil)
                        if !done && pageVideo { viaBrowser = true }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
            }
            if model.isBusy || viaBrowser { ProgressView().controlSize(.small) }
        }
        .padding(24)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(spacing: 10) {
            if viewer.media.count > 1 {
                Text("\(viewer.index + 1) / \(viewer.media.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.white.opacity(0.12), in: Capsule())
            }
            if let alt = media.alt, !alt.isEmpty {
                Text(alt).lineLimit(1).font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 12)
            if let file = media.videoFile ?? media.file {
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
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var arrows: some View {
        HStack {
            arrow("chevron.left", label: "Önceki medya", enabled: viewer.index > 0) { move(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Spacer()
            arrow("chevron.right", label: "Sonraki medya", enabled: viewer.index < viewer.media.count - 1) { move(1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .padding(.horizontal, 16)
    }

    /// Thumbnails of every medium in the post; the current one is outlined.
    private var strip: some View {
        // Centered while it fits, scrolling once a post has more media than
        // the window is wide.
        GeometryReader { geo in
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(viewer.media.enumerated()), id: \.offset) { i, m in
                        Button { go(to: i) } label: {
                            Color.clear
                                .frame(width: 52, height: 52)
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
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(.white)
                                            .padding(3)
                                            .background(.black.opacity(0.6), in: Circle())
                                            .padding(3)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(i == viewer.index ? Color.white : .white.opacity(0.12), lineWidth: i == viewer.index ? 2 : 1)
                                )
                                .opacity(i == viewer.index ? 1 : 0.6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Medya \(i + 1)")
                        .id(i)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minWidth: geo.size.width)
            }
            .onChange(of: viewer.index) { _, i in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(i, anchor: .center) }
            }
        }
        }
        .frame(height: 76)
    }

    private func chromeButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.12), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func arrow(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.12), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
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
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
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
