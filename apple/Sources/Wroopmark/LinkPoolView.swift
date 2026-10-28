import SwiftUI

/// Every URL found in saved posts (and added by hand), deduplicated.
struct LinkPoolView: View {
    @Environment(AppModel.self) private var model
    @State private var newLink = ""

    var body: some View {
        List(selection: Binding<Int64?>(
            get: { model.selectedLink?.id },
            set: { id in Task { await model.select(link: model.links.first { $0.id == id }) } }
        )) {
            ForEach(model.links) { link in
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.title ?? link.url.replacingOccurrences(of: "https://", with: ""))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(link.host)
                        if link.itemCount > 0 { Text("· \(link.itemCount) kayıtta") }
                        if link.manual { Image(systemName: "hand.point.up.left").help("Elle eklendi") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(link.id)
                .contextMenu {
                    Button("Tarayıcıda aç") { open(link) }
                    Button("Kopyala") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link.url, forType: .string)
                    }
                    Divider()
                    Button("Havuzdan sil", role: .destructive) { Task { await model.deleteLink(link) } }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            HStack {
                TextField("Havuza link ekle", text: $newLink)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Ekle", action: add).disabled(newLink.isEmpty)
                Button {
                    Task { await model.enrichLinks() }
                } label: { Label("Başlıkları getir", systemImage: "text.badge.plus") }
                    .help("Başlığı olmayan linklerin sayfa başlığını indir")
                    .disabled(model.isBusy)
            }
            .padding(10)
            .background(.bar)
        }
        .overlay {
            if model.links.isEmpty {
                ContentUnavailableView("Link yok", systemImage: "link", description: Text("Kaydedilen gönderilerdeki linkler burada toplanır."))
            }
        }
        .navigationTitle("Link havuzu")
        .navigationSubtitle("\(model.links.count.formatted()) link")
    }

    private func add() {
        let url = newLink.trimmingCharacters(in: .whitespaces)
        newLink = ""
        Task { await model.addLink(url) }
    }

    private func open(_ link: LinkRow) {
        if let url = URL(string: link.url) { NSWorkspace.shared.open(url) }
    }
}

struct LinkDetailView: View {
    @Environment(AppModel.self) private var model
    let link: LinkRow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(link.title ?? link.host).font(.title3.weight(.semibold)).textSelection(.enabled)
                if let d = link.description { Text(d).foregroundStyle(.secondary) }
                if let url = URL(string: link.url) {
                    Link(link.url, destination: url).font(.callout).lineLimit(2)
                }
                Divider()
                Text(model.linkItems.isEmpty ? "Hiçbir kayıtta geçmiyor" : "Geçtiği kayıtlar")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(model.linkItems) { item in
                    ItemCard(item: item, selected: false)
                        .onTapGesture {
                            model.scope = .all
                            model.query = ""
                            Task {
                                await model.reload()
                                model.selection = [item.id]
                            }
                        }
                }
            }
            .padding(18)
        }
    }
}
