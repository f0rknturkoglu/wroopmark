import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } content: {
            Group {
                switch model.scope {
                case .links: LinkPoolView()
                case .photos: GalleryView(videos: false)
                case .videos: GalleryView(videos: true)
                case .triage: TriageView()
                default: ItemGridView()
                }
            }
            .navigationSplitViewColumnWidth(min: 420, ideal: 620)
        } detail: {
            DetailColumn()
                .navigationSplitViewColumnWidth(min: 340, ideal: 420)
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Ara: kelime tag:dev from:@kişi has:image \"ifade\"")
        .onChange(of: model.query) { _, _ in model.queryChanged() }
        .onChange(of: model.filters) { _, _ in model.queryChanged() }
        .onChange(of: model.sort) { _, _ in Task { await model.reload() } }
        .onChange(of: model.scope) { _, _ in
            model.selection = []
            Task { await model.reload() }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isBusy { ProgressView().controlSize(.small) }
                if model.scope != .links {
                    SortMenu()
                    Button { model.showFilters.toggle() } label: {
                        Label("Filtreler", systemImage: model.filters.isEmpty
                              ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .help(model.filters.isEmpty ? "Gelişmiş filtreler" : "\(model.filters.activeCount) filtre açık")
                    .popover(isPresented: $model.showFilters, arrowEdge: .bottom) { FilterPanel().environment(model) }
                }
                Button { model.showAdd = true } label: { Label("Bağlantı ekle", systemImage: "plus") }
                    .help("URL kaydet (⌘N)")
            }
        }
        // A link dragged from the browser (or a .webloc) is saved like ⌘N.
        .dropDestination(for: URL.self) { urls, _ in
            let web = urls.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
            guard !web.isEmpty else { return false }
            Task {
                for url in web { _ = await model.addURL(url.absoluteString, tags: [], note: "") }
            }
            return true
        }
        .sheet(isPresented: $model.showAdd) { AddURLSheet() }
        .sheet(item: $model.viewer) { v in MediaViewer(viewer: v) }
        .sheet(isPresented: $model.showBulkTags) { BulkTagSheet(ids: Array(model.selection)) }
        .alert("Hata", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct DetailColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let item = model.selectedItem {
            ItemDetailView(item: item).id(item.id)
        } else if model.selection.count > 1 {
            MultiSelectionView(count: model.selection.count)
        } else if model.scope == .links, let link = model.selectedLink {
            LinkDetailView(link: link)
        } else {
            ContentUnavailableView("Bir kayıt seç", systemImage: "bookmark", description: Text("Metin, görseller, linkler, etiketler ve not burada görünür."))
        }
    }
}

struct MultiSelectionView: View {
    @Environment(AppModel.self) private var model
    let count: Int

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("\(count) kayıt seçili").font(.title3.weight(.semibold))
            HStack {
                Button("Etiketle…") { model.showBulkTags = true }
                Button("Sil", role: .destructive) { Task { await model.delete(Array(model.selection)) } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
