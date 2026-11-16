import AppKit
import AVKit
import SwiftUI

private extension Media {
    /// Direct video stream URL when the media file hasn't been downloaded locally yet.
    var macStreamURL: URL? {
        guard isVideo, let u = URL(string: url), u.scheme?.hasPrefix("http") == true else { return nil }
        let p = u.path.lowercased()
        if p.hasSuffix(".mp4") || p.hasSuffix(".mov") || p.hasSuffix(".m4v") || p.hasSuffix(".m3u8")
            || url.contains("video.twimg.com") || url.contains("bsky.app") || url.contains("cdninstagram.com")
            || url.contains("fbcdn.net") || url.contains("v.redd.it") {
            return u
        }
        return nil
    }
}

/// Full-window theater feed for binging saved videos on macOS: ↑/↓ or J/K
/// moves between clips, playback speed and watch position are remembered, and
/// folders/tags/delete sit alongside the player without scrolling bugs.
struct MacVideoFeedView: View {
    @Environment(AppModel.self) private var model

    struct Entry: Identifiable, Hashable {
        let item: Item
        let video: Media
        let index: Int
        var id: String { "\(item.id)#\(index)" }
        var memoryKey: String { video.videoFile ?? video.url }
        var playbackURL: URL? {
            if let f = video.videoFile { return Core.shared.mediaURL(f) }
            return video.macStreamURL
        }
        var isStream: Bool { video.videoFile == nil && video.macStreamURL != nil }

        static func == (lhs: Entry, rhs: Entry) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    @State private var scope: Scope
    @State private var entries: [Entry] = []
    @State private var currentIndex = 0
    @State private var loading = false
    @State private var reachedEnd = false
    @State private var offset = 0
    @State private var shuffled = false
    @State private var hideWatched = UserDefaults.standard.bool(forKey: "macFeedHideWatched")
    @AppStorage("macFeedMuted") private var muted = false
    @AppStorage("macVideoRate") private var playbackRate: Double = 1.0
    @State private var videoAspect: CGFloat?
    @State private var folderOverrides: [String: Int64?] = [:]
    @State private var showReader = false
    @State private var confirmDelete = false
    @State private var keyMonitor: Any?

    private static let rateOptions: [Double] = [1.0, 1.25, 1.5, 2.0]
    private let pageSize = 80

    init(initialScope: Scope) {
        _scope = State(initialValue: initialScope)
    }

    private var current: Entry? {
        entries.indices.contains(currentIndex) ? entries[currentIndex] : nil
    }

    private var rateLabel: String {
        playbackRate == floor(playbackRate) ? "\(Int(playbackRate))×" : String(format: "%.2g×", playbackRate)
    }

    private var effectiveFilter: String {
        let scopePart: String
        switch scope {
        case .folder(let id, _): scopePart = "folder:\(id)"
        case .platform(let p): scopePart = "site:\(p.rawValue)"
        case .tag(let key): scopePart = "tag:\(key)"
        case .saved(let s): scopePart = s.query
        default: scopePart = ""
        }
        return ["has:video", scopePart, model.query.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private var resumeKey: String { "macFeedResume:\(effectiveFilter)" }

    var body: some View {
        ZStack {
            Color.black.opacity(0.95).ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                Divider().overlay(.white.opacity(0.12))
                if entries.isEmpty && !loading {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let entry = current {
                    HStack(spacing: 0) {
                        stage(entry)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider().overlay(.white.opacity(0.12))
                        sideInspector(entry)
                            .frame(width: 310)
                            .frame(maxHeight: .infinity)
                            .background(.white.opacity(0.03))
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .task(id: "\(effectiveFilter)|\(shuffled)|\(hideWatched)") {
            await reloadFeed()
        }
        .task(id: current?.id) {
            videoAspect = nil
            if let entry = current, !shuffled {
                UserDefaults.standard.set(entry.id, forKey: resumeKey)
            }
            if currentIndex >= entries.count - 4 && !reachedEnd {
                await loadMore()
            }
            guard let url = current?.playbackURL else { return }
            if url.isFileURL {
                videoAspect = await LocalVideo.aspect(of: url)
            } else {
                videoAspect = current?.video.aspect
            }
        }
        .onChange(of: hideWatched) { _, val in
            UserDefaults.standard.set(val, forKey: "macFeedHideWatched")
        }
        .onAppear {
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    MainActor.assumeIsolated { handleKey(event) } ? nil : event
                }
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .sheet(isPresented: $showReader) {
            if let entry = current {
                ReaderView(id: entry.item.id)
            }
        }
        .confirmationDialog(
            "Bu kayıt silinsin mi?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Sil", role: .destructive) {
                if let entry = current {
                    Task { await deleteEntry(entry) }
                }
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Bu işlem geri alınamaz.")
        }
    }

    // MARK: Top Bar

    private var topBar: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button { model.showVideoFeed = false } label: {
                Label("Kapat", systemImage: "xmark")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)

            Label("Video Akışı", systemImage: "play.rectangle.on.rectangle")
                .font(.headline)

            if !entries.isEmpty {
                Text("\(currentIndex + 1) / \(reachedEnd ? "\(entries.count)" : "\(entries.count)+")")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.1), in: Capsule())
            }

            Spacer()

            Menu {
                Button { scope = .all } label: {
                    Label("Tüm videolar", systemImage: scope == .all ? "checkmark" : "tray.full")
                }
                if !model.folders.isEmpty {
                    Section("Klasörler") {
                        ForEach(FolderNode.flattened(model.folderTree).filter { $0.folder != nil }) { node in
                            if let f = node.folder {
                                Button {
                                    scope = .folder(id: f.id, name: f.name)
                                } label: {
                                    let picked: Bool = {
                                        if case .folder(let id, _) = scope { return id == f.id }
                                        return false
                                    }()
                                    Label(node.displayPath, systemImage: picked ? "checkmark" : "folder")
                                }
                            }
                        }
                    }
                }
            } label: {
                Label(scopeTitle, systemImage: "folder")
            }
            .controlSize(.small)

            Toggle(isOn: $hideWatched) {
                Label("İzlenenleri gizle", systemImage: "eye.slash")
            }
            .toggleStyle(.button)
            .controlSize(.small)

            Toggle(isOn: $shuffled) {
                Label("Karıştır", systemImage: "shuffle")
            }
            .toggleStyle(.button)
            .controlSize(.small)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    private var scopeTitle: String {
        switch scope {
        case .folder(_, let name): name.split(separator: "/").last.map(String.init) ?? name
        case .tag(let key): "#\(key)"
        case .platform(let p): p.label
        case .saved(let s): s.name
        default: String(localized: "Tüm videolar")
        }
    }

    // MARK: Stage & Inspector

    private func stage(_ entry: Entry) -> some View {
        ZStack {
            if let url = entry.playbackURL {
                LocalVideo(
                    url: url,
                    autoplay: true,
                    isMuted: muted,
                    loops: true,
                    rate: Float(playbackRate),
                    memoryKey: entry.memoryKey,
                    paused: showReader || confirmDelete
                )
                .id(entry.id)
                .aspectRatio(videoAspect ?? entry.video.aspect ?? 9.0 / 16.0, contentMode: .fit)
                .clipShape(.rect(cornerRadius: Theme.Radius.md))
                .shadow(color: .black.opacity(0.55), radius: 24, y: 10)
                .padding(.vertical, Theme.Spacing.lg)
                .padding(.horizontal, Theme.Spacing.xl)
            }

            VStack {
                Spacer()
                HStack(spacing: Theme.Spacing.md) {
                    Button { step(-1) } label: {
                        Label("Önceki (↑ / K)", systemImage: "chevron.up")
                    }
                    .disabled(currentIndex <= 0)

                    Button { step(1) } label: {
                        Label("Sonraki (↓ / J)", systemImage: "chevron.down")
                    }
                    .disabled(currentIndex >= entries.count - 1)
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .padding(.bottom, Theme.Spacing.lg)
            }
        }
    }

    private func sideInspector(_ entry: Entry) -> some View {
        let item = entry.item
        let activeFolder = folderOverrides[item.id] ?? item.folderId
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    HStack(spacing: Theme.Spacing.sm) {
                        AuthorLine(item: item, showHandle: true)
                    }

                    HStack(spacing: Theme.Spacing.sm) {
                        if MacFeedMemory.watched.contains(entry.memoryKey) {
                            Label("İzlendi", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                        if entry.isStream {
                            Label("Çevrimiçi akış", systemImage: "globe")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let title = item.title, !title.isEmpty {
                        Text(title)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                    }
                    if !item.text.isEmpty {
                        Text(item.text)
                            .font(.callout)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                    if let q = item.quote?.item, !q.text.isEmpty {
                        QuoteSnippet(item: q)
                    }
                    if !item.tags.isEmpty {
                        FlowLayout(spacing: Theme.Spacing.xs) {
                            ForEach(item.tags, id: \.self) { tag in
                                TagChip(name: tag) {
                                    model.filter(tag: tag)
                                    model.showVideoFeed = false
                                }
                            }
                        }
                    }
                }
                .padding(Theme.Spacing.lg)
            }

            Divider().overlay(.white.opacity(0.12))

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.sm) {
                    Button { muted.toggle() } label: {
                        Label(muted ? "Sesi aç (M)" : "Sessiz (M)", systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    Button(action: cycleRate) {
                        Label("Hız: \(rateLabel)", systemImage: "gauge.with.dots.needle.67percent")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                HStack(spacing: Theme.Spacing.sm) {
                    if !model.folders.isEmpty {
                        Menu {
                            ForEach(FolderNode.flattened(model.folderTree).filter { $0.folder != nil }) { node in
                                if let f = node.folder {
                                    Button {
                                        folderOverrides[item.id] = f.id
                                        Task { await model.moveItemsToFolder(ids: [item.id], folderID: f.id) }
                                    } label: {
                                        Label(node.displayPath, systemImage: activeFolder == f.id ? "checkmark" : "folder")
                                    }
                                }
                            }
                            if activeFolder != nil {
                                Divider()
                                Button {
                                    folderOverrides[item.id] = nil
                                    Task { await model.moveItemsToFolder(ids: [item.id], folderID: nil) }
                                } label: {
                                    Label("Klasörden çıkar", systemImage: "tray")
                                }
                            }
                        } label: {
                            Label("Klasör", systemImage: activeFolder != nil ? "folder.fill" : "folder")
                        }
                    }
                    Button { showReader = true } label: {
                        Label("Okuyucu", systemImage: "book")
                    }
                    if let file = entry.video.videoFile {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([Core.shared.mediaURL(file)])
                        } label: {
                            Label("Finder", systemImage: "folder.badge.gearshape")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                HStack(spacing: Theme.Spacing.sm) {
                    if let url = URL(string: item.url), url.scheme?.hasPrefix("http") == true {
                        Button { NSWorkspace.shared.open(url) } label: {
                            Label("Kaynağında aç", systemImage: "arrow.up.right.square")
                        }
                    }
                    Spacer()
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Sil", systemImage: "trash")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(Theme.Spacing.lg)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Burada video yok", systemImage: "play.slash")
        } description: {
            Text("İndirilmiş ya da doğrudan akışı olan videolar burada arka arkaya oynar.")
        }
    }

    // MARK: Actions & Loading

    private func cycleRate() {
        let idx = Self.rateOptions.firstIndex(where: { abs($0 - playbackRate) < 0.05 }) ?? 0
        playbackRate = Self.rateOptions[(idx + 1) % Self.rateOptions.count]
    }

    private func step(_ delta: Int) {
        let next = currentIndex + delta
        guard entries.indices.contains(next) else { return }
        currentIndex = next
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard !showReader, !confirmDelete, !(event.window?.firstResponder is NSText) else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods.isEmpty else { return false }
        switch (event.keyCode, event.charactersIgnoringModifiers?.lowercased()) {
        case (126, _), (_, "k"): step(-1); return true
        case (125, _), (_, "j"): step(1); return true
        case (_, "m"): muted.toggle(); return true
        case (53, _): model.showVideoFeed = false; return true
        default: return false
        }
    }

    private func reloadFeed() async {
        entries = []
        currentIndex = 0
        offset = 0
        reachedEnd = false
        let resume = shuffled ? nil : UserDefaults.standard.string(forKey: resumeKey)
        await loadMore(want: 16)
        if let resume {
            for _ in 0..<5 where !entries.contains(where: { $0.id == resume }) && !reachedEnd {
                await loadMore(want: 40)
            }
            if let idx = entries.firstIndex(where: { $0.id == resume }) {
                currentIndex = idx
            }
        }
    }

    private func loadMore(want: Int = 12) async {
        guard !loading, !reachedEnd else { return }
        loading = true
        defer { loading = false }
        var got: [Entry] = []
        while got.count < want, !reachedEnd {
            guard let r: SearchResult = try? await model.core.call(.search(q: effectiveFilter, sort: "", limit: pageSize, offset: offset)) else {
                reachedEnd = true
                break
            }
            offset += r.items.count
            reachedEnd = r.items.count < pageSize
            for item in r.items {
                let videos = item.allMedia.enumerated().filter { $0.element.isVideo && ($0.element.videoFile != nil || $0.element.macStreamURL != nil) }
                got += videos.map { Entry(item: item, video: $0.element, index: $0.offset) }
            }
        }
        if hideWatched {
            let watched = MacFeedMemory.watched
            got.removeAll { watched.contains($0.memoryKey) }
        }
        if shuffled { got.shuffle() }
        let known = Set(entries.map(\.id))
        entries += got.filter { !known.contains($0.id) }
    }

    private func deleteEntry(_ entry: Entry) async {
        let removedID = entry.item.id
        entries.removeAll { $0.item.id == removedID }
        if entries.isEmpty {
            currentIndex = 0
        } else if currentIndex >= entries.count {
            currentIndex = entries.count - 1
        }
        await model.delete([removedID])
    }
}
