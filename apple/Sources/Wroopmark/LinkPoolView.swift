import SwiftUI

/// Every URL found in saved posts (and added by hand), deduplicated and organized into subfolders.
struct LinkPoolView: View {
    @Environment(AppModel.self) private var model
    @State private var newLink = ""
    @State private var selectedID: Int64?
    @State private var deletingLink: LinkRow?

    private var currentCategory: LinkCategory? {
        if case .links(let cat) = model.scope { return cat }
        return nil
    }

    private var displayedLinks: [LinkRow] {
        if let cat = currentCategory {
            return model.links.filter { cat.matches(host: $0.host, url: $0.url) }
        }
        return model.links
    }

    private var title: String {
        if let cat = currentCategory {
            return "\(cat.label) linkleri"
        }
        return "Link havuzu"
    }

    var body: some View {
        List(selection: $selectedID) {
            ForEach(displayedLinks) { link in
                HStack(spacing: 9) {
                    let cat = LinkCategory.allCases.first { $0.matches(host: link.host, url: link.url) } ?? .other
                    Image(nsImage: cat.iconImage)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(link.title ?? link.url.replacingOccurrences(of: "https://", with: ""))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(link.host)
                            if link.itemCount > 0 {
                                Text("· \(link.itemCount) kayıtta").monospacedDigit()
                            }
                            if link.manual { Image(systemName: "hand.point.up.left").help("Elle eklendi") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
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
                    Button("Havuzdan sil…", role: .destructive) { deletingLink = link }
                }
            }
        }
        .onChange(of: selectedID) { _, id in
            Task {
                await model.select(link: displayedLinks.first { $0.id == id })
            }
        }
        .onChange(of: model.scope) { _, _ in
            if let sel = model.selectedLink, !displayedLinks.contains(where: { $0.id == sel.id }) {
                let first = displayedLinks.first
                selectedID = first?.id
                Task { await model.select(link: first) }
            }
        }
        .confirmationDialog(
            "Bu linki havuzdan silmek istediğine emin misin?",
            isPresented: Binding(
                get: { deletingLink != nil },
                set: { if !$0 { deletingLink = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Sil", role: .destructive) {
                if let link = deletingLink {
                    deletingLink = nil
                    Task { await model.deleteLink(link) }
                }
            }
            Button("Vazgeç", role: .cancel) { deletingLink = nil }
        } message: {
            Text("Bu link kayıt havuzundan kaldırılır.")
        }
        .safeAreaInset(edge: .top) {
            HStack {
                TextField("Havuza link ekle", text: $newLink)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Ekle", action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(newLink.isEmpty)
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
            if displayedLinks.isEmpty {
                if let cat = currentCategory {
                    ContentUnavailableView {
                        Label("\(cat.label) linki yok", systemImage: cat.symbolFallback)
                    } description: {
                        Text("Bu kategoride kayıtlı link bulunmuyor.")
                    }
                } else {
                    ContentUnavailableView("Link yok", systemImage: "link", description: Text("Kaydedilen gönderilerdeki linkler burada toplanır."))
                }
            }
        }
        .navigationTitle("")
        .onAppear {
            selectedID = model.selectedLink?.id
        }
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
