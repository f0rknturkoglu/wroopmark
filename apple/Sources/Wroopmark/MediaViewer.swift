import AVKit
import SwiftUI

/// Full-size images and offline video playback, entirely from the media
/// store. ← → to move, Esc to close.
struct MediaViewer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let viewer: Viewer

    private var media: Media { viewer.media[viewer.index] }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                content
            }
            bar
        }
        .frame(minWidth: 820, idealWidth: 1100, minHeight: 600, idealHeight: 800)
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

    private var notDownloaded: some View {
        VStack(spacing: 12) {
            Image(systemName: "icloud.and.arrow.down").font(.system(size: 38)).foregroundStyle(.white.opacity(0.85))
            Text(media.canDownloadVideo || !media.isVideo ? "Henüz indirilmedi" : "Bu video tarayıcı eklentisiyle iner")
                .foregroundStyle(.white)
            if media.isVideo && !media.canDownloadVideo {
                Text("Gönderiyi tarayıcıda, eklenti açıkken bir kez açman yeterli.")
                    .font(.caption).foregroundStyle(.white.opacity(0.75))
            }
            HStack {
                if media.canDownloadVideo || media.file == nil {
                    Button("Şimdi indir") { Task { await model.downloadMedia(viewer.ownerID) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy)
                }
                Button("Kaynağında aç") {
                    if let url = URL(string: viewer.postURL) { NSWorkspace.shared.open(url) }
                }
            }
            if model.isBusy { ProgressView().controlSize(.small).tint(.white) }
        }
        .padding(24)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var bar: some View {
        HStack(spacing: 12) {
            Button { move(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(viewer.index == 0)
            Text("\(viewer.index + 1) / \(viewer.media.count)").monospacedDigit().foregroundStyle(.secondary)
            Button { move(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: [])
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

/// AppKit's own player view. SwiftUI's `VideoPlayer` lives in the
/// `_AVKit_SwiftUI` overlay, which aborts at runtime when built with the
/// Command Line Tools; `AVPlayerView` has no such overlay and also brings
/// the QuickTime controls, full screen and picture in picture.
struct LocalVideo: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        let player = AVPlayer(url: url)
        view.player = player
        player.play()
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            view.player?.pause()
            let player = AVPlayer(url: url)
            view.player = player
            player.play()
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
