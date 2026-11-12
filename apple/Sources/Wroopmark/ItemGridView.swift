import SwiftUI

/// The library as uniform cards or as a reading list. Click selects,
/// ⌘-click toggles, ⇧-click extends; double-click opens the post.
struct ItemGridView: View {
    @Environment(AppModel.self) private var model
    @State private var anchor: String?
    @State private var columnCount = 3

    /// Card columns from the width the scroll view really has. `LazyVGrid`
    /// alone caches the column set from an earlier (inspector-less) layout,
    /// so the column count is state and the grid is rebuilt when it changes.
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.md), count: columnCount)
    }

    private nonisolated static func columns(forWidth width: CGFloat) -> Int {
        let available = max(Theme.Layout.cardMinWidth, width - Theme.Spacing.lg * 2)
        return max(1, Int((available + Theme.Spacing.md) / (Theme.Layout.cardMinWidth + Theme.Spacing.md)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch model.layout {
                case .grid:
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: Theme.Spacing.md) {
                        ForEach(model.items) { item in
                            let selected = model.selection.contains(item.id)
                            ItemCard(item: item, selected: selected)
                                .equatable()
                                .modifier(Selectable(item: item, selected: selected, owner: self))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(columnCount)
                    .padding(Theme.Spacing.lg)
                case .list:
                    LazyVStack(spacing: Theme.Spacing.xs) {
                        ForEach(model.items) { item in
                            let selected = model.selection.contains(item.id)
                            ItemRow(item: item, selected: selected)
                                .equatable()
                                .modifier(Selectable(item: item, selected: selected, owner: self))
                        }
                    }
                    .padding(Theme.Spacing.lg)
                case .feed:
                    LazyVStack(spacing: Theme.Spacing.md) {
                        ForEach(model.items) { item in
                            let selected = model.selection.contains(item.id)
                            FeedPost(item: item, selected: selected)
                                .equatable()
                                .modifier(Selectable(item: item, selected: selected, owner: self))
                        }
                    }
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                    .padding(Theme.Spacing.lg)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.top)
        .onGeometryChange(for: Int.self) { proxy in
            Self.columns(forWidth: proxy.size.width)
        } action: { count in
            if count != columnCount { columnCount = count }
        }
        .safeAreaInset(edge: .top, spacing: 0) { TagStrip() }
        .overlay {
            if model.items.isEmpty && !model.isLoading {
                if let err = model.gridError {
                    ContentUnavailableView {
                        Label("Kütüphane yüklenemedi", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(err)
                    } actions: {
                        Button {
                            Task { await model.reload() }
                        } label: {
                            Label("Tekrar Dene", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.regular)
                    }
                    .padding(Theme.Spacing.lg)
                } else if model.effectiveQuery.isEmpty {
                    ContentUnavailableView {
                        Label("Kütüphane boş", systemImage: "bookmark")
                    } description: {
                        Text("Tarayıcı eklentisiyle X yer imlerini içe aktar ya da ⌘N ile bir bağlantı ekle.")
                    }
                    .padding(Theme.Spacing.lg)
                } else {
                    ContentUnavailableView.search(text: model.query)
                        .padding(Theme.Spacing.lg)
                }
            }
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
        Button { open(item) } label: {
            Label("Tarayıcıda aç", systemImage: "arrow.up.right.square")
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url, forType: .string)
        } label: {
            Label("Bağlantıyı kopyala", systemImage: "doc.on.doc")
        }
        if item.needsDownload {
            Button { Task { await model.downloadMedia(item.id) } } label: {
                Label("Medyayı indir", systemImage: "arrow.down.circle")
            }
        }
        Divider()
        Menu(ids.count > 1 ? "Klasöre taşı…" : "Klasöre taşı") {
            if !model.folders.isEmpty {
                ForEach(model.folders) { f in
                    Button {
                        Task { await model.moveItemsToFolder(ids: ids, folderID: f.id) }
                    } label: {
                        HStack {
                            Label {
                                Text(f.name)
                            } icon: {
                                Image(nsImage: FolderIcons.image(forFolder: f.name))
                            }
                            if item.folderId == f.id && ids.count == 1 {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
            }
            if item.folderId != nil || ids.count > 1 {
                Button {
                    Task { await model.moveItemsToFolder(ids: ids, folderID: nil) }
                } label: {
                    Label("Klasörden çıkar", systemImage: "tray")
                }
            }
        }
        Button {
            model.selection = Set(ids)
            model.showBulkTags = true
        } label: {
            Label(ids.count > 1 ? "\(ids.count) kaydı etiketle…" : "Etiketle…", systemImage: "tag")
        }
        Button(role: .destructive) {
            model.requestDelete(ids)
        } label: {
            Label(ids.count > 1 ? "\(ids.count) kaydı sil…" : "Sil…", systemImage: "trash")
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
    let selected: Bool
    let owner: ItemGridView

    func body(content: Content) -> some View {
        content
            .onTapGesture { ClickInfo.current.handle(single: owner.select(item), double: owner.open(item),
                                                     command: owner.toggle(item), shift: owner.extend(to: item)) }
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
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

/// Most used tags as one-click filters, plus the save-search action.
struct TagStrip: View {
    @Environment(AppModel.self) private var model

    private var scopeTitle: String {
        switch model.scope {
        case .all: "Tümü"
        case .untagged: "Etiketsiz"
        case .platform(let p): p.label
        case .tag(let key): "#\(key)"
        case .folder(_, let name): name
        case .links(let cat): cat.map { "\($0.label) linkleri" } ?? "Link havuzu"
        case .photos: "Fotoğraflar"
        case .videos: "Videolar"
        case .triage: "Ayıkla"
        case .saved(let saved): saved.name
        }
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                Text(scopeTitle)
                    .font(.subheadline.weight(.semibold))
                if model.total > 0 {
                    CountPill(value: model.total.formatted())
                }
            }

            Divider()
                .frame(height: 18)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.sm) {
                    if !model.filters.isEmpty {
                        TagStripActionCapsule(
                            title: "\(model.filters.activeCount) filtre",
                            symbol: "line.3.horizontal.decrease",
                            prominent: true
                        ) {
                            model.showFilters = true
                        }
                        Button { model.filters = AdvancedFilters() } label: {
                            Label("Filtreleri temizle", systemImage: "xmark.circle.fill")
                                .labelStyle(.iconOnly)
                                .frame(minWidth: Theme.Spacing.xxl, minHeight: Theme.Spacing.xxl)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Filtreleri temizle")
                        .help("Filtreleri temizle")
                    }
                    if !model.searchToSave.isEmpty {
                        TagStripActionCapsule(
                            title: "Aramayı kaydet",
                            symbol: "bookmark",
                            prominent: false
                        ) {
                            model.showSaveSearch = true
                        }
                        .help("Bu aramayı kenar çubuğuna ekle (⌘⇧S)")
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
                        Label("Etiket yok", systemImage: "tag")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Henüz etiket yok — bir kaydı seçip etiket ekle ya da kartın üstündeki # düğmesini kullan.")
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct TagStripActionCapsule: View {
    let title: String
    let symbol: String
    let prominent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .monospacedDigit()
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.xs)
                .foregroundStyle(prominent ? .white : Theme.accent)
                .background(
                    prominent
                        ? (hovering ? Theme.accent.opacity(0.9) : Theme.accent)
                        : Theme.accent.opacity(hovering ? 0.18 : 0.12),
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .strokeBorder(
                            prominent ? Color.white.opacity(0.16) : Theme.accent.opacity(hovering ? 0.36 : 0.18),
                            lineWidth: Theme.Stroke.hairlineWidth
                        )
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .font(.caption.weight(prominent ? .semibold : .medium))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Uniform-height Bento card: cover or editorial text header on top, synced
/// row baselines and concentric corners (`24pt` outer = `8pt` inner + `16pt` padding).
struct ItemCard: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let selected: Bool
    @State private var hovering = false
    @State private var tagging = false

    private let outerRadius: CGFloat = Theme.Radius.lg
    private let cardPadding: CGFloat = Theme.Spacing.lg
    private let innerRadius: CGFloat = Theme.Radius.sm
    private let slotHeight: CGFloat = 144
    private let minHeight: CGFloat = 336

    private var platform: Platform { Platform(rawValue: item.platform) ?? .web }
    private var primaryCopy: String {
        let h = item.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        if !h.isEmpty { return h }
        let q = item.quote?.item.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return q.isEmpty ? hostFallback : q
    }
    private var hostFallback: String {
        URL(string: item.url)?.host() ?? platform.label
    }
    private var hasCover: Bool { item.cover?.file != nil }

    var body: some View {
        cardContent
            .padding(cardPadding)
            .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity, alignment: .topLeading)
            .background(.background.secondary, in: .rect(cornerRadius: outerRadius))
            .containerShape(.rect(cornerRadius: outerRadius))
            .clipShape(.rect(cornerRadius: outerRadius))
            .overlay(alignment: .center) { cardBorder }
            // Only the hovered card casts a soft shadow: a shadow on every card
            // is an offscreen pass per card on every scroll frame.
            .shadow(color: .black.opacity(hovering ? 0.08 : 0), radius: hovering ? 8 : 0, y: hovering ? 4 : 0)
            .contentShape(RoundedRectangle(cornerRadius: outerRadius, style: .continuous))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
            .strokeBorder(
                selected
                    ? Theme.accent
                    : (hovering ? Theme.Stroke.surfaceHoverBorder : Theme.Stroke.surfaceBorder),
                lineWidth: selected ? Theme.Stroke.selectionWidth : Theme.Stroke.hairlineWidth
            )
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            AuthorLine(item: item)

            if hasCover, let cover = item.cover, let file = cover.file {
                // Framed concentric media slot inside 16pt card padding -> 8pt radius.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: slotHeight)
                    .overlay { LocalImage(file: file) }
                    .clipShape(.rect(cornerRadius: innerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                            .strokeBorder(Theme.Stroke.mediaOutline, lineWidth: Theme.Stroke.hairlineWidth)
                    }
                    .overlay(alignment: .bottomLeading) { MediaBadge(item: item) }

                Text(primaryCopy)
                    .font(.callout)
                    .lineSpacing(2)
                    .foregroundStyle(.primary.opacity(0.92))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Balanced editorial slot for text-only posts so row density stays uniform.
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Label(platform.label, systemImage: platform.symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                        Text(hostFallback)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        Spacer(minLength: Theme.Spacing.xs)
                    }
                    Text(primaryCopy)
                        .font(.callout.weight(.medium))
                        .lineSpacing(3)
                        .foregroundStyle(.primary.opacity(0.92))
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .padding(Theme.Spacing.md)
                .frame(maxWidth: .infinity, minHeight: slotHeight, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.Stroke.subtleFill, in: .rect(cornerRadius: innerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                        .strokeBorder(Theme.Stroke.surfaceBorder, lineWidth: Theme.Stroke.hairlineWidth)
                }

                if let quote = item.quote?.item, !item.headline.isEmpty {
                    QuoteSnippet(item: quote)
                } else if !item.text.isEmpty, item.title?.isEmpty == false {
                    Text(item.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // A cover card spends its flexible space between the text and the
            // metadata; a text-only card lets its editorial block fill it, so
            // the card never looks half empty.
            if hasCover { Spacer(minLength: 0) }

            HStack(alignment: .center, spacing: Theme.Spacing.sm) {
                if !item.tags.isEmpty {
                    CardTags(tags: item.tags)
                } else {
                    Text(hostFallback)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Spacing.xs)
                Button { tagging = true } label: {
                    Label("Etiketleri düzenle", systemImage: "number")
                        .labelStyle(.iconOnly)
                        .frame(width: Theme.Spacing.xxl, height: Theme.Spacing.xxl)
                        .background(Theme.Stroke.subtleHoverFill, in: Circle())
                        .overlay {
                            Circle()
                                .strokeBorder(Theme.Stroke.surfaceBorder, lineWidth: Theme.Stroke.hairlineWidth)
                        }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel("Etiketleri düzenle")
                .help("Etiketle")
                .opacity(hovering || tagging ? 1 : 0)
                .allowsHitTesting(hovering || tagging)
                .popover(isPresented: $tagging, arrowEdge: .bottom) {
                    TagEditor(tags: item.tags, all: model.tags) { tags in
                        Task { await model.setTags(item.id, tags) }
                    }
                    .padding(Theme.Spacing.md)
                    .frame(minWidth: 260, idealWidth: 300)
                }
            }
            .frame(minHeight: Theme.Spacing.xxl)
        }
    }
}

/// A whole post in the feed layout: full text and media at their own size,
/// read by scrolling. Media opens in the viewer.
struct FeedPost: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            AuthorLine(item: item, showHandle: true)
            if let title = item.title, !title.isEmpty {
                Text(title)
                    .font(.headline)
            }
            if !item.text.isEmpty {
                Text(item.text)
                    .font(.body)
                    .lineSpacing(3)
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
        .padding(Theme.Spacing.lg)
        .background(.background.secondary, in: .rect(cornerRadius: Theme.Radius.lg))
        .containerShape(.rect(cornerRadius: Theme.Radius.lg))
        .overlay(alignment: .center) {
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(
                    selected
                        ? Theme.accent
                        : (hovering ? Theme.Stroke.surfaceHoverBorder : Theme.Stroke.surfaceBorder),
                    lineWidth: selected ? Theme.Stroke.selectionWidth : Theme.Stroke.hairlineWidth
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Compact reading row for the list layout with rounded inset selection.
struct ItemRow: View {
    let item: Item
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Avatar(name: item.author ?? item.platform, size: 32)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                AuthorLine(item: item, showAvatar: false, showHandle: true)
                Text(item.headline.isEmpty ? (item.quote?.item.text ?? "") : item.headline)
                    .font(.callout)
                    .lineSpacing(2)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !item.tags.isEmpty { CardTags(tags: item.tags) }
            }
            if let file = item.cover?.file {
                LocalImage(file: file, maxPixel: 240)
                    .frame(width: 72, height: 72)
                    .clipShape(.rect(cornerRadius: Theme.Radius.sm))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                            .strokeBorder(Theme.Stroke.mediaOutline, lineWidth: Theme.Stroke.hairlineWidth)
                    }
                    .overlay(alignment: .bottomLeading) { MediaBadge(item: item, compact: true) }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(
            selected
                ? Theme.accent.opacity(0.14)
                : (hovering ? Theme.Stroke.subtleFill : .clear),
            in: .rect(cornerRadius: Theme.Radius.sm)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .strokeBorder(
                    selected
                        ? Theme.accent.opacity(0.55)
                        : (hovering ? Theme.Stroke.surfaceBorder : .clear),
                    lineWidth: selected ? 1 : Theme.Stroke.hairlineWidth
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Video / count / offline marker on a cover.
struct MediaBadge: View {
    let item: Item
    var compact = false

    var body: some View {
        let videos = item.allMedia.filter(\.isVideo)
        let missing = item.needsDownload
        HStack(spacing: Theme.Spacing.xs) {
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
        .font(.caption.bold())
        .foregroundStyle(.white)
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(.black.opacity(0.62), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Theme.Stroke.darkOverlayBorder, lineWidth: Theme.Stroke.hairlineWidth)
        }
        .padding(Theme.Spacing.sm)
        .opacity(videos.isEmpty && item.allMedia.count < 2 && !missing ? 0 : 1)
    }
}

struct QuoteSnippet: View {
    let item: Item

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Capsule()
                .fill(Theme.accent.opacity(0.55))
                .frame(width: Theme.Spacing.xs)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                if let a = item.author {
                    Text(a)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(item.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
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
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(tags.prefix(3), id: \.self) { tag in
                    TagChip(name: tag, action: { model.filter(tag: tag) })
                }
                if tags.count > 3 {
                    Text("+\(tags.count - 3)")
                        .font(.caption.weight(.medium))
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
        HStack(spacing: Theme.Spacing.sm) {
            if showAvatar { Avatar(name: item.author ?? platform.label, size: 20) }
            Text(displayName)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            if showHandle, let h = item.authorHandle, item.authorName != nil {
                Text("@\(h)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.xs)
            Image(systemName: platform.symbol)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text((item.created ?? item.saved).short)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
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
    var spacing: CGFloat = Theme.Spacing.xs

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


extension ItemCard: Equatable {
    nonisolated static func == (lhs: ItemCard, rhs: ItemCard) -> Bool {
        lhs.item == rhs.item && lhs.selected == rhs.selected
    }
}

extension FeedPost: Equatable {
    nonisolated static func == (lhs: FeedPost, rhs: FeedPost) -> Bool {
        lhs.item == rhs.item && lhs.selected == rhs.selected
    }
}

extension ItemRow: Equatable {
    nonisolated static func == (lhs: ItemRow, rhs: ItemRow) -> Bool {
        lhs.item == rhs.item && lhs.selected == rhs.selected
    }
}
