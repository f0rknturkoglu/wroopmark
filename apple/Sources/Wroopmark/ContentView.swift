import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var saveSearchName = ""

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            Group {
                switch model.scope {
                case .links: LinkPoolView()
                case .photos: GalleryView(videos: false)
                case .videos: GalleryView(videos: true)
                case .triage: TriageView()
                default: ItemGridView()
                }
            }
            .inspector(isPresented: $model.showDetailPane) {
                DetailColumn()
                    .inspectorColumnWidth(min: 320, ideal: 380, max: 550)
            }
        }
        // The media viewer is a lightbox over the whole window rather than a
        // sheet: a click on the backdrop closes it, like Esc.
        .overlay {
            if let v = model.viewer {
                MediaViewer(viewer: v)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: model.viewer?.id)
        .preferredColorScheme(model.theme.colorScheme)
        .alert("Aramayı kaydet", isPresented: $model.showSaveSearch) {
            TextField("Ad", text: $saveSearchName)
            Button("Kaydet") {
                let name = saveSearchName
                Task { await model.saveSearch(name: name) }
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Kenar çubuğunda durur, her açılışta güncel sonuçları gösterir.\n\(model.searchToSave)")
        }
        .onChange(of: model.showSaveSearch) { _, shown in
            if shown { saveSearchName = model.query.trimmingCharacters(in: .whitespaces).isEmpty ? "Yeni arama" : model.query }
        }
        .onChange(of: model.query) { _, _ in model.queryChanged() }
        .onChange(of: model.filters) { _, _ in model.queryChanged() }
        .onChange(of: model.sort) { _, _ in Task { await model.reload() } }
        .onChange(of: model.scope) { _, _ in
            model.selection = []
            Task { await model.reload() }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("Ara: kelime, tag:dev, from:@yazar, has:image…", text: $model.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                    if !model.query.isEmpty {
                        Button {
                            model.query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .frame(minWidth: 280, idealWidth: 380, maxWidth: 500)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1)
                )
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if model.isBusy { ProgressView().controlSize(.small) }
                if !model.scope.isLinks {
                    SortMenu()
                    Button { model.showFilters.toggle() } label: {
                        Label("Filtreler", systemImage: model.filters.isEmpty
                              ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .help(model.filters.isEmpty ? "Gelişmiş filtreler" : "\(model.filters.activeCount) filtre açık")
                    .popover(isPresented: $model.showFilters, arrowEdge: .bottom) { FilterPanel().environment(model) }
                }
                Button {
                    model.showDownloads.toggle()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: model.isDownloading ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(model.isDownloading ? Theme.accent : .primary)
                        if model.activeOrQueuedDownloadsCount > 0 {
                            Text("\(model.activeOrQueuedDownloadsCount)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(2.5)
                                .background(Theme.accent, in: Circle())
                                .offset(x: 7, y: -5)
                                .monospacedDigit()
                        }
                    }
                }
                .help("İndirmeler (⌘J)")
                Button { model.showAdd = true } label: { Label("Bağlantı ekle", systemImage: "plus") }
                    .help("URL kaydet (⌘N)")

                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        model.showDetailPane.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.trailing")
                        .foregroundStyle(model.showDetailPane ? Theme.accent : .primary)
                }
                .help(model.showDetailPane ? "Detay panelini gizle (⌘I)" : "Detay panelini göster (⌘I)")
                .keyboardShortcut("i", modifiers: [.command])
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
        .sheet(isPresented: $model.showDownloads) { DownloadsView().environment(model) }
        .sheet(isPresented: $model.showBulkTags) { BulkTagSheet(ids: Array(model.selection)) }
        .alert("Hata", isPresented: $model.hasError) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog(
            (model.confirmDeleteIDs?.count ?? 0) > 1 ? "\(model.confirmDeleteIDs?.count ?? 0) kaydı silmek istediğine emin misin?" : "Bu kaydı silmek istediğine emin misin?",
            isPresented: $model.hasConfirmDelete,
            titleVisibility: .visible
        ) {
            Button("Sil", role: .destructive) {
                if let ids = model.confirmDeleteIDs {
                    model.confirmDeleteIDs = nil
                    Task { await model.delete(ids) }
                }
            }
            Button("Vazgeç", role: .cancel) {
                model.confirmDeleteIDs = nil
            }
        } message: {
            Text("Bu işlem geri alınamaz.")
        }
    }
}

struct DetailColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let item = model.selectedItem {
            ItemDetailView(item: item).id("\(item.id)-\(item.folderId ?? 0)")
        } else if model.selection.count > 1 {
            MultiSelectionView(count: model.selection.count)
        } else if model.scope.isLinks, let link = model.selectedLink {
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
            Text("\(count) kayıt seçili")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            HStack(spacing: 10) {
                Button("Etiketle…") { model.showBulkTags = true }

                Menu("Klasöre taşı…") {
                    if !model.folders.isEmpty {
                        ForEach(model.folders) { f in
                            Button {
                                Task { await model.moveItemsToFolder(ids: Array(model.selection), folderID: f.id) }
                            } label: {
                                Label {
                                    Text(f.name)
                                } icon: {
                                    Image(nsImage: FolderIcons.image(forFolder: f.name))
                                }
                            }
                        }
                        Divider()
                    }
                    Button("Klasörden çıkar") {
                        Task { await model.moveItemsToFolder(ids: Array(model.selection), folderID: nil) }
                    }
                }

                Button("Sil", role: .destructive) { model.requestDelete(Array(model.selection)) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
