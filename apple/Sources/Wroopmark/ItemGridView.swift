import SwiftUI

/// The library as uniform cards or as a reading list. Click selects,
/// ⌘-click toggles, ⇧-click extends; double-click opens the post.
struct ItemGridView: View {
    @Environment(AppModel.self) private var model
    @State private var anchor: String?

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 330), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch model.layout {
                case .grid:
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(model.items) { item in
                            ItemCard(item: item, selected: model.selection.contains(item.id))
                                .modifier(Selectable(item: item, owner: self))
                        }
                    }
                    .padding(16)
                case .list:
                    LazyVStack(spacing: 0) {
                        ForEach(model.items) { item in
                            ItemRow(item: item, selected: model.selection.contains(item.id))
                                .modifier(Selectable(item: item, owner: self))
                            Divider().opacity(0.5)
                        }
                    }
                    .padding(.horizontal, 8)
                case .feed:
                    LazyVStack(spacing: 16) {
                        ForEach(model.items) { item in
                            FeedPost(item: item, selected: model.selection.contains(item.id))
                                .modifier(Selectable(item: item, owner: self))
                        }
                    }
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                }
            }
        }
        .background(Theme.canvas)
        .safeAreaInset(edge: .top, spacing: 0) { TagStrip() }
        .overlay {
            if model.items.isEmpty && !model.isLoading {
                if model.effectiveQuery.isEmpty {
                    ContentUnavailableView {
                        Label("Kütüphane boş", systemImage: "bookmark")
                    } description: {
                        Text("Tarayıcı eklentisiyle X yer imlerini içe aktar ya da ⌘N ile bir bağlantı ekle.")
                    }
                } else {
                    ContentUnavailableView.search(text: model.query)
                }
            }
        }
        .navigationTitle("")
    }

    private var title: String {
        switch model.scope {
        case .all: "Tümü"
        case .untagged: "Etiketsiz"
        case .platform(let p): p.label
        case .tag(let key): "#\(key)"
        case .folder(_, let name): name
        case .links(let cat): cat != nil ? "\(cat!.label) linkleri" : "Link havuzu"
        case .photos: "Fotoğraflar"
        case .videos: "Videolar"
        case .triage: "Ayıkla"
        }
    }

    func select(_ item: Item) {
        model.selection = [item.id]
        anchor = item.id
    }

    func toggle(_ item: Item) {
        if model.selection.contains(item.id) { model.selection.remove(item.id) } else { model.selection.insert(item.id) }
        anchor = item.id
    }

    func extend(to item: Item) {
        guard let anchor, let a = model.items.firstIndex(where: { $0.id == anchor }),
              let b = model.items.firstIndex(where: { $0.id == item.id }) else { return select(item) }
        model.selection = Set(model.items[min(a, b)...max(a, b)].map(\.id))
    }

    func open(_ item: Item) {
        if let url = URL(string: item.url) { NSWorkspace.shared.open(url) }
    }

    @ViewBuilder
    func menu(for item: Item) -> some View {
        let ids = model.selection.contains(item.id) ? Array(model.selection) : [item.id]
        Button("Tarayıcıda aç") { open(item) }
        Button("Bağlantıyı kopyala") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url, forType: .string)
        }
        if item.needsDownload {
            Button("Medyayı indir") { Task { await model.downloadMedia(item.id) } }
        }
        Divider()
        Menu(ids.count > 1 ? "Klasöre taşı…" : "Klasöre taşı") {
            if !model.folders.isEmpty {
                ForEach(model.folders) { f in
                    Button {
                        Task { await model.moveItemsToFolder(ids: ids, folderID: f.id) }
                    } label: {
                        HStack {
                            Text(f.name)
                            if item.folderId == f.id && ids.count == 1 {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
            }
            if item.folderId != nil || ids.count > 1 {
                Button("Klasörden çıkar") {
                    Task { await model.moveItemsToFolder(ids: ids, folderID: nil) }
                }
            }
        }
        Button(ids.count > 1 ? "\(ids.count) kaydı etiketle…" : "Etiketle…") {
            model.selection = Set(ids)
            model.showBulkTags = true
        }
        Button(ids.count > 1 ? "\(ids.count) kaydı sil…" : "Sil…", role: .destructive) {
            model.requestDelete(ids)
        }
    }
}

/// Click handling shared by cards and rows.
///
/// One tap gesture reads the click count and modifiers from the event, so a
/// single click selects at once. (A separate `count: 2` gesture makes SwiftUI
/// hold every single click for the double-click interval.)
private struct Selectable: ViewModifier {
    @Environment(AppModel.self) private var model
    let item: Item
    let owner: ItemGridView

    func body(content: Content) -> some View {
        content
            .onTapGesture { ClickInfo.current.handle(single: owner.select(item), double: owner.open(item),
                                                     command: owner.toggle(item), shift: owner.extend(to: item)) }
            .contextMenu { owner.menu(for: item) }
            .onAppear {
                if item.id == model.items.last?.id { Task { await model.loadMore() } }
            }
    }
}

/// The click that is being handled, read from AppKit.
struct ClickInfo {
    let count: Int
    let flags: NSEvent.ModifierFlags

    @MainActor static var current: ClickInfo {
        let e = NSApp.currentEvent
        return ClickInfo(count: e?.clickCount ?? 1, flags: e?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? [])
    }

    /// The first click of a double click has already selected; the second opens.
    func handle(single: @autoclosure () -> Void, double: @autoclosure () -> Void,
                command: @autoclosure () -> Void = (), shift: @autoclosure () -> Void = ()) {
        if flags.contains(.command) { command() }
        else if flags.contains(.shift) { shift() }
        else if count >= 2 { double() }
        else { single() }
    }
}

/// Most used tags as one-click filters, plus the layout switch.
struct TagStrip: View {
    @Environment(AppModel.self) private var model

    private var scopeTitle: String {
        switch model.scope {
        case .all: "Tümü"
        case .untagged: "Etiketsiz"
        case .platform(let p): p.label
        case .tag(let key): "#\(key)"
        case .folder(_, let name): name
        case .links(let cat): cat != nil ? "\(cat!.label) linkleri" : "Link havuzu"
        case .photos: "Fotoğraflar"
        case .videos: "Videolar"
        case .triage: "Ayıkla"
        }
    }

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text(scopeTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                if model.total > 0 {
                    Text(model.total.formatted())
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
            }

            Divider().frame(height: 14).opacity(0.5)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if !model.filters.isEmpty {
                        Button { model.showFilters = true } label: {
                            Label("\(model.filters.activeCount) filtre", systemImage: "line.3.horizontal.decrease")
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.accent, in: Capsule())
                        Button { model.filters = AdvancedFilters() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .frame(minWidth: 24, minHeight: 24)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Filtreleri temizle")
                        .help("Filtreleri temizle")
                    }
                    if case .tag(let key) = model.scope {
                        TagChip(name: key, selected: true, removable: true, action: {}, remove: { model.scope = .all })
                    }
                    ForEach(model.topTags, id: \.key) { tag in
                        if model.scope != .tag(tag.key) {
                            TagChip(name: tag.name, action: { model.filter(tag: tag.name) })
                                .help("\(tag.count) kayıt")
                        }
                    }
                    if model.tags.isEmpty {
                        Text("Henüz etiket yok — bir kaydı seçip etiket ekle ya da kartın üstündeki # düğmesini kullan.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }
            Picker("Görünüm", selection: $model.layout) {
                Image(systemName: "square.grid.2x2").tag(LibraryLayout.grid)
                Image(systemName: "list.bullet").tag(LibraryLayout.list)
                Image(systemName: "rectangle.grid.1x2").tag(LibraryLayout.feed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 112)
            .help("Kart / liste / akış görünümü")
        }
        .padding(.horizontal, 16)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Fixed-height card: cover on top when there is one, then author, text and
/// tags. Every card in a row lines up regardless of content.
struct ItemCard: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let selected: Bool
    @State private var hovering = false
    @State private var tagging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let cover = item.cover, let file = cover.file {
                // The image fills a fixed box; its own size never widens the card.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.coverHeight)
                    .overlay { LocalImage(file: file) }
                    .clipped()
                    .overlay(alignment: .bottomLeading) { MediaBadge(item: item) }
            }
            VStack(alignment: .leading, spacing: 8) {
                AuthorLine(item: item)
                Text(item.headline.isEmpty ? (item.quote?.item.text ?? "") : item.headline)
                    .font(.system(size: 13.5))
                    .lineSpacing(2.5)
                    .foregroundStyle(.primary.opacity(0.92))
                    .lineLimit(item.cover == nil ? 8 : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item.cover == nil, let quote = item.quote?.item, !item.headline.isEmpty {
                    QuoteSnippet(item: quote)
                }
                Spacer(minLength: 0)
                CardTags(tags: item.tags)
            }
            .padding(12)
        }
        .frame(minHeight: Theme.cardHeight)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.hairline, lineWidth: selected ? 2 : 1)
        )
        // Only the hovered card casts a soft shadow: a shadow on every card
        // is an offscreen pass per card on every scroll frame.
        .shadow(color: .black.opacity(hovering ? 0.12 : 0), radius: hovering ? 8 : 0, y: hovering ? 3 : 0)
        .overlay(alignment: .topTrailing) {
            if hovering || tagging {
                Button { tagging = true } label: {
                    Image(systemName: "number")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Etiketleri düzenle")
                .padding(8)
                .help("Etiketle")
                .popover(isPresented: $tagging, arrowEdge: .bottom) {
                    TagEditor(tags: item.tags, all: model.tags) { tags in
                        Task { await model.setTags(item.id, tags) }
                    }
                    .padding(14)
                    .frame(minWidth: 260, idealWidth: 300)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A whole post in the feed layout: full text and media at their own size,
/// read by scrolling. Media opens in the viewer.
struct FeedPost: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AuthorLine(item: item, showHandle: true)
            if let title = item.title, !title.isEmpty {
                Text(title).font(.system(size: 16, weight: .semibold))
            }
            if !item.text.isEmpty {
                Text(item.text)
                    .font(.system(size: 14.5))
                    .lineSpacing(3.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !item.media.isEmpty {
                // Tall (phone) media would fill several screens; capped.
                MediaGallery(media: item.media, stacked: item.isPhotoCarousel) {
                    model.openViewer(owner: item, fromQuote: false, index: $0)
                }
                    .frame(maxHeight: 560)
                    .frame(maxWidth: .infinity)
            }
            if let quote = item.quote?.item {
                QuoteCard(item: quote) { model.openViewer(owner: item, fromQuote: true, index: $0) }
            }
            if !item.tags.isEmpty { CardTags(tags: item.tags) }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.hairline, lineWidth: selected ? 2 : 1)
        )
        .contentShape(Rectangle())
    }
}

/// Compact reading row for the list layout.
struct ItemRow: View {
    let item: Item
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(name: item.author ?? item.platform, size: 32)
            VStack(alignment: .leading, spacing: 5) {
                AuthorLine(item: item, showAvatar: false, showHandle: true)
                Text(item.headline.isEmpty ? (item.quote?.item.text ?? "") : item.headline)
                    .font(.system(size: 13.5))
                    .lineSpacing(2.5)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !item.tags.isEmpty { CardTags(tags: item.tags) }
            }
            if let file = item.cover?.file {
                LocalImage(file: file, maxPixel: 240)
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .bottomLeading) { MediaBadge(item: item, compact: true) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(selected ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// Video / count / offline marker on a cover.
struct MediaBadge: View {
    let item: Item
    var compact = false

    var body: some View {
        let videos = item.allMedia.filter(\.isVideo)
        let missing = item.needsDownload
        HStack(spacing: 4) {
            if !videos.isEmpty { Image(systemName: "play.fill").accessibilityHidden(true) }
            if item.isPhotoCarousel { Image(systemName: "square.stack.fill").accessibilityHidden(true) }
            if item.allMedia.count > 1 && !compact {
                Text("\(item.allMedia.count)").monospacedDigit()
            }
            if missing {
                Image(systemName: "icloud.and.arrow.down")
                    .accessibilityHidden(true)
                    .help("Bir kısmı henüz indirilmedi")
            }
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(6)
        .opacity(videos.isEmpty && item.allMedia.count < 2 && !missing ? 0 : 1)
    }
}

struct QuoteSnippet: View {
    let item: Item

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1).fill(Theme.accent.opacity(0.5)).frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                if let a = item.author { Text(a).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
                Text(item.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One line of tags; overflow collapses to "+n".
struct CardTags: View {
    @Environment(AppModel.self) private var model
    let tags: [String]

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: 4) {
                ForEach(tags.prefix(3), id: \.self) { tag in
                    TagChip(name: tag, action: { model.filter(tag: tag) })
                }
                if tags.count > 3 {
                    Text("+\(tags.count - 3)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }
}

struct AuthorLine: View {
    let item: Item
    var showAvatar = true
    var showHandle = false

    var body: some View {
        let platform = Platform(rawValue: item.platform) ?? .web
        HStack(spacing: 6) {
            if showAvatar { Avatar(name: item.author ?? platform.label, size: 20) }
            Text(displayName).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            if showHandle, let h = item.authorHandle, item.authorName != nil {
                Text("@\(h)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: platform.symbol).font(.system(size: 10)).foregroundStyle(.tertiary)
            Text((item.created ?? item.saved).short)
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                .fixedSize()
        }
    }

    private var displayName: String {
        if let n = item.authorName, !n.isEmpty { return n }
        if let h = item.authorHandle { return "@\(h)" }
        return URL(string: item.url)?.host() ?? "—"
    }
}

/// Wrapping row layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = arrange(width: bounds.width, subviews: subviews)
        for (sub, origin) in zip(subviews, placed.origins) {
            sub.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}
