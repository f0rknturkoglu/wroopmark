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

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            sidebar
        } content: {
            List(selection: $selection) {
                LibraryBanners()
                if model.scope == .today && model.query.isEmpty {
                    if !model.onThisDay.isEmpty {
                        Section("Geçmişte bugün") {
                            ForEach(model.onThisDay) { item in
                                ItemRowView(item: item)
                                    .tag(item.id)
                                    .swipeActions {
                                        Button("Sil", role: .destructive) { Task { await model.delete(item.id) } }
                                    }
                            }
                        }
                    }
                    if !model.rediscover.isEmpty {
                        Section("Arşivden bugün için") {
                            ForEach(model.rediscover) { item in
                                ItemRowView(item: item)
                                    .tag(item.id)
                                    .swipeActions {
                                        Button("Sil", role: .destructive) { Task { await model.delete(item.id) } }
                                    }
                            }
                        }
                    }
                } else {
                    ForEach(model.items) { item in
                        ItemRowView(item: item)
                            .tag(item.id)
                            .onAppear { if item.id == model.items.last?.id { Task { await model.loadMore() } } }
                            .swipeActions {
                                Button("Sil", role: .destructive) { Task { await model.delete(item.id) } }
                            }
                    }
                }
                if model.items.isEmpty && !model.isLoading {
                    if model.query.isEmpty && model.scope == .all {
                        WelcomeView(add: { showAdd = true }, sync: { showSettings = true })
                            .listRowSeparator(.hidden)
                    } else {
                        ContentUnavailableView.search(text: model.query)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(model.scope.title)
            .navigationSubtitle(model.total > 0 ? "\(model.total) kayıt" : "")
            .searchable(text: $model.query, prompt: "Ara: kelime, tag:dev, from:@kişi")
            .refreshable {
                await model.syncNow()
                await model.reload()
            }
            .toolbar {
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
                        .accessibilityLabel("Bağlantı ekle")
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
        .onChange(of: model.semanticSearch) { _, _ in Task { await model.reload() } }
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
