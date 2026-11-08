import SwiftUI

/// Every photo or every video in the library as one square grid, newest
/// first. Click shows the post in the detail column, double-click opens the
/// viewer. The search box narrows it like any other view.
struct GalleryView: View {
    @Environment(AppModel.self) private var model
    let videos: Bool

    private struct Entry: Identifiable {
        let item: Item
        let fromQuote: Bool
        let index: Int
        let media: Media
        var id: String { "\(item.id)#\(fromQuote ? "q" : "m")\(index)" }
    }

    private var entries: [Entry] {
        model.items.flatMap { item -> [Entry] in
            let own = item.media.enumerated().map { Entry(item: item, fromQuote: false, index: $0.offset, media: $0.element) }
            let quoted = (item.quote?.item.media ?? []).enumerated().map { Entry(item: item, fromQuote: true, index: $0.offset, media: $0.element) }
            return (own + quoted).filter { $0.media.isVideo == videos }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 4)]

    var body: some View {
        let entries = entries
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(entries) { e in
                    tile(e)
                        .onAppear {
                            if e.id == entries.last?.id { Task { await model.loadMore() } }
                        }
                }
            }
            .padding(8)
        }
        .background(Theme.canvas)
        .safeAreaInset(edge: .top, spacing: 0) { bar(count: entries.count) }
        .overlay {
            if entries.isEmpty && !model.isLoading {
                if model.filters.isEmpty && model.query.isEmpty {
                    ContentUnavailableView(videos ? "Video yok" : "Fotoğraf yok",
                                           systemImage: videos ? "play.rectangle" : "photo.on.rectangle")
                } else {
                    ContentUnavailableView {
                        Label("Eşleşen \(videos ? "video" : "fotoğraf") yok", systemImage: "line.3.horizontal.decrease.circle")
                    } actions: {
                        Button("Filtreleri temizle") {
                            model.filters = AdvancedFilters()
                            model.query = ""
                        }
                    }
                }
            }
        }
        .navigationTitle("")
    }

    /// Title, how many are loaded, and the folder filter one click away.
    private func bar(count: Int) -> some View {
        HStack(spacing: 10) {
            Text(videos ? "Videolar" : "Fotoğraflar")
                .font(.system(size: 13, weight: .semibold))
            if count > 0 {
                // Posts are paged in, so this grows while scrolling.
                Text(model.reachedEnd ? count.formatted() : "\(count.formatted())+")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            Spacer()
            let others = model.filters.activeCount - (model.filters.folder == .any ? 0 : 1)
            if others > 0 {
                Button { model.showFilters = true } label: {
                    Label("\(others) filtre daha", systemImage: "line.3.horizontal.decrease")
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .help("Filtre panelini aç")
            }
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(model.filters.folder == .any ? Color.secondary : Theme.accent)
            FolderFilterPicker()
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .help("Klasöre göre süz (alt klasörler dahil)")
            if model.filters.folder != .any {
                Button { model.filters.folder = .any } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(minWidth: 22, minHeight: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Klasör filtresini kaldır")
                .help("Klasör filtresini kaldır")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tile(_ e: Entry) -> some View {
        let selected = model.selection == [e.item.id]
        return Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let file = e.media.file {
                    LocalImage(file: file, maxPixel: 420)
                } else {
                    Rectangle().fill(Theme.hairline)
                        .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if e.media.isVideo {
                    Image(systemName: e.media.videoFile != nil ? "play.fill" : "icloud.and.arrow.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(6)
                        .help(e.media.videoFile != nil ? "Çevrimdışı" : "Video henüz indirilmedi")
                }
            }
            .overlay {
                if selected { Rectangle().strokeBorder(Theme.accent, lineWidth: 3) }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                ClickInfo.current.handle(single: model.selection = [e.item.id],
                                         double: model.openViewer(owner: e.item, fromQuote: e.fromQuote, index: e.index))
            }
            .contextMenu {
                Button("Görüntüle") { model.openViewer(owner: e.item, fromQuote: e.fromQuote, index: e.index) }
                if let file = e.media.videoFile ?? e.media.file {
                    Button("Finder'da göster") { NSWorkspace.shared.activateFileViewerSelecting([Core.shared.mediaURL(file)]) }
                }
                Button("Kaynağında aç") {
                    if let url = URL(string: e.item.url) { NSWorkspace.shared.open(url) }
                }
            }
    }
}
