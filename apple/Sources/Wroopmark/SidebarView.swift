import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: TagNode?
    @State private var newName = ""
    @State private var showNewFolderSheet = false
    @State private var newFolderName = ""
    @State private var folderRenaming: Folder?
    @State private var folderNewName = ""
    @State private var folderToDelete: Folder?
    @State private var parentForSubfolder: Folder?
    @State private var newSubfolderName = ""
    @AppStorage("linkPoolExpanded") private var linkPoolExpanded = true
    @State private var searchRenaming: SavedSearch?
    @State private var searchNewName = ""

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
                                    Button("Alt klasör ekle…") {
                                        parentForSubfolder = f
                                        newSubfolderName = ""
                                    }
                                    Divider()
                                    Button("Yeniden adlandır…") {
                                        folderRenaming = f
                                        folderNewName = node.name
                                    }
                                    Divider()
                                    Button("Klasörü sil", role: .destructive) {
                                        folderToDelete = f
                                    }
                                }
                            }
                    }
                } else {
                    Button {
                        newFolderName = ""
                        showNewFolderSheet = true
                    } label: {
                        Label("Klasör oluştur…", systemImage: "folder.badge.plus")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                }
            } header: {
                HStack {
                    Text("Klasörler")
                    Spacer()
                    Button {
                        newFolderName = ""
                        showNewFolderSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
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
                                Button("Yeniden adlandır…") {
                                    searchNewName = saved.name
                                    searchRenaming = saved
                                }
                                Button("Aramayı sil", role: .destructive) {
                                    Task { await model.deleteSavedSearch(saved) }
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
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    model.showDownloads.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: model.isDownloading ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(model.isDownloading ? Theme.accent : .secondary)
                        Text(model.isDownloading ? "İndirmeler sürüyor…" : "İndirmeler")
                            .font(.caption)
                            .foregroundStyle(model.isDownloading ? Theme.accent : .primary)
                        Spacer()
                        if model.activeOrQueuedDownloadsCount > 0 {
                            Text("\(model.activeOrQueuedDownloadsCount)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Theme.accent, in: Capsule())
                                .monospacedDigit()
                        }
                    }
                    .padding(.vertical, 4).padding(.horizontal, 6)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("İndirme paneli (⌘J)")

                if let s = model.stats, s.mediaPending > 0 {
                    Label("\(s.mediaPending) kaydın medyası iniyor", systemImage: "arrow.down.circle")
                        .monospacedDigit()
                }
                if model.isFetchingVideos, let n = model.stats?.videosMissing, n > 0 {
                    Label("\(n) video iniyor", systemImage: "film")
                        .monospacedDigit()
                }
                if model.isReadingText, let n = model.stats?.ocrPending, n > 0 {
                    Label("\(n) kayıtta yazı okunuyor", systemImage: "text.viewfinder")
                        .monospacedDigit()
                }
            }
            .font(.caption).foregroundStyle(.secondary).padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("wroopmark")
        .alert("Aramayı yeniden adlandır", isPresented: Binding(get: { searchRenaming != nil }, set: { if !$0 { searchRenaming = nil } })) {
            TextField("Ad", text: $searchNewName)
            Button("Adlandır") {
                if let saved = searchRenaming {
                    let name = searchNewName
                    Task { await model.renameSavedSearch(saved, to: name) }
                }
            }
            Button("Vazgeç", role: .cancel) {}
        }
        .sheet(isPresented: $showNewFolderSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Yeni klasör").font(.headline)
                Text("Kayıtları bu klasörde toplayabilirsin.").font(.caption).foregroundStyle(.secondary)
                TextField("Klasör adı", text: $newFolderName)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 260, idealWidth: 320)
                HStack {
                    Spacer()
                    Button("Vazgeç") { showNewFolderSheet = false }.keyboardShortcut(.cancelAction)
                    Button("Oluştur") {
                        let name = newFolderName
                        showNewFolderSheet = false
                        Task { _ = await model.addFolder(name: name) }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
        }
        .sheet(item: $folderRenaming) { folder in
            VStack(alignment: .leading, spacing: 12) {
                Text("Klasörü yeniden adlandır").font(.headline)
                TextField("Yeni ad", text: $folderNewName)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 260, idealWidth: 320)
                HStack {
                    Spacer()
                    Button("Vazgeç") { folderRenaming = nil }.keyboardShortcut(.cancelAction)
                    Button("Adlandır") {
                        let id = folder.id
                        let name = folderNewName
                        folderRenaming = nil
                        Task { await model.renameFolder(id: id, name: name) }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(folderNewName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
        }
        .sheet(item: $parentForSubfolder) { parent in
            VStack(alignment: .leading, spacing: 12) {
                Text("Yeni Alt Klasör").font(.headline)
                Text("\"\(parent.name)\" klasörünün altına yeni alt klasör ekle.").font(.caption).foregroundStyle(.secondary)
                TextField("Alt klasör adı", text: $newSubfolderName)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 260, idealWidth: 320)
                HStack {
                    Spacer()
                    Button("Vazgeç") { parentForSubfolder = nil }.keyboardShortcut(.cancelAction)
                    Button("Ekle") {
                        let name = newSubfolderName
                        parentForSubfolder = nil
                        Task { _ = await model.addSubfolder(parent: parent, name: name) }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newSubfolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
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
            VStack(alignment: .leading, spacing: 12) {
                Text("Etiketi yeniden adlandır").font(.headline)
                Text("Alt etiketler de taşınır: \(node.id)/… → yeni/…").font(.caption).foregroundStyle(.secondary)
                TextField("yeni ad", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 260, idealWidth: 320)
                HStack {
                    Spacer()
                    Button("Vazgeç") { renaming = nil }.keyboardShortcut(.cancelAction)
                    Button("Adlandır") {
                        let from = node.id
                        let to = newName
                        renaming = nil
                        Task { await model.renameTag(from: from, to: to) }
                    }
                    .buttonStyle(.borderedProminent)
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

    private func row(_ title: String, image: NSImage, _ count: Int?) -> some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 15, height: 15)
            }
            Spacer()
            if let count { Text(count.formatted()).foregroundStyle(.secondary).monospacedDigit() }
        }
    }
}
