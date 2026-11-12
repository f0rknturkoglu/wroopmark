import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var saveSearchName = ""

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView()
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(
                    min: Theme.Layout.sidebarMinWidth,
                    ideal: Theme.Layout.sidebarIdealWidth,
                    max: Theme.Layout.sidebarMaxWidth
                )
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
            .searchable(
                text: $model.query,
                placement: .toolbar,
                prompt: Text("Ara…")
            )
            .inspector(isPresented: $model.showDetailPane) {
                DetailColumn()
                    .inspectorColumnWidth(
                        min: Theme.Layout.inspectorMinWidth,
                        ideal: Theme.Layout.inspectorIdealWidth,
                        max: Theme.Layout.inspectorMaxWidth
                    )
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
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { model.sidebarVisible.toggle() }
                } label: {
                    Label("Kenar Çubuğu", systemImage: "sidebar.left")
                        .labelStyle(.iconOnly)
                }
                .help(model.sidebarVisible ? "Kenar çubuğunu gizle (⌃⌘S)" : "Kenar çubuğunu göster (⌃⌘S)")
                .accessibilityLabel(model.sidebarVisible ? "Kenar çubuğunu gizle" : "Kenar çubuğunu göster")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("İşlem sürüyor")
                }

                ControlGroup {
                    SortMenu()
                    if !model.scope.isLinks {
                        Button { model.showFilters.toggle() } label: {
                            Label("Filtreler", systemImage: model.filters.isEmpty
                                  ? "line.3.horizontal.decrease.circle"
                                  : "line.3.horizontal.decrease.circle.fill")
                                .labelStyle(.iconOnly)
                        }
                        .help(model.filters.isEmpty ? "Gelişmiş filtreler" : "\(model.filters.activeCount) filtre açık")
                        .popover(isPresented: $model.showFilters, arrowEdge: .bottom) { FilterPanel().environment(model) }
                    }
                }
            }

            ToolbarSpacer(.fixed)

            ToolbarItem(placement: .primaryAction) {
                Button { model.showAdd = true } label: {
                    Label("Bağlantı ekle", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .help("URL kaydet (⌘N)")
            }

            if !model.scope.isLinks {
                ToolbarSpacer(.fixed)

                ToolbarItem(placement: .primaryAction) {
                    Picker("Görünüm", selection: $model.layout) {
                        Label("Kart", systemImage: "square.grid.2x2").tag(LibraryLayout.grid)
                        Label("Liste", systemImage: "list.bullet").tag(LibraryLayout.list)
                        Label("Akış", systemImage: "rectangle.grid.1x2").tag(LibraryLayout.feed)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .labelStyle(.iconOnly)
                    .fixedSize()
                    .help("Kart / liste / akış görünümü")
                }
            }

            ToolbarSpacer(.fixed)

            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        model.showDetailPane.toggle()
                    }
                } label: {
                    Label("Detay paneli", systemImage: "sidebar.trailing")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(model.showDetailPane ? Theme.accent : .primary)
                }
                .help(model.showDetailPane ? "Detay panelini gizle (⌘I)" : "Detay panelini göster (⌘I)")
            }
        }
        // A link dragged from the browser (or a .webloc) is saved like ⌘N.
        .dropDestination(for: URL.self) { urls, _ in
            let web = urls.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
            guard !web.isEmpty else { return false }
            Task {
                await model.addURLs(web.map(\.absoluteString))
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

extension ContentView {
    /// Maps the persisted boolean to the split-view enum so the toolbar,
    /// the View menu, and a divider drag all write the same state.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { model.sidebarVisible ? .all : .detailOnly },
            set: { model.sidebarVisible = $0 != .detailOnly }
        )
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
            ContentUnavailableView(
                "Bir kayıt seç",
                systemImage: "bookmark",
                description: Text("Metin, görseller, linkler, etiketler ve not burada görünür.")
            )
            .padding(Theme.Spacing.lg)
        }
    }
}

struct MultiSelectionView: View {
    @Environment(AppModel.self) private var model
    let count: Int

    var body: some View {
        ContentUnavailableView {
            Label("\(count) kayıt seçili", systemImage: "square.stack.3d.up")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        } description: {
            Text("Seçilenlere etiket ekle, klasöre taşı ya da sil.")
        } actions: {
            ControlGroup {
                Button { model.showBulkTags = true } label: {
                    Label("Etiketle…", systemImage: "tag")
                }

                Menu {
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
                    Button {
                        Task { await model.moveItemsToFolder(ids: Array(model.selection), folderID: nil) }
                    } label: {
                        Label("Klasörden çıkar", systemImage: "tray")
                    }
                } label: {
                    Label("Klasöre taşı…", systemImage: "folder")
                }

                Button(role: .destructive) { model.requestDelete(Array(model.selection)) } label: {
                    Label("Sil", systemImage: "trash")
                }
            }
            .buttonStyle(.glass)
            .controlSize(.regular)
        }
        .padding(Theme.Spacing.lg)
    }
}
