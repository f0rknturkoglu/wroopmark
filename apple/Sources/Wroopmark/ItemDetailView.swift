import SwiftUI

struct ItemDetailView: View {
    @Environment(AppModel.self) private var model
    let item: Item
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    private var liveItem: Item {
        model.items.first(where: { $0.id == item.id }) ?? item
    }

    private var currentFolder: Folder? {
        if let fid = liveItem.folderId, let f = model.folders.first(where: { $0.id == fid }) {
            return f
        }
        if case .folder(let fid, _) = model.scope, let f = model.folders.first(where: { $0.id == fid }) {
            return f
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if model.scope == .all, let f = currentFolder {
                    HStack(spacing: 7) {
                        Image(nsImage: FolderIcons.image(forFolder: f.name))
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                            .foregroundStyle(Theme.accent)
                        Text("Klasör:")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(f.name)
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(Theme.accent)
                        Spacer()
                        Button("Klasöre Git") {
                            model.scope = .folder(id: f.id, name: f.name)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Theme.accent.opacity(0.18), lineWidth: 1)
                    )
                }
                if let error = loadError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Detaylar yüklenemedi: \(error)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Tekrar Dene") {
                            Task {
                                do {
                                    let full: Item = try await model.core.call(["cmd": "get", "id": item.id])
                                    fullOCR = full.ocr
                                    loadError = nil
                                } catch {
                                    loadError = error.localizedDescription
                                }
                            }
                        }
                        .controlSize(.small)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                if let title = item.title, !title.isEmpty {
                    Text(title).font(.system(size: 19, weight: .semibold)).textSelection(.enabled)
                }
                if !item.text.isEmpty {
                    Text(linkified(item.text))
                        .font(.system(size: 15))
                        .lineSpacing(4.5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Videos show as their poster with a play button and play in
                // the lightbox. A live AppKit player in this scrolling column
                // makes SwiftUI drop clicks on every control below it (tags,
                // note, folder), and would start a player on every selection.
                if !liveItem.media.isEmpty {
                    MediaGallery(media: liveItem.media, stacked: liveItem.isPhotoCarousel) {
                        model.openViewer(owner: liveItem, fromQuote: false, index: $0)
                    }
                }
                if let quote = liveItem.quote?.item {
                    QuoteCard(item: quote) { model.openViewer(owner: liveItem, fromQuote: true, index: $0) }
                }
                if let ocr = fullOCR, !ocr.isEmpty {
                    DisclosureGroup {
                        Text(ocr)
                            .font(.system(size: 12.5, design: .rounded))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    } label: {
                        Label("Görseldeki yazı", systemImage: "text.viewfinder")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                section("Klasör") {
                    HStack {
                        Menu {
                            if !model.folders.isEmpty {
                                ForEach(model.folders) { f in
                                    Button {
                                        Task { await model.moveToFolder(id: liveItem.id, folderID: f.id) }
                                    } label: {
                                        HStack {
                                            Text(f.name)
                                            if (liveItem.folderId ?? currentFolder?.id) == f.id { Image(systemName: "checkmark") }
                                        }
                                    }
                                }
                                Divider()
                            }
                            if liveItem.folderId != nil || currentFolder != nil {
                                Button("Klasörden çıkar") {
                                    Task { await model.moveToFolder(id: liveItem.id, folderID: nil) }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if let f = currentFolder {
                                    Image(nsImage: FolderIcons.image(forFolder: f.name))
                                        .renderingMode(.template)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 13, height: 13)
                                        .foregroundStyle(Theme.accent)
                                } else {
                                    Image(systemName: "folder")
                                        .foregroundStyle(.secondary)
                                }
                                Text(currentFolder?.name ?? "Klasör seçilmedi")
                                    .foregroundStyle(currentFolder != nil ? .primary : .secondary)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12.5, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Theme.hairline, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .menuStyle(.borderlessButton)
                        Spacer()
                    }
                }
                section("Etiketler") {
                    TagEditor(tags: item.tags, all: model.tags) { tags in
                        Task { await model.setTags(item.id, tags) }
                    }
                }
                section("Not") {
                    TextEditor(text: $note)
                        .font(.system(size: 13.5))
                        .frame(minHeight: 64)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Theme.hairline, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .focused($noteFocused)
                        .onChange(of: noteFocused) { _, focused in if !focused { saveNote() } }
                }
                if !item.links.isEmpty {
                    section("Linkler") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(item.links, id: \.self) { link in
                                if let url = URL(string: link) {
                                    Link(destination: url) {
                                        Label(link.replacingOccurrences(of: "https://", with: ""), systemImage: "link")
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    .font(.system(size: 13))
                                }
                            }
                        }
                    }
                }

                actions
                footer
            }
            .padding(24)
            .frame(maxWidth: 660, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { note = item.note ?? "" }
        .task(id: item.id) {
            do {
                let full: Item = try await model.core.call(["cmd": "get", "id": item.id])
                fullOCR = full.ocr
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
        }
        .onDisappear(perform: saveNote)
    }

    /// The list rows carry no OCR text; the detail loads it with the item.
    @State private var fullOCR: String?
    @State private var loadError: String?

    private var header: some View {
        let platform = Platform(rawValue: item.platform) ?? .web
        return HStack(spacing: 10) {
            Avatar(name: item.author ?? platform.label, size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.authorName ?? item.author ?? URL(string: item.url)?.host() ?? platform.label)
                    .font(.system(size: 14, weight: .semibold))
                HStack(spacing: 6) {
                    if let h = item.authorHandle { Text("@\(h)") }
                    Label(platform.label, systemImage: platform.symbol)
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if let created = item.created {
                Text(created.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Theme.locale)))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                if let url = URL(string: item.url) { NSWorkspace.shared.open(url) }
            } label: { Label("Kaynağında aç", systemImage: "arrow.up.right.square") }
                .buttonStyle(.borderedProminent)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url, forType: .string)
            } label: { Label("Kopyala", systemImage: "doc.on.doc") }
            if item.needsDownload {
                Button {
                    Task { await model.downloadMedia(item.id) }
                } label: {
                    Label(item.platform == "youtube" ? "Videoyu lokale indir" : "Medyayı indir", systemImage: "arrow.down.circle")
                }
                .disabled(model.isBusy)
            }
            Spacer()
            Button(role: .destructive) {
                model.requestDelete([item.id])
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Kaydı sil")
            .help("Sil")
        }
        .controlSize(.regular)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Kaydedildi \(item.saved.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(Theme.locale)))")
                .monospacedDigit()
            Text(item.id).textSelection(.enabled)
        }
        .font(.system(size: 11)).foregroundStyle(.tertiary)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased(with: Locale(identifier: "tr")))
                .font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
            content()
        }
    }

    private func saveNote() {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (item.note ?? "") else { return }
        Task { await model.setNote(item.id, trimmed) }
    }

    /// Makes URLs in post text clickable. The detail redraws whenever the
    /// library refreshes; the detector and its result are kept per text.
    private func linkified(_ text: String) -> AttributedString {
        if let hit = Self.linkCache.object(forKey: text as NSString) { return hit.value }
        var s = AttributedString(text)
        if let detector = Self.detector {
            for m in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range, in: text), let ar = Range(r, in: s), let url = m.url else { continue }
                s[ar].link = url
                s[ar].foregroundColor = Theme.accent
            }
        }
        Self.linkCache.setObject(Linked(s), forKey: text as NSString)
        return s
    }

    private final class Linked {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let linkCache: NSCache<NSString, Linked> = {
        let c = NSCache<NSString, Linked>()
        c.countLimit = 64
        return c
    }()
}

/// Chips with remove buttons, an inline field with completion, and the
/// most used tags one click away.
struct TagEditor: View {
    let tags: [String]
    let all: [TagCount]
    let onChange: ([String]) -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    TagChip(name: tag, removable: true, remove: { onChange(tags.filter { $0 != tag }) })
                }
                TextField(tags.isEmpty ? "Etiket ekle (Enter)" : "ekle…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .frame(width: 130)
                    .padding(.vertical, 3)
                    .onSubmit { add(draft) }
            }
            let options = suggestions
            if !options.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(options, id: \.key) { tag in
                        Button { add(tag.name) } label: {
                            Text("+ \(tag.name)")
                                .font(.system(size: 11.5))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Theme.hairline, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var suggestions: [TagCount] {
        let have = Set(tags.map { $0.lowercased() })
        let free = all.filter { !have.contains($0.name.lowercased()) }
        let q = draft.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return Array(free.sorted { $0.count > $1.count }.prefix(8)) }
        return Array(free.filter { $0.name.localizedCaseInsensitiveContains(q) }.prefix(8))
    }

    private func add(_ text: String) {
        let new = parseTags(text).filter { t in !tags.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }
        draft = ""
        if !new.isEmpty { onChange(tags + new) }
    }
}

/// Used by the bulk tag sheet.
struct TagSuggestions: View {
    let current: [String]
    let all: [TagCount]
    let pick: (String) -> Void

    var body: some View {
        let lower = Set(current.map { $0.lowercased() })
        let options = all.filter { !lower.contains($0.name.lowercased()) }.sorted { $0.count > $1.count }.prefix(12)
        FlowLayout(spacing: 5) {
            ForEach(Array(options), id: \.key) { tag in
                Button { pick(tag.name) } label: {
                    Text("+ \(tag.name)")
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Theme.hairline, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// One medium full width; several as an even two-column grid.
struct MediaGallery: View {
    let media: [Media]
    /// Photo carousels (TikTok) show as one stacked deck; a click opens the
    /// viewer at the first photo, and ← → go through the rest.
    var stacked = false
    let open: (Int) -> Void

    var body: some View {
        if media.count == 1, let m = media.first {
            tile(m, index: 0)
                .aspectRatio(min(max(m.aspect ?? 1.5, 0.6), 2.4), contentMode: .fit)
        } else if stacked {
            PhotoStack(media: media) { open(0) }
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(Array(media.enumerated()), id: \.element.url) { i, m in
                    tile(m, index: i).frame(height: 170)
                }
            }
        }
    }

    private func tile(_ m: Media, index: Int) -> some View {
        ZStack {
            if let file = m.file {
                Color.clear.overlay { LocalImage(file: file, maxPixel: 1200) }.clipped()
            } else {
                Rectangle().fill(Theme.hairline)
                    .overlay(Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary))
            }
            if m.isVideo {
                Image(systemName: m.videoFile != nil ? "play.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white, .black.opacity(0.45))
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        // High priority: inside a feed post or card the post's own click
        // (select / open) would otherwise swallow it.
        .highPriorityGesture(TapGesture().onEnded { open(index) })
        .help(m.alt ?? (m.isVideo ? (m.videoFile != nil ? "Oynat" : "Video henüz indirilmedi") : "Büyüt"))
    }
}

/// Several photos as a deck: the first on top, two more peeking out behind
/// it, and the count.
struct PhotoStack: View {
    let media: [Media]
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let top = media[0]
        let aspect = min(max(top.aspect ?? 0.75, 0.6), 1.6)
        ZStack {
            ForEach(Array(media.prefix(3).enumerated().reversed()), id: \.element.url) { i, m in
                card(m)
                    .rotationEffect(.degrees(i == 0 ? 0 : (i == 1 ? 3.5 : -4) * (hovering ? 1.6 : 1)))
                    .offset(x: CGFloat(i) * (hovering ? 14 : 8), y: CGFloat(i) * -4)
                    .scaleEffect(1 - CGFloat(i) * 0.04)
                    .shadow(color: .black.opacity(i == 0 ? 0.25 : 0.12), radius: i == 0 ? 8 : 4, y: 2)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .padding(.trailing, 18).padding(.top, 8)
        .overlay(alignment: .bottomLeading) {
            Label("\(media.count)", systemImage: "square.stack.fill")
                .font(.system(size: 12, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(10)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .highPriorityGesture(TapGesture().onEnded(open))
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.25), value: hovering)
        .help("\(media.count) fotoğraf — tıkla, ← → ile gez")
    }

    private func card(_ m: Media) -> some View {
        Color.clear
            .overlay {
                if let file = m.file {
                    LocalImage(file: file, maxPixel: 1200)
                } else {
                    Rectangle().fill(Theme.hairline)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.15)))
    }
}

struct QuoteCard: View {
    let item: Item
    let open: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AuthorLine(item: item)
            if !item.text.isEmpty {
                Text(item.text).font(.system(size: 13.5)).lineSpacing(3).textSelection(.enabled)
            }
            if !item.media.isEmpty { MediaGallery(media: item.media, open: open) }
        }
        .padding(12)
        .background(Theme.hairline.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }
}
