import AVFoundation
import SwiftUI
import UIKit

// The swipe-through feed: full-screen posts one after another, from the
// whole library or one folder (or whatever the list is filtered to). Two
// modes: only videos (those on the phone), or every post — videos play,
// pictures swipe sideways, text and quotes read like a timeline. One
// player for the page on screen; other pages show their poster.

/// One page of the feed: an item, and the video it plays if any.
struct FeedEntry: Identifiable, Hashable {
    let item: Item
    /// A video on the phone; nil for pictures and text.
    let video: Media?
    let index: Int
    var id: String { "\(item.id)#\(index)" }

    static func == (a: FeedEntry, b: FeedEntry) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// Pictures to show when there is no video (posters of videos that are
    /// not on the phone included).
    var pictures: [Media] { item.allMedia.filter { $0.file != nil } }
}

enum FeedMode: String {
    case videos, all
}

/// The single player of the feed. It loops the current video and reports
/// its progress for the bar at the bottom.
@MainActor
@Observable
final class FeedPlayer {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var timeObserver: Any?
    private(set) var current: String?
    var progress: Double = 0
    var duration: Double = 0
    var paused = false
    var muted = UserDefaults.standard.bool(forKey: "feedMuted") {
        didSet {
            player.isMuted = muted
            UserDefaults.standard.set(muted, forKey: "feedMuted")
        }
    }

    init() {
        player.isMuted = muted
        player.preventsDisplaySleepDuringVideoPlayback = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, let item = self.player.currentItem else { return }
                let d = item.duration.seconds
                self.duration = d.isFinite ? d : 0
                self.progress = self.duration > 0 ? t.seconds / self.duration : 0
            }
        }
    }

    func play(_ file: String) {
        guard file != current else { return }
        current = file
        looper?.disableLooping()
        player.removeAllItems()
        progress = 0
        duration = 0
        let item = AVPlayerItem(url: Core.shared.mediaURL(file))
        looper = AVPlayerLooper(player: player, templateItem: item)
        paused = false
        player.rate = 1
        player.play()
    }

    func togglePause() {
        paused.toggle()
        if paused { player.pause() } else { player.play() }
    }

    /// Hold to watch at double speed.
    func fast(_ on: Bool) {
        guard !paused else { return }
        player.rate = on ? 2 : 1
    }

    func seek(to fraction: Double) {
        guard duration > 0 else { return }
        let t = CMTime(seconds: max(0, min(1, fraction)) * duration, preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        progress = fraction
    }

    func stop() {
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()
        current = nil
    }
}

/// The feed's pages, read from the library a page of results at a time.
@MainActor
@Observable
final class FeedSource {
    private(set) var entries: [FeedEntry] = []
    private(set) var loading = false
    private(set) var reachedEnd = false
    private var offset = 0
    private let filter: String
    private let mode: FeedMode
    private let shuffled: Bool
    private let pageSize = 80

    init(filter: String, mode: FeedMode, shuffled: Bool) {
        self.filter = filter
        self.mode = mode
        self.shuffled = shuffled
    }

    /// Reads results until at least `want` more pages came or the library
    /// ran out (in the video mode, videos not on the phone are skipped).
    func load(want: Int = 10) async {
        guard !loading, !reachedEnd else { return }
        loading = true
        defer { loading = false }
        let q = [mode == .videos ? "has:video" : "", filter].filter { !$0.isEmpty }.joined(separator: " ")
        var got: [FeedEntry] = []
        while got.count < want, !reachedEnd {
            guard let r: SearchResult = try? await Core.shared.call(.search(q: q, sort: "", limit: pageSize, offset: offset)) else {
                reachedEnd = true
                break
            }
            offset += r.items.count
            reachedEnd = r.items.count < pageSize
            for item in r.items {
                let videos = item.allMedia.enumerated().filter { $0.element.isVideo && $0.element.videoFile != nil }
                switch mode {
                case .videos:
                    got += videos.map { FeedEntry(item: item, video: $0.element, index: $0.offset) }
                case .all:
                    // One page per post; a post with videos plays its first.
                    got.append(FeedEntry(item: item, video: videos.first?.element, index: 0))
                }
            }
        }
        if shuffled { got.shuffle() }
        let known = Set(entries.map(\.id))
        entries += got.filter { !known.contains($0.id) }
    }

    /// Drops a deleted post's pages; returns the page to show next.
    func remove(item id: String, after current: String?) -> String? {
        let start = current.flatMap { c in entries.firstIndex { $0.id == c } } ?? 0
        let next = entries[start...].first { $0.item.id != id }?.id ?? entries[..<start].last { $0.item.id != id }?.id
        entries.removeAll { $0.item.id == id }
        return next
    }
}

struct VideoFeedView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The list's scope when the feed opened; the menu can switch folders.
    @State var scope: PhoneScope
    let query: String
    @State private var mode = FeedMode(rawValue: UserDefaults.standard.string(forKey: "feedMode") ?? "") ?? .videos
    @State private var source: FeedSource?
    @State private var current: String?
    @State private var shuffled = false
    @State private var player = FeedPlayer()
    @State private var details: Item?
    @State private var deleting: Item?

    private var filter: String {
        [scope.filter, query.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Where the feed was left for this scope and mode, to continue there.
    private var resumeKey: String { "feedResume:\(mode.rawValue):\(filter)" }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let source {
                if source.entries.isEmpty && !source.loading {
                    empty
                } else {
                    pages(source)
                }
            }
            topBar
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        // Swipe right to leave, like going back. On a page of several
        // pictures sideways swipes page through them, so start at the edge.
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { v in
                    let right = v.translation.width > 90 && abs(v.translation.height) < v.translation.width * 0.6
                    let onPictures = (source?.entries.first { $0.id == current }).map { $0.video == nil && $0.pictures.count > 1 } ?? false
                    if right && (!onPictures || v.startLocation.x < 40) { dismiss() }
                }
        )
        .confirmationDialog("Bu kayıt silinsin mi?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { item in
            Button("Sil", role: .destructive) { Task { await delete(item) } }
            Button("Vazgeç", role: .cancel) {}
        } message: { _ in
            Text("Senkron açıksa diğer cihazlardan da silinir.")
        }
        .task(id: "\(filter)|\(mode.rawValue)|\(shuffled)") { await open() }
        .onChange(of: current) { _, id in
            guard let source, let id, let entry = source.entries.first(where: { $0.id == id }) else { return }
            if let v = entry.video?.videoFile { player.play(v) } else { player.stop() }
            if !shuffled { UserDefaults.standard.set(id, forKey: resumeKey) }
            if let i = source.entries.firstIndex(of: entry), i >= source.entries.count - 3 {
                Task { await source.load() }
            }
        }
        .onChange(of: mode) { _, m in UserDefaults.standard.set(m.rawValue, forKey: "feedMode") }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        }
        .onDisappear {
            player.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .sheet(item: $details) { item in
            NavigationStack {
                ItemView(id: item.id)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Kapat") { details = nil } }
                    }
            }
            .onAppear { player.player.pause() }
            .onDisappear { if !player.paused { player.player.play() } }
        }
    }

    private func delete(_ item: Item) async {
        guard let source else { return }
        player.stop()
        let next = source.remove(item: item.id, after: current)
        current = next
        if let id = next, let e = source.entries.first(where: { $0.id == id }), let v = e.video?.videoFile { player.play(v) }
        await model.delete(item.id)
    }

    private func open() async {
        player.stop()
        let s = FeedSource(filter: filter, mode: mode, shuffled: shuffled)
        source = s
        current = nil
        let resume = shuffled ? nil : UserDefaults.standard.string(forKey: resumeKey)
        await s.load(want: 12)
        // Continue where this scope was left, if it is in the first pages.
        var target = s.entries.first?.id
        if let resume {
            for _ in 0..<5 where !s.entries.contains(where: { $0.id == resume }) && !s.reachedEnd {
                await s.load(want: 40)
            }
            if s.entries.contains(where: { $0.id == resume }) { target = resume }
        }
        current = target
    }

    private func pages(_ source: FeedSource) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(source.entries) { entry in
                    FeedPage(entry: entry, active: entry.id == current, player: player, details: { details = entry.item }, delete: { deleting = entry.item })
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(entry.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $current)
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
    }

    private var empty: some View {
        ContentUnavailableView {
            Label(mode == .videos ? "Burada video yok" : "Burada gönderi yok", systemImage: "play.slash")
        } description: {
            Text(mode == .videos
                 ? "Telefonda olan videolar burada akar. Mac'ten gelen videolar iCloud indirdikçe eklenir."
                 : "Bu klasörde ya da süzgeçte kayıt yok.")
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        VStack {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).padding(10).background(.ultraThinMaterial, in: .circle)
                }
                .accessibilityLabel("Kapat")
                Spacer()
                Menu {
                    Picker("Göster", selection: $mode) {
                        Label("Videolar", systemImage: "play.rectangle").tag(FeedMode.videos)
                        Label("Tüm gönderiler", systemImage: "text.below.photo").tag(FeedMode.all)
                    }
                    Divider()
                    Button { scope = .all } label: { Label("Tüm kütüphane", systemImage: "tray.full") }
                    if !model.folders.isEmpty {
                        Section("Klasörler") {
                            ForEach(model.folders) { f in
                                Button { scope = .folder(f.id, f.name) } label: {
                                    Label(f.name.replacingOccurrences(of: "/", with: " › "), systemImage: "folder")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode == .videos ? "play.rectangle.fill" : "text.below.photo.fill").font(.caption)
                        Text(scope == .all ? (mode == .videos ? "Tüm videolar" : "Tüm gönderiler") : scope.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: .capsule)
                }
                Spacer()
                Button { shuffled.toggle() } label: {
                    Image(systemName: "shuffle").font(.headline).padding(10)
                        .background(shuffled ? AnyShapeStyle(PhoneTheme.accent) : AnyShapeStyle(.ultraThinMaterial), in: .circle)
                }
                .accessibilityLabel(shuffled ? "Sırayla" : "Karıştır")
            }
            .foregroundStyle(.white)
            .padding(.horizontal)
            Spacer()
        }
    }
}

/// One page: a video, pictures to swipe sideways, or a post's text; the
/// author and buttons on top.
private struct FeedPage: View {
    let entry: FeedEntry
    let active: Bool
    let player: FeedPlayer
    let details: () -> Void
    let delete: () -> Void
    @State private var showPause = false
    @State private var expanded = false

    private var item: Item { entry.item }
    /// Text goes in the middle of a page without pictures, at the bottom
    /// (over the picture) otherwise.
    private var textOnly: Bool { entry.video == nil && entry.pictures.isEmpty }

    var body: some View {
        // The page's size comes from the black base; pictures and the video
        // are overlays, so a filling picture cannot widen the page.
        Color.black
            .overlay {
                if let video = entry.video {
                    VideoLayer(video: video, active: active, player: player, showPause: $showPause)
                } else if !entry.pictures.isEmpty {
                    PictureSwiper(pictures: entry.pictures)
                } else {
                    TextPost(item: item, open: details)
                }
            }
            .clipped()
            .overlay(alignment: .bottom) { overlay }
            .onChange(of: active) { _, on in if !on { showPause = false } }
    }

    private var overlay: some View {
        VStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: (Platform(rawValue: item.platform) ?? .web).symbol).font(.caption)
                        if let a = item.author ?? URL(string: item.url)?.host() {
                            Text(a).font(.headline).lineLimit(1)
                        }
                        Text(item.saved.formatted(.relative(presentation: .named))).font(.caption).opacity(0.7)
                    }
                    if !textOnly {
                        let text = item.headline
                        if !text.isEmpty {
                            Text(text)
                                .font(.subheadline)
                                .lineLimit(expanded ? 14 : 2)
                                .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
                        }
                        if let q = item.quote?.item, !q.text.isEmpty {
                            QuoteLine(item: q).onTapGesture(perform: details)
                        }
                    }
                    if !item.thread.isEmpty {
                        Button(action: details) {
                            Label("Zincir · \(item.thread.count + 1) gönderi", systemImage: "text.line.first.and.arrowtriangle.forward")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    if !item.tags.isEmpty {
                        Text(item.tags.map { "#\($0)" }.joined(separator: " "))
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 18) {
                    if entry.video != nil {
                        sideButton(player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: player.muted ? "Sesi aç" : "Sesi kapat") {
                            player.muted.toggle()
                        }
                    }
                    sideButton("info.circle", label: "Ayrıntılar", action: details)
                    sideButton("trash", label: "Sil", action: delete)
                    if let url = URL(string: item.url), url.scheme?.hasPrefix("http") == true {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up").font(.title2).frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Paylaş")
                    }
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 4)
            .padding(.horizontal)
            if active && entry.video != nil {
                ProgressBar(player: player)
            }
        }
        .padding(.bottom, 24)
        .background(alignment: .bottom) {
            if !textOnly {
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 280)
                    .allowsHitTesting(false)
            }
        }
    }

    private func sideButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title2).frame(width: 44, height: 44)
        }
        .accessibilityLabel(label)
    }
}

/// The video of a page: its poster, and the player while on screen. Tap
/// pauses, holding plays at double speed.
private struct VideoLayer: View {
    let video: Media
    let active: Bool
    let player: FeedPlayer
    @Binding var showPause: Bool

    private var portrait: Bool { (video.aspect ?? 0.56) < 0.8 }

    var body: some View {
        ZStack {
            if let poster = video.file {
                LocalImage(file: poster, maxPixel: 1200, fill: portrait)
            }
            if active {
                PlayerLayer(player: player.player, fill: portrait)
                    .contentShape(.rect)
                    .onTapGesture {
                        player.togglePause()
                        showPause = player.paused
                    }
                    .onLongPressGesture(minimumDuration: 0.3, maximumDistance: 30) {} onPressingChanged: { pressing in
                        player.fast(pressing)
                    }
            }
            if active && showPause && player.paused {
                Image(systemName: "play.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.8))
                    .allowsHitTesting(false)
            }
        }
    }
}

/// A post's pictures, swiped sideways, with dots when there are several.
private struct PictureSwiper: View {
    let pictures: [Media]

    var body: some View {
        TabView {
            ForEach(pictures) { m in
                if let f = m.file {
                    LocalImage(file: f, maxPixel: 2000, fill: false)
                        .overlay {
                            if m.isVideo {
                                // A video whose file is not on the phone yet.
                                Label("Video telefona inmedi", systemImage: "icloud.and.arrow.down")
                                    .font(.footnote.weight(.semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(.ultraThinMaterial, in: .capsule)
                            }
                        }
                }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: pictures.count > 1 ? .always : .never))
        .padding(.vertical, 70)
    }
}

/// A post with no pictures: its text large in the middle of the page.
private struct TextPost: View {
    let item: Item
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let t = item.title, !t.isEmpty, t != item.text {
                Text(t).font(.title2.weight(.bold))
            }
            if !item.text.isEmpty {
                Text(item.text)
                    .font(item.text.count < 180 ? .title2 : .body)
                    .lineLimit(item.text.count < 180 ? nil : 16)
            }
            if let q = item.quote?.item {
                QuoteCard(item: q)
            }
            if let part = item.thread.first, !part.text.isEmpty {
                // The next post of the thread, to show there is more.
                Text(part.text).font(.callout).foregroundStyle(.white.opacity(0.6)).lineLimit(3)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 90)
        .padding(.bottom, 170)
        .frame(maxHeight: .infinity)
        .contentShape(.rect)
        .onTapGesture(perform: open)
        .background {
            LinearGradient(colors: [PhoneTheme.accent.opacity(0.35), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

/// A quoted post as a card (text pages).
private struct QuoteCard: View {
    let item: Item

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if let a = item.author { Text(a).font(.subheadline.weight(.semibold)) }
                Text(item.text).font(.callout).lineLimit(6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let f = item.cover?.file {
                LocalImage(file: f, maxPixel: 300).frame(width: 64, height: 64).clipShape(.rect(cornerRadius: 8))
            }
        }
        .padding(12)
        .background(.white.opacity(0.1), in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.18)) }
    }
}

/// A quoted post in one line, under a picture or video's text.
private struct QuoteLine: View {
    let item: Item

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "quote.bubble").font(.caption)
            Text([item.author, item.text].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .lineLimit(2)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.white.opacity(0.14), in: .rect(cornerRadius: 10))
    }
}

/// A thin bar that shows where the video is; drag it to seek.
private struct ProgressBar: View {
    let player: FeedPlayer
    @State private var dragging: Double?

    var body: some View {
        GeometryReader { g in
            let p = dragging ?? player.progress
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(width: max(0, min(1, p)) * g.size.width)
            }
            .frame(height: dragging == nil ? 3 : 6)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in dragging = max(0, min(1, v.location.x / max(1, g.size.width))) }
                    .onEnded { _ in
                        if let d = dragging { player.seek(to: d) }
                        dragging = nil
                    }
            )
        }
        .frame(height: 20)
        .padding(.horizontal)
        .animation(.snappy(duration: 0.15), value: dragging == nil)
        .accessibilityElement()
        .accessibilityLabel("Video ilerlemesi")
        .accessibilityValue("%\(Int(player.progress * 100))")
    }
}

/// AVPlayerLayer without the system controls, filling or fitting the page.
private struct PlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    let fill: Bool

    final class View: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
    }

    func makeUIView(context: Context) -> View {
        let v = View()
        v.backgroundColor = .clear
        v.playerLayer?.player = player
        return v
    }

    func updateUIView(_ v: View, context: Context) {
        if v.playerLayer?.player !== player { v.playerLayer?.player = player }
        v.playerLayer?.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}
