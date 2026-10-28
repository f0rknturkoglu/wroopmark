import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: TagNode?
    @State private var newName = ""

    var body: some View {
        @Bindable var model = model
        List(selection: Binding<Scope?>(get: { model.scope }, set: { if let s = $0 { model.scope = s } })) {
            Section("Kütüphane") {
                row("Tümü", "tray.full", model.stats?.items).tag(Scope.all)
                row("Etiketsiz", "tag.slash", nil).tag(Scope.untagged)
                row("Link havuzu", "link", model.stats?.links).tag(Scope.links)
            }
            Section("Galeri") {
                row("Fotoğraflar", "photo.on.rectangle", nil).tag(Scope.photos)
                row("Videolar", "play.rectangle", nil).tag(Scope.videos)
            }
            Section("Platformlar") {
                ForEach(Platform.allCases) { p in
                    let n = model.stats?.byPlatform[p.rawValue] ?? 0
                    if n > 0 || p == .x {
                        row(p.label, p.symbol, n).tag(Scope.platform(p))
                    }
                }
            }
            if !model.tagTree.isEmpty {
                Section("Etiketler") {
                    OutlineGroup(model.tagTree, children: \.children) { node in
                        row(node.name, "number", node.count > 0 ? node.count : nil)
                            .tag(Scope.tag(node.id))
                            .contextMenu {
                                Button("Yeniden adlandır…") {
                                    newName = node.id
                                    renaming = node
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                if let s = model.stats, s.mediaPending > 0 {
                    Label("\(s.mediaPending) kaydın medyası iniyor", systemImage: "arrow.down.circle")
                }
                if model.isReadingText, let n = model.stats?.ocrPending, n > 0 {
                    Label("\(n) kayıtta yazı okunuyor", systemImage: "text.viewfinder")
                }
            }
            .font(.caption).foregroundStyle(.secondary).padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $renaming) { node in
            VStack(alignment: .leading, spacing: 12) {
                Text("Etiketi yeniden adlandır").font(.headline)
                Text("Alt etiketler de taşınır: \(node.id)/… → yeni/…").font(.caption).foregroundStyle(.secondary)
                TextField("yeni ad", text: $newName).textFieldStyle(.roundedBorder).frame(width: 300)
                HStack {
                    Spacer()
                    Button("Vazgeç") { renaming = nil }.keyboardShortcut(.cancelAction)
                    Button("Adlandır") {
                        let from = node.id
                        let to = newName
                        renaming = nil
                        Task { await model.renameTag(from: from, to: to) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parseTags(newName).isEmpty)
                }
            }
            .padding(20)
        }
    }

    private func row(_ title: String, _ symbol: String, _ count: Int?) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if let count { Text(count.formatted()).foregroundStyle(.secondary).monospacedDigit() }
        }
    }
}
