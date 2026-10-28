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
        .overlay {
            if entries.isEmpty && !model.isLoading {
                ContentUnavailableView(videos ? "Video yok" : "Fotoğraf yok",
                                       systemImage: videos ? "play.rectangle" : "photo.on.rectangle")
            }
        }
        .navigationTitle(videos ? "Videolar" : "Fotoğraflar")
        .navigationSubtitle("\(entries.count.formatted()) \(videos ? "video" : "fotoğraf")")
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
            .onTapGesture(count: 2) { model.openViewer(owner: e.item, fromQuote: e.fromQuote, index: e.index) }
            .onTapGesture { model.selection = [e.item.id] }
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
