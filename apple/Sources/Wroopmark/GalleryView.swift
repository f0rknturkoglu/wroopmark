import SwiftUI

/// Every photo or every video in the library as one square grid, newest
/// first. Click shows the post in the detail column, double-click opens the
/// viewer. The search box narrows it like any other view.
struct GalleryView: View {
    @Environment(AppModel.self) private var model
    let videos: Bool
    @State private var entries: [Entry] = []

    private struct Entry: Identifiable {
        let item: Item
        let fromQuote: Bool
        let index: Int
        let media: Media
        var id: String { "\(item.id)#\(fromQuote ? "q" : "m")\(index)" }
    }

    /// Flattening every post's media is O(items); keep it out of `body` and
    /// recompute only when the loaded page or the video filter changes.
    private func computeEntries() -> [Entry] {
        model.items.flatMap { item -> [Entry] in
            let own = item.media.enumerated().map { Entry(item: item, fromQuote: false, index: $0.offset, media: $0.element) }
            let quoted = (item.quote?.item.media ?? []).enumerated().map { Entry(item: item, fromQuote: true, index: $0.offset, media: $0.element) }
            return (own + quoted).filter { $0.media.isVideo == videos }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 224), spacing: Theme.Spacing.md)]

    /// Until `onAppear` fills the cache, derive it so the first frame is not
    /// mistaken for "no photos".
    private var displayEntries: [Entry] {
        entries.isEmpty && !model.items.isEmpty ? computeEntries() : entries
    }

    var body: some View {
        let entries = displayEntries
        // The bar sits above the scroll view instead of in a safe-area inset:
        // an inset let the first row slide under the bar by its top padding.
        VStack(spacing: 0) {
            bar(count: entries.count)
            // The gap is outside the scroll view: the gallery scroll view
            // otherwise starts at the first lazy item and clips its top.
            Color.clear.frame(height: Theme.Spacing.lg)
            ScrollView {
                LazyVGrid(columns: columns, spacing: Theme.Spacing.md) {
                    ForEach(entries) { e in
                        tile(e)
                            .onAppear {
                                if e.id == entries.last?.id { Task { await model.loadMore() } }
                            }
                    }
                }
                .padding(Theme.Spacing.lg)
            }
            .overlay {
                if entries.isEmpty && !model.isLoading {
                    if let err = model.gridError {
                        ContentUnavailableView {
                            Label("Galeri yüklenemedi", systemImage: "exclamationmark.triangle")
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
                    } else if model.filters.isEmpty && model.query.isEmpty {
                        ContentUnavailableView(
                            videos ? "Video yok" : "Fotoğraf yok",
                            systemImage: videos ? "play.rectangle" : "photo.on.rectangle"
                        )
                        .padding(Theme.Spacing.lg)
                    } else {
                        ContentUnavailableView {
                            Label("Eşleşen \(videos ? "video" : "fotoğraf") yok", systemImage: "line.3.horizontal.decrease.circle")
                        } actions: {
                            Button {
                                model.filters = AdvancedFilters()
                                model.query = ""
                            } label: {
                                Label("Filtreleri temizle", systemImage: "xmark.circle")
                            }
                            .controlSize(.regular)
                        }
                        .padding(Theme.Spacing.lg)
                    }
                }
            }
        }
        .onAppear {
            if self.entries.isEmpty { self.entries = computeEntries() }
        }
        .onChange(of: model.items) { _, _ in
            self.entries = computeEntries()
        }
    }

    /// Title, how many are loaded, and the folder filter one click away.
    private func bar(count: Int) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(videos ? "Videolar" : "Fotoğraflar")
                .font(.subheadline.weight(.semibold))
            if count > 0 {
                // Posts are paged in, so this grows while scrolling.
                CountPill(value: model.reachedEnd ? count.formatted() : "\(count.formatted())+")
            }
            Spacer()
            let others = model.filters.activeCount - (model.filters.folder == .any ? 0 : 1)
            if others > 0 {
                Button { model.showFilters = true } label: {
                    Label("\(others) filtre daha", systemImage: "line.3.horizontal.decrease")
                        .monospacedDigit()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .help("Filtre panelini aç")
            }
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundStyle(model.filters.folder == .any ? Color.secondary : Theme.accent)
                FolderFilterPicker()
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Klasöre göre süz (alt klasörler dahil)")
                if model.filters.folder != .any {
                    Button { model.filters.folder = .any } label: {
                        Label("Klasör filtresini kaldır", systemImage: "xmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 24, minHeight: 24)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Klasör filtresini kaldır")
                    .help("Klasör filtresini kaldır")
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .background(.background)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tile(_ e: Entry) -> some View {
        let selected = model.selection == [e.item.id]
        let radius = Theme.Radius.sm
        return Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let file = e.media.file {
                    LocalImage(file: file, maxPixel: 420)
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay { Image(systemName: "photo").foregroundStyle(.tertiary) }
                }
            }
            .clipShape(.rect(cornerRadius: radius))
            .overlay(alignment: .bottomLeading) {
                if e.media.isVideo {
                    Image(systemName: e.media.videoFile != nil ? "play.fill" : "icloud.and.arrow.down")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(Theme.Spacing.xs)
                        .background(.black.opacity(0.62), in: Circle())
                        .overlay {
                            Circle()
                                .strokeBorder(Theme.Stroke.darkOverlayBorder, lineWidth: Theme.Stroke.hairlineWidth)
                        }
                        .padding(Theme.Spacing.sm)
                        .help(e.media.videoFile != nil ? "Çevrimdışı" : "Video henüz indirilmedi")
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        selected ? Theme.accent : Theme.Stroke.mediaOutline,
                        lineWidth: selected ? 3 : Theme.Stroke.hairlineWidth
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .modifier(HoverOutline(radius: radius))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
            .onTapGesture {
                ClickInfo.current.handle(single: model.selection = [e.item.id],
                                         double: model.openViewer(owner: e.item, fromQuote: e.fromQuote, index: e.index))
            }
            .contextMenu {
                Button { model.openViewer(owner: e.item, fromQuote: e.fromQuote, index: e.index) } label: {
                    Label("Görüntüle", systemImage: "eye")
                }
                if let file = e.media.videoFile ?? e.media.file {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([Core.shared.mediaURL(file)])
                    } label: {
                        Label("Finder'da göster", systemImage: "folder")
                    }
                }
                Button {
                    if let url = URL(string: e.item.url) { NSWorkspace.shared.open(url) }
                } label: {
                    Label("Kaynağında aç", systemImage: "arrow.up.right.square")
                }
            }
    }
}

/// A restrained outline that appears while the pointer is over a tile.
private struct HoverOutline: ViewModifier {
    let radius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(hovering ? Theme.accent.opacity(0.65) : .clear, lineWidth: Theme.Stroke.selectionWidth)
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
