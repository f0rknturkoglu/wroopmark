import AVKit
import SwiftUI

/// Full-size images and offline video playback, entirely from the media
/// store. ← → to move, Esc to close.
struct MediaViewer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let viewer: Viewer
    /// The outside tools failed and the browser extension is on it.
    @State private var viaBrowser = false

    private var media: Media { viewer.media[viewer.index] }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.viewer = nil
                    }
                content
            }
            bar
        }
        .frame(minWidth: 820, idealWidth: 1100, minHeight: 600, idealHeight: 800)
        .onChange(of: viewer.index) { _, _ in viaBrowser = false }
    }

    @ViewBuilder
    private var content: some View {
        if media.isVideo, let file = media.videoFile {
            LocalVideo(url: Core.shared.mediaURL(file)).id(file)
        } else if let file = media.file {
            LocalImage(file: file, maxPixel: 3200, contentMode: .fit)
                .id(file)
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
            Image(systemName: "icloud.and.arrow.down").font(.system(size: 38)).foregroundStyle(.white.opacity(0.85))
            Text(model.isBusy ? "İndiriliyor…" : viaBrowser ? "Tarayıcıyla indiriliyor…" : "Henüz indirilmedi").foregroundStyle(.white)
            if viaBrowser {
                Text("İndirici başaramadı; gönderi tarayıcıda arka planda açıldı, video gelince burada oynar.")
                    .font(.caption).foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
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
            if model.isBusy || viaBrowser { ProgressView().controlSize(.small).tint(.white) }
        }
        .padding(24)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var bar: some View {
        HStack(spacing: 12) {
            Button { move(-1) } label: {
                Image(systemName: "chevron.left")
                    .frame(minWidth: 28, minHeight: 28)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .accessibilityLabel("Önceki medya")
            .disabled(viewer.index == 0)
            Text("\(viewer.index + 1) / \(viewer.media.count)").monospacedDigit().foregroundStyle(.secondary)
            Button { move(1) } label: {
                Image(systemName: "chevron.right")
                    .frame(minWidth: 28, minHeight: 28)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .accessibilityLabel("Sonraki medya")
            .disabled(viewer.index >= viewer.media.count - 1)
            if let alt = media.alt {
                Text(alt).lineLimit(1).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let file = media.videoFile ?? media.file {
                Button { NSWorkspace.shared.activateFileViewerSelecting([Core.shared.mediaURL(file)]) } label: {
                    Label("Finder'da göster", systemImage: "folder")
                }
            }
            Button("Kapat") { model.viewer = nil }
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.bar)
    }

    private func move(_ step: Int) {
        guard var v = model.viewer else { return }
        let next = v.index + step
        guard v.media.indices.contains(next) else { return }
        v.index = next
        model.viewer = v
    }
}

/// Inline player that embeds video playback directly within the frame/card.
struct InlineVideoPlayer: View {
    let file: String
    var alt: String? = nil
    var maxHeight: CGFloat = 380

    private var videoURL: URL {
        Core.shared.mediaURL(file)
    }

    var body: some View {
        LocalVideo(url: videoURL, controlsStyle: .inline)
            .frame(maxWidth: .infinity)
            .frame(height: maxHeight)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
    }
}

/// AppKit's own player view. SwiftUI's `VideoPlayer` lives in the
/// `_AVKit_SwiftUI` overlay, which aborts at runtime when built with the
/// Command Line Tools; `AVPlayerView` has no such overlay and also brings
/// the QuickTime controls, full screen and picture in picture.
struct LocalVideo: NSViewRepresentable {
    let url: URL
    var isMuted: Bool = false
    var controlsStyle: AVPlayerViewControlsStyle = .floating

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = controlsStyle
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        let player = AVPlayer(url: url)
        player.isMuted = isMuted
        view.player = player
        player.play()
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if let player = view.player {
            if player.isMuted != isMuted {
                player.isMuted = isMuted
            }
            if (player.currentItem?.asset as? AVURLAsset)?.url != url {
                player.pause()
                let newPlayer = AVPlayer(url: url)
                newPlayer.isMuted = isMuted
                view.player = newPlayer
                newPlayer.play()
            }
        } else {
            let player = AVPlayer(url: url)
            player.isMuted = isMuted
            view.player = player
            player.play()
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
