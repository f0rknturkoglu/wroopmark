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
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header
                if model.scope == .all, let f = currentFolder {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(nsImage: FolderIcons.image(forFolder: f.name))
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                            .foregroundStyle(Theme.accent)
                        Text("Klasör:")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(f.name)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                        Spacer(minLength: Theme.Spacing.sm)
                        Button {
                            model.scope = .folder(id: f.id, name: f.name)
                        } label: {
                            Label("Klasöre Git", systemImage: "arrow.forward")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(Theme.Stroke.subtleFill, in: .rect(cornerRadius: Theme.Radius.sm))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                            .strokeBorder(Theme.Stroke.surfaceBorder, lineWidth: Theme.Stroke.hairlineWidth)
                    }
                }
                if let error = loadError {
                    HStack(spacing: Theme.Spacing.sm) {
                        Label("Detaylar yüklenemedi", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: Theme.Spacing.sm)
                        Button {
                            detailReloadToken += 1
                        } label: {
                            Label("Tekrar Dene", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                    }
                    .padding(Theme.Spacing.md)
                    .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: Theme.Radius.sm))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                            .strokeBorder(Color.orange.opacity(0.28), lineWidth: Theme.Stroke.hairlineWidth)
                    }
                }
                if let title = item.title, !title.isEmpty {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                }
                if !item.text.isEmpty {
                    Text(linkified(item.text))
                        .font(.body)
                        .lineSpacing(4)
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
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, Theme.Spacing.sm)
                    } label: {
                        Label("Görseldeki yazı", systemImage: "text.viewfinder")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                section("Klasör") {
                    HStack {
                        Menu {
                            if model.folders.isEmpty && liveItem.folderId == nil && currentFolder == nil {
                                Button {} label: {
                                    Label("Henüz klasör yok", systemImage: "folder")
                                }
                                .disabled(true)
                            }
                            if !model.folders.isEmpty {
                                ForEach(model.folders) { f in
                                    Button {
                                        Task { await model.moveToFolder(id: liveItem.id, folderID: f.id) }
                                    } label: {
                                        HStack {
                                            Label {
                                                Text(f.name)
                                            } icon: {
                                                Image(nsImage: FolderIcons.image(forFolder: f.name))
                                            }
                                            if (liveItem.folderId ?? currentFolder?.id) == f.id { Image(systemName: "checkmark") }
                                        }
                                    }
                                }
                                Divider()
                            }
                            if liveItem.folderId != nil || currentFolder != nil {
                                Button {
                                    Task { await model.moveToFolder(id: liveItem.id, folderID: nil) }
                                } label: {
                                    Label("Klasörden çıkar", systemImage: "tray")
                                }
                            }
                        } label: {
                            HStack(spacing: Theme.Spacing.sm) {
                                if let f = currentFolder {
                                    Image(nsImage: FolderIcons.image(forFolder: f.name))
                                        .renderingMode(.template)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 16, height: 16)
                                        .foregroundStyle(Theme.accent)
                                } else {
                                    Image(systemName: "folder")
                                        .frame(width: 16, height: 16)
                                        .foregroundStyle(.secondary)
                                }
                                Text(currentFolder?.name ?? "Klasör seçilmedi")
                                    .foregroundStyle(currentFolder != nil ? .primary : .secondary)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.sm)
                            .background(Theme.Stroke.subtleFill, in: .rect(cornerRadius: Theme.Radius.sm))
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                    .strokeBorder(Theme.Stroke.surfaceBorder, lineWidth: Theme.Stroke.hairlineWidth)
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .controlSize(.regular)
                        Spacer()
                    }
                }
                section("Etiketler") {
                    TagEditor(tags: item.tags, all: model.tags) { tags in
                        Task { await model.setTags(item.id, tags) }
                    }
                }
                section("Not") {
                    ZStack(alignment: .topLeading) {
                        if note.isEmpty {
                            Text("Kayıtla ilgili not ekle…")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, Theme.Spacing.sm)
                                .padding(.vertical, Theme.Spacing.sm)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $note)
                            .font(.body)
                            .frame(minHeight: 72)
                            .scrollContentBackground(.hidden)
                            .padding(Theme.Spacing.xs)
                    }
                    .padding(Theme.Spacing.xs)
                    .background(Theme.Stroke.subtleFill, in: .rect(cornerRadius: Theme.Radius.sm))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                            .strokeBorder(
                                noteFocused ? Theme.accent.opacity(0.65) : Theme.Stroke.surfaceBorder,
                                lineWidth: noteFocused ? 1 : Theme.Stroke.hairlineWidth
                            )
                    }
                    .focused($noteFocused)
                    .onChange(of: noteFocused) { _, focused in if !focused { saveNote() } }
                }
                if !item.links.isEmpty {
                    section("Linkler") {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            ForEach(item.links, id: \.self) { link in
                                if let url = URL(string: link) {
                                    Link(destination: url) {
                                        Label(link.replacingOccurrences(of: "https://", with: ""), systemImage: "link")
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    .font(.callout)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                footer
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 660, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actions
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
                .frame(maxWidth: .infinity)
                .background(.background)
                .overlay(alignment: .top) { Divider() }
        }
        .onAppear { note = item.note ?? "" }
        .task(id: "\(item.id)#\(detailReloadToken)") {
            fullOCR = liveItem.ocr
            loadError = nil
            do {
                let full: Item = try await model.core.call(.get(id: item.id))
                fullOCR = full.ocr
                loadError = nil
            } catch is CancellationError {
                return
            } catch {
                loadError = error.localizedDescription
            }
        }
        .onDisappear(perform: saveNote)
    }

    /// The list rows carry no OCR text; the detail loads it with the item.
    @State private var fullOCR: String?
    @State private var loadError: String?
    @State private var detailReloadToken = 0

    private var header: some View {
        let platform = Platform(rawValue: item.platform) ?? .web
        return HStack(alignment: .center, spacing: Theme.Spacing.md) {
            Avatar(name: item.author ?? platform.label, size: 40)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(item.authorName ?? item.author ?? URL(string: item.url)?.host() ?? platform.label)
                    .font(.headline)
                HStack(spacing: Theme.Spacing.sm) {
                    if let h = item.authorHandle { Text("@\(h)") }
                    Label(platform.label, systemImage: platform.symbol)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            if let created = item.created {
                Text(created.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Theme.locale)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            actionRow(compact: false)
            actionRow(compact: true)
        }
        .controlSize(.regular)
    }

    @ViewBuilder
    private func actionRow(compact: Bool) -> some View {
        let downloadTitle = item.platform == "youtube" ? "Videoyu lokale indir" : "Medyayı indir"
        HStack(spacing: Theme.Spacing.sm) {
            Button {
                if let url = URL(string: item.url) { NSWorkspace.shared.open(url) }
            } label: {
                Label("Kaynağında aç", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderedProminent)
            .fixedSize()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url, forType: .string)
            } label: {
                if compact {
                    Label("Bağlantıyı kopyala", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                } else {
                    Label("Kopyala", systemImage: "doc.on.doc")
                }
            }
            .buttonStyle(.bordered)
            .fixedSize()
            .accessibilityLabel("Bağlantıyı kopyala")
            .help("Bağlantıyı kopyala")

            if item.needsDownload {
                Button {
                    Task { await model.downloadMedia(item.id) }
                } label: {
                    if compact {
                        Label(downloadTitle, systemImage: "arrow.down.circle")
                            .labelStyle(.iconOnly)
                    } else {
                        Label(downloadTitle, systemImage: "arrow.down.circle")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(compact ? .small : .regular)
                .fixedSize()
                .disabled(model.isBusy)
                .accessibilityLabel(downloadTitle)
                .help(downloadTitle)
            }

            Spacer(minLength: Theme.Spacing.sm)

            Button(role: .destructive) {
                model.requestDelete([item.id])
            } label: {
                Label("Kaydı sil", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .fixedSize()
            .accessibilityLabel("Kaydı sil")
            .help("Sil")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Kaydedildi \(item.saved.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(Theme.locale)))")
                .monospacedDigit()
            Text(item.id)
                .textSelection(.enabled)
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func saveNote() {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (item.note ?? "") else { return }
        Task { await model.setNote(item.id, trimmed) }
    }

    /// Makes URLs in post text clickable. The detail redraws whenever the
    /// library refreshes; the detector and its result are kept per text on `@MainActor`.
    private func linkified(_ text: String) -> AttributedString {
        if let hit = Self.linkCache[text] { return hit }
        var s = AttributedString(text)
        if let detector = Self.detector {
            for m in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range, in: text), let ar = Range(r, in: s), let url = m.url else { continue }
                var attrs = AttributeContainer()
                attrs.link = url
                attrs.foregroundColor = Theme.accent
                s[ar].mergeAttributes(attrs)
            }
        }
        if Self.linkCache.count >= 64, let oldest = Self.linkCacheOrder.first {
            Self.linkCache.removeValue(forKey: oldest)
            Self.linkCacheOrder.removeFirst()
        }
        Self.linkCache[text] = s
        Self.linkCacheOrder.append(text)
        return s
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static var linkCache: [String: AttributedString] = [:]
    private static var linkCacheOrder: [String] = []
}

/// Chips with remove buttons, an inline field with completion, and the
/// most used tags one click away.
struct TagEditor: View {
    let tags: [String]
    let all: [TagCount]
    let onChange: ([String]) -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            FlowLayout(spacing: Theme.Spacing.sm) {
                ForEach(tags, id: \.self) { tag in
                    TagChip(name: tag, removable: true, remove: { onChange(tags.filter { $0 != tag }) })
                }
                TextField(tags.isEmpty ? "Etiket ekle (Enter)" : "ekle…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .frame(width: 132)
                    .padding(.vertical, Theme.Spacing.xs)
                    .onSubmit { add(draft) }
            }
            let options = suggestions
            if !options.isEmpty {
                FlowLayout(spacing: Theme.Spacing.xs) {
                    ForEach(options, id: \.key) { tag in
                        TagSuggestionButton(name: tag.name) { add(tag.name) }
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
        FlowLayout(spacing: Theme.Spacing.xs) {
            ForEach(Array(options), id: \.key) { tag in
                TagSuggestionButton(name: tag.name) { pick(tag.name) }
            }
        }
    }
}

private struct TagSuggestionButton: View {
    let name: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("+ \(name)")
                .font(.caption.weight(.medium))
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.xs)
                .background(
                    hovering ? Theme.Stroke.subtleHoverFill : Theme.Stroke.subtleFill,
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .strokeBorder(
                            hovering ? Theme.Stroke.surfaceHoverBorder : Theme.Stroke.surfaceBorder,
                            lineWidth: Theme.Stroke.hairlineWidth
                        )
                }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
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
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: Theme.Spacing.sm),
                    GridItem(.flexible(), spacing: Theme.Spacing.sm),
                ],
                spacing: Theme.Spacing.sm
            ) {
                ForEach(Array(media.enumerated()), id: \.element.url) { i, m in
                    tile(m, index: i).frame(height: 176)
                }
            }
        }
    }

    private func tile(_ m: Media, index: Int) -> some View {
        ZStack {
            if let file = m.file {
                Color.clear.overlay { LocalImage(file: file, maxPixel: 1200) }.clipped()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay { Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary) }
            }
            if m.isVideo {
                Image(systemName: m.videoFile != nil ? "play.circle.fill" : "arrow.down.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white, .black.opacity(0.45))
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(.rect(cornerRadius: Theme.Radius.sm))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .strokeBorder(Theme.Stroke.mediaOutline, lineWidth: Theme.Stroke.hairlineWidth)
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .accessibilityAddTraits(.isButton)
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
        if let top = media.first {
            let aspect = min(max(top.aspect ?? 0.75, 0.6), 1.6)
            ZStack {
                ForEach(Array(media.prefix(3).enumerated().reversed()), id: \.element.url) { i, m in
                    card(m)
                        .rotationEffect(.degrees(i == 0 ? 0 : (i == 1 ? 3.5 : -4) * (hovering ? 1.6 : 1)))
                        .offset(x: CGFloat(i) * (hovering ? 16 : 8), y: CGFloat(i) * -4)
                        .scaleEffect(1 - CGFloat(i) * 0.04)
                        .shadow(color: .black.opacity(i == 0 ? 0.25 : 0.12), radius: i == 0 ? 8 : 4, y: 2)
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .padding(.trailing, Theme.Spacing.lg)
            .padding(.top, Theme.Spacing.sm)
            .overlay(alignment: .bottomLeading) {
                Label("\(media.count)", systemImage: "square.stack.fill")
                    .font(.caption.bold())
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(.black.opacity(0.62), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(Theme.Stroke.darkOverlayBorder, lineWidth: Theme.Stroke.hairlineWidth)
                    }
                    .padding(Theme.Spacing.md)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .accessibilityAddTraits(.isButton)
            .highPriorityGesture(TapGesture().onEnded(open))
            .onHover { hovering = $0 }
            .animation(.spring(duration: 0.25), value: hovering)
            .help("\(media.count) fotoğraf — tıkla, ← → ile gez")
        }
    }

    private func card(_ m: Media) -> some View {
        Color.clear
            .overlay {
                if let file = m.file {
                    LocalImage(file: file, maxPixel: 1200)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .clipShape(.rect(cornerRadius: Theme.Radius.sm))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .strokeBorder(Theme.Stroke.darkOverlayBorder, lineWidth: Theme.Stroke.hairlineWidth)
            }
    }
}

struct QuoteCard: View {
    let item: Item
    let open: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            AuthorLine(item: item)
            if !item.text.isEmpty {
                Text(item.text)
                    .font(.callout)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
            if !item.media.isEmpty { MediaGallery(media: item.media, open: open) }
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.Stroke.subtleFill, in: .rect(cornerRadius: Theme.Radius.lg))
        .containerShape(.rect(cornerRadius: Theme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.Stroke.surfaceBorder, lineWidth: Theme.Stroke.hairlineWidth)
        }
    }
}
