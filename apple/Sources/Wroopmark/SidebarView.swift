import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: TagNode?
    @State private var showNewFolderSheet = false
    @State private var folderRenaming: Folder?
    @State private var folderToDelete: Folder?
    @State private var parentForSubfolder: Folder?
    @AppStorage("linkPoolExpanded") private var linkPoolExpanded = true
    @State private var searchRenaming: SavedSearch?
    @State private var hoveringDownloads = false

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedScope) {
            Section("Kütüphane") {
                row(String(localized: "Tümü"), "tray.full", model.stats?.items).tag(Scope.all)
                row(String(localized: "Bugün"), "calendar.day.timeline.left", nil).tag(Scope.today)
                    .help("Geçmiş yıllarda bugün kaydettiklerin ve arşivden 5 kayıt")
                row(String(localized: "Etiketsiz"), "tag.slash", nil).tag(Scope.untagged)
                linkPoolRow
                    .tag(Scope.links(nil))
                    .help("Bütün linkler, kategorilere ayrılmış")
                if linkPoolExpanded {
                    ForEach(LinkCategory.allCases) { cat in
                        row(cat.label, image: cat.iconImage, model.linkCategoryCount(cat))
                            .tag(Scope.links(cat))
                            .padding(.leading, Theme.Spacing.lg)
                    }
                }
                row(String(localized: "Ayıkla"), "arrow.left.arrow.right.square", nil).tag(Scope.triage)
                    .help("Kayıtları tek tek gözden geçir: ← sil, → sakla")
            }
            Section {
                if !model.folderTree.isEmpty {
                    OutlineGroup(model.folderTree, children: \.children) { node in
                        let fid = node.folder?.id ?? 0
                        row(node.name, image: FolderIcons.image(forFolder: node.name), node.count > 0 ? node.count : nil)
                            .tag(Scope.folder(id: fid, name: node.id))
                            .contextMenu {
                                if let f = node.folder {
                                    Button {
                                        parentForSubfolder = f
                                    } label: {
                                        Label("Alt klasör ekle…", systemImage: "folder.badge.plus")
                                    }
                                    Button {
                                        model.exportPage(query: Scope.folder(id: fid, name: node.id).filter, title: node.name)
                                    } label: {
                                        Label("Tek sayfa olarak dışa aktar…", systemImage: "doc.richtext")
                                    }
                                    Divider()
                                    Button {
                                        folderRenaming = f
                                    } label: {
                                        Label("Yeniden adlandır…", systemImage: "pencil")
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        folderToDelete = f
                                    } label: {
                                        Label("Klasörü sil", systemImage: "trash")
                                    }
                                }
                            }
                    }
                } else {
                    Button {
                        showNewFolderSheet = true
                    } label: {
                        Label("Klasör oluştur…", systemImage: "folder.badge.plus")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Yeni klasör ekle")
                }
            } header: {
                foldersHeader
            }
            if !model.savedSearches.isEmpty {
                Section("Kayıtlı aramalar") {
                    ForEach(model.savedSearches) { saved in
                        row(saved.name, "magnifyingglass", nil)
                            .tag(Scope.saved(saved))
                            .help(saved.query)
                            .contextMenu {
                                Button {
                                    searchRenaming = saved
                                } label: {
                                    Label("Yeniden adlandır…", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    Task { await model.deleteSavedSearch(saved) }
                                } label: {
                                    Label("Aramayı sil", systemImage: "trash")
                                }
                            }
                    }
                }
            }
            Section("Galeri") {
                row(String(localized: "Fotoğraflar"), "photo.on.rectangle", nil).tag(Scope.photos)
                row(String(localized: "Videolar"), "play.rectangle", nil).tag(Scope.videos)
            }
            Section("Platformlar") {
                ForEach(Platform.allCases) { p in
                    let n = model.stats?.byPlatform[p.rawValue] ?? 0
                    if n > 0 || p == .x {
                        row(p.label, image: FolderIcons.image(forPlatform: p), n).tag(Scope.platform(p))
                    }
                }
            }
            if !model.tagTree.isEmpty {
                Section("Etiketler") {
                    OutlineGroup(model.tagTree, children: \.children) { node in
                        row(node.name, "number", node.count > 0 ? node.count : nil)
                            .tag(Scope.tag(node.id))
                            .contextMenu {
                                Button {
                                    renaming = node
                                } label: {
                                    Label("Yeniden adlandır…", systemImage: "pencil")
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .tint(Theme.accent)
        .contentMargins(.bottom, Theme.Spacing.lg, for: .scrollContent)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .navigationTitle("wroopmark")
        .sheet(isPresented: $showNewFolderSheet) {
            NameSheet(
                title: String(localized: "Yeni klasör"),
                message: String(localized: "Kayıtları bu klasörde toplayabilirsin."),
                placeholder: String(localized: "Klasör adı"),
                actionTitle: String(localized: "Oluştur"),
                symbol: "folder.badge.plus"
            ) { name in
                Task { _ = await model.addFolder(name: name) }
            }
        }
        .sheet(item: $folderRenaming) { folder in
            NameSheet(
                title: String(localized: "Klasörü yeniden adlandır"),
                message: String(localized: "Yeni ad, alt klasörlerin yolunu da günceller."),
                placeholder: String(localized: "Yeni ad"),
                actionTitle: String(localized: "Adlandır"),
                symbol: "pencil",
                initialName: folder.name
            ) { name in
                Task { await model.renameFolder(id: folder.id, name: name) }
            }
        }
        .sheet(item: $parentForSubfolder) { parent in
            NameSheet(
                title: String(localized: "Yeni Alt Klasör"),
                message: String(localized: "\"\(parent.name)\" klasörünün altına yeni alt klasör ekle."),
                placeholder: String(localized: "Alt klasör adı"),
                actionTitle: String(localized: "Ekle"),
                symbol: "folder.badge.plus"
            ) { name in
                Task { _ = await model.addSubfolder(parent: parent, name: name) }
            }
        }
        .confirmationDialog(
            "\"\(folderToDelete?.name ?? "")\" klasörünü silmek istediğine emin misin?",
            isPresented: Binding(get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Klasörü sil", role: .destructive) {
                if let f = folderToDelete {
                    folderToDelete = nil
                    Task { await model.deleteFolder(id: f.id) }
                }
            }
            Button("Vazgeç", role: .cancel) { folderToDelete = nil }
        } message: {
            Text("Klasör silinir ancak içindeki kayıtlar kütüphanenizde kalmaya devam eder.")
        }
        .sheet(item: $renaming) { node in
            NameSheet(
                title: String(localized: "Etiketi yeniden adlandır"),
                message: String(localized: "Alt etiketler de taşınır: \(node.id)/… → yeni/…"),
                placeholder: String(localized: "yeni ad"),
                actionTitle: String(localized: "Adlandır"),
                symbol: "tag",
                initialName: node.id
            ) { name in
                Task { await model.renameTag(from: node.id, to: name) }
            }
        }
        .sheet(item: $searchRenaming) { saved in
            NameSheet(
                title: String(localized: "Aramayı yeniden adlandır"),
                message: saved.query,
                placeholder: "Ad",
                actionTitle: String(localized: "Adlandır"),
                symbol: "magnifyingglass",
                initialName: saved.name
            ) { name in
                Task { await model.renameSavedSearch(saved, to: name) }
            }
        }
    }

    /// "Link havuzu" is both a destination and a disclosure group. A plain
    /// DisclosureGroup cannot carry a List selection tag, so the row owns the
    /// tag and the chevron toggles the children without adding a duplicate
    /// "Tümü" row underneath.
    private var linkPoolRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Label("Link havuzu", systemImage: "link")
            Spacer(minLength: Theme.Spacing.sm)
            if let count = model.stats?.links {
                sidebarCount(count)
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(linkPoolExpanded ? 90 : 0))
                .frame(width: 12)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
        .simultaneousGesture(TapGesture().onEnded {
            withAnimation(.snappy(duration: 0.18)) { linkPoolExpanded.toggle() }
        })
        .accessibilityHint(linkPoolExpanded ? "Kategorileri gizler" : "Kategorileri gösterir")
    }

    private var foldersHeader: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text("Klasörler")
            Spacer()
            Button {
                showNewFolderSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Yeni klasör ekle")
            .help("Yeni klasör ekle")
        }
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Button {
                model.showDownloads.toggle()
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: model.isDownloading ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .frame(width: 16, height: 16)
                        .foregroundStyle(model.isDownloading ? Theme.accent : .secondary)
                    Text(model.isDownloading ? "İndirmeler sürüyor…" : "İndirmeler")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(model.isDownloading ? Theme.accent : .primary)
                    Spacer(minLength: Theme.Spacing.sm)
                    if model.activeOrQueuedDownloadsCount > 0 {
                        Text("\(model.activeOrQueuedDownloadsCount)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, Theme.Spacing.sm)
                            .padding(.vertical, Theme.Spacing.xs)
                            .background(Theme.accent, in: Capsule())
                            .monospacedDigit()
                    }
                }
                .padding(.vertical, Theme.Spacing.sm)
                .padding(.horizontal, Theme.Spacing.md)
                .background(
                    hoveringDownloads ? Theme.Stroke.subtleHoverFill : Theme.Stroke.subtleFill,
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .strokeBorder(
                            hoveringDownloads ? Theme.Stroke.surfaceHoverBorder : Theme.Stroke.surfaceBorder,
                            lineWidth: Theme.Stroke.hairlineWidth
                        )
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .onHover { hoveringDownloads = $0 }
            .animation(.easeOut(duration: 0.12), value: hoveringDownloads)
            .help("İndirme paneli (⌘J)")

            if let s = model.stats, s.mediaPending > 0 {
                statusLine(String(localized: "\(s.mediaPending) kaydın medyası iniyor"), symbol: "arrow.down.circle")
            }
            if model.isFetchingVideos, let n = model.stats?.videosMissing, n > 0 {
                statusLine(String(localized: "\(n) video iniyor"), symbol: "film")
            }
            if model.isReadingText, let n = model.stats?.ocrPending, n > 0 {
                statusLine(String(localized: "\(n) kayıtta yazı okunuyor"), symbol: "text.viewfinder")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func statusLine(_ text: String, symbol: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: symbol)
                .frame(width: 16, height: 16)
            Text(text)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Spacing.md)
    }

    private func row(_ title: String, _ symbol: String, _ count: Int?) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Label(title, systemImage: symbol)
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.sm)
            if let count {
                sidebarCount(count)
            }
        }
    }

    private func row(_ title: String, image: NSImage, _ count: Int?) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Label {
                Text(title)
                    .lineLimit(1)
            } icon: {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            }
            Spacer(minLength: Theme.Spacing.sm)
            if let count {
                sidebarCount(count)
            }
        }
    }

    /// Counts share one type size and one trailing edge; mixing `.callout`
    /// with the sidebars's body text made rows look uneven.
    private func sidebarCount(_ count: Int) -> some View {
        Text(count.formatted())
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}
