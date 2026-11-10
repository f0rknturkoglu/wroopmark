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
                row("Tümü", "tray.full", model.stats?.items).tag(Scope.all)
                row("Etiketsiz", "tag.slash", nil).tag(Scope.untagged)
                DisclosureGroup(isExpanded: $linkPoolExpanded) {
                    row("Tümü", "link", model.stats?.links)
                        .tag(Scope.links(nil))
                    ForEach(LinkCategory.allCases) { cat in
                        row(cat.label, image: cat.iconImage, model.linkCategoryCount(cat))
                            .tag(Scope.links(cat))
                    }
                } label: {
                    row("Link havuzu", "link", model.stats?.links)
                        .tag(Scope.links(nil))
                }
                row("Ayıkla", "arrow.left.arrow.right.square", nil).tag(Scope.triage)
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .padding(.vertical, Theme.Spacing.xs)
                }
            } header: {
                HStack(spacing: Theme.Spacing.sm) {
                    Text("Klasörler")
                    Spacer()
                    Button {
                        showNewFolderSheet = true
                    } label: {
                        Label("Yeni klasör ekle", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityLabel("Yeni klasör ekle")
                    .help("Yeni klasör ekle")
                }
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
                row("Fotoğraflar", "photo.on.rectangle", nil).tag(Scope.photos)
                row("Videolar", "play.rectangle", nil).tag(Scope.videos)
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
        .contentMargins(.bottom, Theme.Spacing.lg, for: .scrollContent)
        .safeAreaInset(edge: .bottom, spacing: 0) {
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
                    statusLine("\(s.mediaPending) kaydın medyası iniyor", symbol: "arrow.down.circle")
                }
                if model.isFetchingVideos, let n = model.stats?.videosMissing, n > 0 {
                    statusLine("\(n) video iniyor", symbol: "film")
                }
                if model.isReadingText, let n = model.stats?.ocrPending, n > 0 {
                    statusLine("\(n) kayıtta yazı okunuyor", symbol: "text.viewfinder")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background)
            .overlay(alignment: .top) { Divider() }
        }
        .navigationTitle("wroopmark")
        .sheet(isPresented: $showNewFolderSheet) {
            NameSheet(
                title: "Yeni klasör",
                message: "Kayıtları bu klasörde toplayabilirsin.",
                placeholder: "Klasör adı",
                actionTitle: "Oluştur",
                symbol: "folder.badge.plus"
            ) { name in
                Task { _ = await model.addFolder(name: name) }
            }
        }
        .sheet(item: $folderRenaming) { folder in
            NameSheet(
                title: "Klasörü yeniden adlandır",
                message: "Yeni ad, alt klasörlerin yolunu da günceller.",
                placeholder: "Yeni ad",
                actionTitle: "Adlandır",
                symbol: "pencil",
                initialName: folder.name
            ) { name in
                Task { await model.renameFolder(id: folder.id, name: name) }
            }
        }
        .sheet(item: $parentForSubfolder) { parent in
            NameSheet(
                title: "Yeni Alt Klasör",
                message: "\"\(parent.name)\" klasörünün altına yeni alt klasör ekle.",
                placeholder: "Alt klasör adı",
                actionTitle: "Ekle",
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
                title: "Etiketi yeniden adlandır",
                message: "Alt etiketler de taşınır: \(node.id)/… → yeni/…",
                placeholder: "yeni ad",
                actionTitle: "Adlandır",
                symbol: "tag",
                initialName: node.id
            ) { name in
                Task { await model.renameTag(from: node.id, to: name) }
            }
        }
        .sheet(item: $searchRenaming) { saved in
            NameSheet(
                title: "Aramayı yeniden adlandır",
                message: saved.query,
                placeholder: "Ad",
                actionTitle: "Adlandır",
                symbol: "magnifyingglass",
                initialName: saved.name
            ) { name in
                Task { await model.renameSavedSearch(saved, to: name) }
            }
        }
    }

    private func statusLine(_ text: String, symbol: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: symbol)
                .frame(width: 16, height: 16)
            Text(text)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Spacing.xs)
    }

    private func row(_ title: String, _ symbol: String, _ count: Int?) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Label(title, systemImage: symbol)
                .help(title)
            Spacer(minLength: Theme.Spacing.sm)
            if let count {
                Text(count.formatted())
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func row(_ title: String, image: NSImage, _ count: Int?) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Label {
                Text(title)
            } icon: {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            }
            .help(title)
            Spacer(minLength: Theme.Spacing.sm)
            if let count {
                Text(count.formatted())
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}
