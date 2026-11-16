import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ItemView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var item: Item?
    @State private var note = ""
    @State private var newTag = ""
    @State private var confirmDelete = false
    @State private var reading = false
    @State private var viewer: Media?
    @State private var newFolder = false
    @State private var folderName = ""
    @State private var summarizing = false
    @State private var related: [Item] = []
    @State private var pickingFromPhotos = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var attaching = false
    @State private var showingSnapshot = false
    @State private var transcribing = false
    @State private var speechError: String?

    var body: some View {
        ScrollView {
            if let item {
                VStack(alignment: .leading, spacing: 16) {
                    header(item)
                    if let t = item.title, !t.isEmpty { Text(t).font(.title3.weight(.semibold)).textSelection(.enabled) }
                    if !item.text.isEmpty { Text(LocalizedStringKey(stringLiteral: item.text.markdownSafe)).textSelection(.enabled) }
                    let threadURLs = Set(item.thread.flatMap { $0.media.map(\.url) })
                    MediaStrip(media: item.media.filter { !threadURLs.contains($0.url) }) { viewer = $0 }
                    if let q = item.quote?.item { QuoteBox(item: q) { viewer = $0 } }
                    if !item.thread.isEmpty { thread(item) }
                    if !item.replies.isEmpty { replies(item) }
                    if let s = item.summary, !s.isEmpty {
                        Label { Text(s) } icon: { Image(systemName: "sparkles") }
                            .font(.callout)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(PhoneTheme.accent.opacity(0.08), in: .rect(cornerRadius: 12))
                    } else if model.aiStatus?.llmReady == true {
                        Button {
                            summarizing = true
                            Task {
                                if let updated = await model.summarize(item.id) {
                                    self.item = updated
                                }
                                summarizing = false
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if summarizing { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
                                Text(summarizing ? "Özetleniyor…" : "Özetle ve etiket öner")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(summarizing)
                    }
                    if item.media.contains(where: { $0.isVideo && $0.videoFile != nil }) {
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                speechError = nil
                                transcribing = true
                                Task {
                                    defer { transcribing = false }
                                    do {
                                        let text = try await model.transcribeVideo(for: item)
                                        if !text.isEmpty, let updated = await model.refresh(id) {
                                            self.item = updated
                                        }
                                    } catch {
                                        speechError = error.localizedDescription
                                    }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    if transcribing { ProgressView().controlSize(.small) } else { Image(systemName: "waveform.badge.magnifyingglass") }
                                    Text(transcribing ? "Konuşma okunuyor…" : "Videodaki konuşmayı metne dök")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(transcribing)
                            if let speechError {
                                Text(speechError).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                    if let extra = item.extra, !extra.isEmpty {
                        DisclosureGroup {
                            Text(extra)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                        } label: {
                            Label("Konuşma ve ek metin", systemImage: "waveform")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    tagsSection(item)
                    folderSection(item)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Not").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        TextField("Kayıtla ilgili not…", text: $note, axis: .vertical)
                            .lineLimit(2...8)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(saveNote)
                    }
                    if !item.links.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Bağlantılar").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(item.links, id: \.self) { l in
                                if let u = URL(string: l) { Link(l.replacingOccurrences(of: "https://", with: ""), destination: u).font(.footnote).lineLimit(1) }
                            }
                        }
                    }
                    Text("Kaydedildi \(item.saved.formatted(date: .long, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !related.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Benzerleri").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(related) { r in
                                NavigationLink(value: r.id) {
                                    ItemRowView(item: r)
                                        .padding(10)
                                        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding()
            } else {
                ProgressView().padding(.top, 80)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if item != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { reading = true } label: { Image(systemName: "book") }
                        .accessibilityLabel("Oku")
                }
            }
            if let item, let url = URL(string: item.url) {
                ToolbarItem(placement: .topBarTrailing) { ShareLink(item: url) }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Link(destination: url) { Label("Kaynağında aç", systemImage: "safari") }
                        if item.snapshot != nil {
                            Button { showingSnapshot = true } label: {
                                Label("Sayfanın kopyası", systemImage: "doc.richtext")
                            }
                        }
                        // The user's own copy (saved from the app, a screen
                        // recording): the post plays and shows offline.
                        Button { pickingFromPhotos = true } label: {
                            Label(item.needsVideoFile ? "Videoyu Fotoğraflar'dan ekle" : "Fotoğraflar'dan ekle", systemImage: "photo.badge.plus")
                        }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Sil", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .fullScreenCover(isPresented: $reading) { ReaderView(id: id) }
        .photosPicker(isPresented: $pickingFromPhotos, selection: $picked, maxSelectionCount: 5,
                      matching: item?.needsVideoFile == true ? .videos : .any(of: [.videos, .images]))
        .onChange(of: picked) { _, chosen in
            guard !chosen.isEmpty else { return }
            picked = []
            Task { await attach(chosen) }
        }
        .overlay {
            if attaching {
                ProgressView().padding(20).background(.regularMaterial, in: .rect(cornerRadius: 14))
            }
        }
        .confirmationDialog("Bu kayıt silinsin mi?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Sil", role: .destructive) {
                Task {
                    await model.delete(id)
                    dismiss()
                }
            }
        }
        .fullScreenCover(item: $viewer) { m in MediaViewerView(media: m) }
        .fullScreenCover(isPresented: $showingSnapshot) {
            if let item { PageCopySheet(item: item) }
        }
        .alert("Yeni klasör", isPresented: $newFolder) {
            TextField("Ad (alt klasör için: Ders/Matematik)", text: $folderName)
            Button("Oluştur ve taşı") { Task { await createFolder() } }
            Button("Vazgeç", role: .cancel) {}
        }
        .task(id: id) {
            async let loaded = model.refresh(id)
            async let rel = model.related(for: id)
            item = await loaded
            note = item?.note ?? ""
            related = await rel
        }
        .onDisappear(perform: saveNote)
    }

    private func header(_ item: Item) -> some View {
        HStack {
            Image(systemName: (Platform(rawValue: item.platform) ?? .web).symbol).foregroundStyle(PhoneTheme.accent)
            VStack(alignment: .leading) {
                Text(item.authorName ?? item.author ?? URL(string: item.url)?.host() ?? "").font(.headline)
                if let h = item.authorHandle, item.authorName != nil { Text("@\(h)").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let c = item.created { Text(c.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func thread(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Zincir · \(item.thread.count + 1) gönderi", systemImage: "text.line.first.and.arrowtriangle.forward")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(item.thread.enumerated()), id: \.element.id) { n, part in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(n + 2)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(part.text).textSelection(.enabled)
                        let urls = Set(part.media.map(\.url))
                        MediaStrip(media: item.media.filter { urls.contains($0.url) }) { viewer = $0 }
                    }
                }
            }
        }
    }

    private func replies(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Yanıtlar · \(item.replies.count)", systemImage: "bubble.left.and.bubble.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(item.replies) { r in
                VStack(alignment: .leading, spacing: 4) {
                    if let a = r.author { Text(a).font(.footnote.weight(.semibold)).foregroundStyle(.secondary) }
                    if !r.text.isEmpty { Text(r.text).font(.callout).textSelection(.enabled) }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 10))
            }
        }
    }

    private func tagsSection(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Etiketler").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(item.tags, id: \.self) { t in
                        Button {
                            Task { await setTags(item.tags.filter { $0 != t }) }
                        } label: {
                            Label("#\(t)", systemImage: "xmark").labelStyle(TrailingIcon())
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    ForEach(item.aiTags.filter { !item.tags.contains($0) }, id: \.self) { t in
                        Button("+ \(t)") { Task { await setTags(item.tags + [t]) } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.secondary)
                    }
                }
            }
            TextField("Etiket ekle", text: $newTag)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit {
                    let add = phoneTags(newTag)
                    newTag = ""
                    Task { await setTags(item.tags + add) }
                }
        }
    }

    private func folderSection(_ item: Item) -> some View {
        HStack {
            Text("Klasör").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("Yeni klasör…", systemImage: "folder.badge.plus") {
                    folderName = ""
                    newFolder = true
                }
                Divider()
                Button("Klasör yok") { Task { await move(nil) } }
                ForEach(model.folders) { f in
                    Button(f.name.replacingOccurrences(of: "/", with: " › ")) { Task { await move(f.id) } }
                }
            } label: {
                Text(model.folders.first { $0.id == item.folderId }?.name.replacingOccurrences(of: "/", with: " › ") ?? String(localized: "Klasör seçilmedi"))
            }
        }
    }

    /// Makes the folder (or finds it, any case) and files the item in it.
    /// `Ders/Matematik` makes a subfolder.
    /// Copies the chosen videos and pictures out of Photos and puts them on this post.
    private func attach(_ chosen: [PhotosPickerItem]) async {
        attaching = true
        defer { attaching = false }
        for p in chosen {
            guard let file = try? await p.loadTransferable(type: PickedFile.self) else { continue }
            _ = try? await model.core.call(.call("attach_file", ["id": .string(id), "path": .string(file.url.path)])) as Bool
            try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
        }
        await model.makePosters()
        model.syncSoon()
        item = await model.refresh(id)
        model.startOCR()
    }

    private func createFolder() async {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let existing = model.folders.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
        var id = existing?.id
        if id == nil, let made: Folder = try? await model.core.call(.addFolder(name: name)) {
            id = made.id
        }
        if let id { await move(id) }
    }

    private func setTags(_ tags: [String]) async {
        var seen = Set<String>()
        let clean = tags.filter { seen.insert($0.lowercased()).inserted }
        if await model.perform(.setTags(id: id, tags: clean)) {
            item = await model.refresh(id)
            await model.refreshMeta()
        }
    }

    private func move(_ folder: Int64?) async {
        if await model.perform(.moveToFolder(id: id, folderID: folder)) {
            item = await model.refresh(id)
            await model.refreshMeta()
        }
    }

    private func saveNote() {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let item, trimmed != (item.note ?? "") else { return }
        Task {
            _ = await model.perform(.setNote(id: id, note: trimmed))
            self.item = await model.refresh(id)
        }
    }
}

private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.font(.caption2)
        }
    }
}

extension Media: Identifiable {
    public var id: String { url }
}

/// Pictures and videos side by side; tapping opens them full screen.
struct MediaStrip: View {
    let media: [Media]
    let open: (Media) -> Void

    var body: some View {
        if media.count == 1, let m = media.first {
            // The picture fills a box the width of the screen; as an overlay it
            // never makes the page wider (a filled image proposes its own size).
            Color.clear
                .aspectRatio(m.aspect ?? 1.3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { tile(m) }
                .clipShape(.rect(cornerRadius: 12))
        } else if !media.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(media) { m in tile(m).frame(width: 220, height: 220).clipShape(.rect(cornerRadius: 12)) }
                }
            }
        }
    }

    private func tile(_ m: Media) -> some View {
        Button { open(m) } label: {
            ZStack {
                if let f = m.file {
                    LocalImage(file: f, maxPixel: 900)
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.12))
                        .overlay { Image(systemName: m.isVideo ? "video" : "photo").foregroundStyle(.secondary) }
                }
                if m.isVideo {
                    Image(systemName: m.videoFile != nil ? "play.circle.fill" : "icloud.and.arrow.down")
                        .font(.system(size: 44))
                        .foregroundStyle(.white, .black.opacity(0.35))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct MediaViewerView: View {
    @Environment(\.dismiss) private var dismiss
    let media: Media
    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if media.isVideo, media.videoFile != nil || media.streamURL != nil {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .overlay {
                        if player == nil {
                            Label(
                                failed ? "Video şu an oynatılamıyor" : (media.videoFile != nil ? "iCloud'dan iniyor…" : "Video yükleniyor…"),
                                systemImage: failed ? "icloud.slash" : "icloud.and.arrow.down"
                            )
                            .foregroundStyle(.white)
                        }
                    }
                    .task {
                        if let v = media.videoFile, let url = await PhoneMedia.playable(v) {
                            player = AVPlayer(url: url)
                            player?.play()
                        } else if let stream = media.streamURL {
                            player = AVPlayer(url: stream)
                            player?.play()
                        } else {
                            failed = true
                        }
                    }
                    .onDisappear { player?.pause() }
            } else if let f = media.file {
                LocalImage(file: f, maxPixel: 2400, fill: false)
            } else {
                Text("Bu video telefonda yok. Kaynağında izlemek için ⋯ → Kaynağında aç.")
                    .foregroundStyle(.white).padding()
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white, .black.opacity(0.4))
            }
            .padding()
        }
    }
}

struct QuoteBox: View {
    let item: Item
    let open: (Media) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.author ?? "").font(.subheadline.weight(.semibold))
            if !item.text.isEmpty { Text(item.text).font(.callout) }
            MediaStrip(media: item.media, open: open)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 12))
    }
}

private extension String {
    /// Plain text shown with tappable links: Markdown is applied, so its
    /// special characters (other than URLs) are escaped.
    var markdownSafe: String {
        var s = self
        for c in ["\\", "*", "_", "`", "[", "]", "#", "~", ">"] { s = s.replacingOccurrences(of: c, with: "\\" + c) }
        return s
    }
}


extension Media {
    /// A direct video stream the phone can play online when no local or iCloud copy is stored.
    var streamURL: URL? {
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

extension Item {
    /// Has a video whose file is not on this device.
    var needsVideoFile: Bool { media.contains { $0.isVideo && $0.videoFile == nil } }
}
