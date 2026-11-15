import AVKit
import SwiftUI

struct ItemView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var item: Item?
    @State private var note = ""
    @State private var newTag = ""
    @State private var confirmDelete = false
    @State private var viewer: Media?
    @State private var newFolder = false
    @State private var folderName = ""

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
                    if let s = item.summary, !s.isEmpty {
                        Label { Text(s) } icon: { Image(systemName: "sparkles") }
                            .font(.callout)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(PhoneTheme.accent.opacity(0.08), in: .rect(cornerRadius: 12))
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
                }
                .padding()
            } else {
                ProgressView().padding(.top, 80)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let item, let url = URL(string: item.url) {
                ToolbarItem(placement: .topBarTrailing) { ShareLink(item: url) }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Link(destination: url) { Label("Kaynağında aç", systemImage: "safari") }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Sil", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
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
        .alert("Yeni klasör", isPresented: $newFolder) {
            TextField("Ad (alt klasör için: Ders/Matematik)", text: $folderName)
            Button("Oluştur ve taşı") { Task { await createFolder() } }
            Button("Vazgeç", role: .cancel) {}
        }
        .task(id: id) {
            item = await model.refresh(id)
            note = item?.note ?? ""
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
                Text(model.folders.first { $0.id == item.folderId }?.name.replacingOccurrences(of: "/", with: " › ") ?? "Klasör seçilmedi")
            }
        }
    }

    /// Makes the folder (or finds it, any case) and files the item in it.
    /// `Ders/Matematik` makes a subfolder.
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
            tile(m).frame(maxWidth: .infinity).aspectRatio(m.aspect ?? 1.3, contentMode: .fit).clipShape(.rect(cornerRadius: 12))
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

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if media.isVideo, let v = media.videoFile {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear {
                        player = AVPlayer(url: Core.shared.mediaURL(v))
                        player?.play()
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
