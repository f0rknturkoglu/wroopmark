import SwiftUI

/// The iPad's library: scopes on the left, the list in the middle, the
/// post on the right. The list, the post view, the feed and the clean-up
/// are the iPhone's.
struct PadLibrary: View {
    @Environment(PhoneModel.self) private var model
    @State private var selection: String?
    @State private var showAdd = false
    @State private var showSettings = false
    @State private var showFeed = false
    @State private var showTriage = false
    @State private var activeTool: PhoneTool?
    @State private var readingTarget: ReadingTarget?
    @State private var savingSearch = false
    @State private var searchName = ""

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            sidebar
        } content: {
            List(selection: $selection) {
                LibraryBanners()
                if model.scope == .today && model.effectiveQuery.isEmpty && model.sort.isEmpty {
                    if !model.onThisDay.isEmpty {
                        Section("Geçmişte bugün") {
                            ForEach(model.onThisDay) { item in
                                ItemRowView(item: item)
                                    .tag(item.id)
                                    .modifier(ItemRowActions(item: item) { readingTarget = ReadingTarget(id: $0) })
                            }
                        }
                    }
                    if !model.rediscover.isEmpty {
                        Section("Arşivden bugün için") {
                            ForEach(model.rediscover) { item in
                                ItemRowView(item: item)
                                    .tag(item.id)
                                    .modifier(ItemRowActions(item: item) { readingTarget = ReadingTarget(id: $0) })
                            }
                        }
                    }
                } else {
                    ForEach(model.items) { item in
                        ItemRowView(item: item)
                            .tag(item.id)
                            .onAppear { if item.id == model.items.last?.id { Task { await model.loadMore() } } }
                            .modifier(ItemRowActions(item: item) { readingTarget = ReadingTarget(id: $0) })
                    }
                }
                if model.items.isEmpty && !model.isLoading {
                    if model.effectiveQuery.isEmpty && model.scope == .all {
                        WelcomeView(add: { showAdd = true }, sync: { showSettings = true })
                            .listRowSeparator(.hidden)
                    } else {
                        ContentUnavailableView.search(text: model.query)
                    }
                }
            }
            .listStyle(.plain)
            .dropDestination(for: URL.self) { urls, _ in
                let valid = urls.filter { $0.scheme == "http" || $0.scheme == "https" }
                guard !valid.isEmpty else { return false }
                Task {
                    for u in valid { _ = await model.addURL(u.absoluteString, tags: []) }
                }
                return true
            }
            .navigationTitle(model.scope.title)
            .navigationSubtitle(model.total > 0 ? "\(model.total) kayıt" : "")
            .searchable(text: $model.query, prompt: "Ara: kelime, tag:dev, from:@kişi")
            .searchSuggestions {
                Button { model.filterTokens.insert("has:video") } label: { Label("Videolu kayıtlar", systemImage: "play.rectangle") }
                Button { model.filterTokens.insert("has:highlight") } label: { Label("Vurgulu kayıtlar", systemImage: "highlighter") }
                Button { model.filterTokens.insert("is:untagged") } label: { Label("Etiketsiz kayıtlar", systemImage: "tag.slash") }
                ForEach(model.tags.prefix(5), id: \.key) { t in
                    Button("#\(t.name) (\(t.count))") { model.query = "tag:\(t.key)" }
                }
            }
            .refreshable {
                await model.syncNow()
                await model.reload()
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { activeTool = .filters } label: {
                        Image(systemName: model.filterTokens.isEmpty && model.sort.isEmpty ? "arrow.up.arrow.down.circle" : "arrow.up.arrow.down.circle.fill")
                    }
                    .accessibilityLabel("Süz ve Sırala")
                }
                if !model.searchToSave.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            searchName = ""
                            savingSearch = true
                        } label: {
                            Image(systemName: "bookmark")
                        }
                        .accessibilityLabel("Bu aramayı kaydet")
                    }
                }
                if model.aiStatus?.embedReady == true {
                    ToolbarItem(placement: .primaryAction) {
                        Button { model.semanticSearch.toggle() } label: {
                            Image(systemName: model.semanticSearch ? "sparkles.rectangle.stack.fill" : "sparkles")
                        }
                        .accessibilityLabel(model.semanticSearch ? "Anlamına göre arama açık" : "Anlamına göre ara")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .keyboardShortcut("n", modifiers: .command)
                        .accessibilityLabel("Bağlantı veya not ekle")
                }
            }
        } detail: {
            if let id = selection {
                NavigationStack {
                    ItemView(id: id)
                        .navigationDestination(for: String.self) { ItemView(id: $0) }
                }
                .id(id)
            } else {
                ContentUnavailableView("Bir kayıt seç", systemImage: "bookmark", description: Text("Soldan bir kapsam, ortadan bir kayıt."))
            }
        }
        .onChange(of: model.query) { _, _ in model.queryChanged() }
        .onChange(of: model.sort) { _, _ in Task { await model.reload() } }
        .onChange(of: model.filterTokens) { _, _ in Task { await model.reload() } }
        .onChange(of: model.semanticSearch) { _, _ in Task { await model.reload() } }
        .onChange(of: model.activeModal) { _, modal in
            guard let modal else { return }
            model.activeModal = nil
            switch modal {
            case "add": showAdd = true
            case "triage": showTriage = true
            case "feed": showFeed = true
            default: break
            }
        }
        .onChange(of: model.scope) { _, _ in
            selection = nil
            Task { await model.reload() }
        }
        // A deleted post leaves the right side empty.
        .onChange(of: model.items.map(\.id)) { _, ids in
            if let s = selection, !ids.contains(s) { selection = nil }
        }
        .onChange(of: model.openRequest) { _, id in
            if let id {
                selection = id
                model.openRequest = nil
            }
        }
        .sheet(isPresented: $showAdd) { AddURLView() }
        .sheet(isPresented: $showSettings) { PhoneSettingsView() }
        .sheet(item: $activeTool) { PhoneToolSheet(tool: $0) }
        .fullScreenCover(item: $readingTarget) { ReaderView(id: $0.id) }
        .alert("Aramayı kaydet", isPresented: $savingSearch) {
            TextField("Arama adı", text: $searchName)
            Button("Kaydet") {
                let name = searchName
                Task { await model.saveSearch(name: name) }
            }
            Button("Vazgeç", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $showFeed) { VideoFeedView(scope: model.scope, query: model.query) }
        .fullScreenCover(isPresented: $showTriage) { PhoneTriageView(scope: model.scope, query: model.query) }
    }

    private var scope: Binding<PhoneScope?> {
        Binding(get: { model.scope }, set: { if let s = $0 { model.scope = s } })
    }

    private var sidebar: some View {
        List(selection: scope) {
            Section {
                Label("Tümü", systemImage: "tray.full").tag(PhoneScope.all)
                Label("Bugün", systemImage: "calendar.day.timeline.left").tag(PhoneScope.today)
                Label("Etiketsiz", systemImage: "tag.slash").tag(PhoneScope.untagged)
            }
            Section {
                Button { showFeed = true } label: { Label("Akış", systemImage: "play.rectangle.on.rectangle") }
                Button { showTriage = true } label: { Label("Ayıkla", systemImage: "rectangle.stack.badge.minus") }
            }
            Section("Araçlar") {
                Button { activeTool = .foldersTags } label: { Label("Klasörler ve Etiketler", systemImage: "folder.badge.gearshape") }
                Button { activeTool = .gallery } label: { Label("Galeri", systemImage: "photo.on.rectangle") }
                Button { activeTool = .links } label: { Label("Link Havuzu", systemImage: "link") }
                Button { activeTool = .rules } label: { Label("Kurallar", systemImage: "slider.horizontal.3") }
                Button { activeTool = .duplicates } label: { Label("Kopyalar", systemImage: "square.on.square") }
                Button { activeTool = .export } label: { Label("Dışa Aktar…", systemImage: "square.and.arrow.up") }
            }
            if !model.savedSearches.isEmpty {
                Section("Kayıtlı aramalar") {
                    ForEach(model.savedSearches) { s in
                        Label(s.name, systemImage: "magnifyingglass")
                            .tag(PhoneScope.saved(s))
                            .contextMenu {
                                Button(role: .destructive) {
                                    Task { await model.deleteSavedSearch(s) }
                                } label: {
                                    Label("Sil", systemImage: "trash")
                                }
                            }
                    }
                }
            }
            let counts = model.stats?.byPlatform ?? [:]
            let platforms = Platform.allCases.filter { (counts[$0.rawValue] ?? 0) > 0 }
            if !platforms.isEmpty {
                Section("Platformlar") {
                    ForEach(platforms) { p in
                        Label(p.label, systemImage: p.symbol)
                            .badge(counts[p.rawValue] ?? 0)
                            .tag(PhoneScope.platform(p.rawValue))
                    }
                }
            }
            if !model.folders.isEmpty {
                Section("Klasörler") {
                    ForEach(model.folders) { f in
                        Label(f.name.replacingOccurrences(of: "/", with: " › "), systemImage: "folder")
                            .badge(f.count)
                            .tag(PhoneScope.folder(f.id, f.name))
                            .contextMenu {
                                Button {
                                    Task { await model.sharePage(query: PhoneScope.folder(f.id, f.name).filter, title: PhoneScope.folder(f.id, f.name).title) }
                                } label: {
                                    Label("Tek sayfa olarak paylaş", systemImage: "square.and.arrow.up")
                                }
                                Button { activeTool = .foldersTags } label: {
                                    Label("Klasörleri yönet…", systemImage: "folder.badge.gearshape")
                                }
                                Button(role: .destructive) {
                                    Task { await model.deleteFolder(id: f.id) }
                                } label: {
                                    Label("Klasörü sil", systemImage: "trash")
                                }
                            }
                    }
                }
            }
            if !model.tags.isEmpty {
                Section("Etiketler") {
                    ForEach(model.tags.prefix(60), id: \.key) { t in
                        Label(t.name, systemImage: "number")
                            .badge(t.count)
                            .tag(PhoneScope.tag(t.key))
                    }
                }
            }
        }
        .navigationTitle("wroopmark")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: {
                    Image(systemName: model.isSyncing ? "arrow.triangle.2.circlepath" : "gearshape")
                        .symbolEffect(.rotate, isActive: model.isSyncing)
                }
                .accessibilityLabel("Ayarlar")
            }
        }
    }
}
