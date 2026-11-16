import SwiftUI

enum PhoneTool: String, Identifiable, CaseIterable {
    case gallery, links, rules, duplicates, export, foldersTags, filters
    var id: String { rawValue }
}

/// Modal container for Mac-parity iPhone/iPad tools.
struct PhoneToolSheet: View {
    @Environment(\.dismiss) private var dismiss
    let tool: PhoneTool

    var body: some View {
        NavigationStack {
            Group {
                switch tool {
                case .gallery: PhoneGalleryView()
                case .links: PhoneLinksView()
                case .rules: PhoneRulesView()
                case .duplicates: PhoneDuplicatesView()
                case .export: PhoneExportSheet()
                case .foldersTags: PhoneFoldersTagsView()
                case .filters: PhoneFilterSheet()
                }
            }
            .navigationDestination(for: String.self) { ItemView(id: $0) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Galeri

struct PhoneGalleryView: View {
    @Environment(PhoneModel.self) private var model

    enum Filter: String, CaseIterable, Identifiable {
        case all, images, videos
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: String(localized: "Tümü")
            case .images: String(localized: "Görseller")
            case .videos: String(localized: "Videolar")
            }
        }
        var filterTerm: String {
            switch self {
            case .all: "has:media"
            case .images: "has:image"
            case .videos: "has:video"
            }
        }
    }

    private struct Tile: Identifiable {
        let id: String
        let itemID: String
        let file: String
        let isVideo: Bool
    }

    @State private var filter: Filter = .all
    @State private var items: [Item] = []
    @State private var loading = false
    @State private var reachedEnd = false

    private var tiles: [Tile] {
        items.flatMap { item in
            item.allMedia.enumerated().compactMap { idx, m in
                guard let file = m.file else { return nil }
                if filter == .images && m.isVideo { return nil }
                if filter == .videos && !m.isVideo { return nil }
                return Tile(id: "\(item.id)#\(idx)", itemID: item.id, file: file, isVideo: m.isVideo)
            }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 3)]

    var body: some View {
        ScrollView {
            Picker("Tür", selection: $filter) {
                ForEach(Filter.allCases) { f in Text(f.title).tag(f) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            if tiles.isEmpty && !loading {
                ContentUnavailableView(
                    "Medya bulunamadı",
                    systemImage: "photo.on.rectangle",
                    description: Text("İndirilen görseller ve video kapakları burada ızgara olarak görünür.")
                )
                .padding(.top, 48)
            } else {
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(tiles) { tile in
                        NavigationLink(value: tile.itemID) {
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay {
                                    LocalImage(file: tile.file, maxPixel: 260)
                                }
                                .clipped()
                                .overlay(alignment: .bottomTrailing) {
                                    if tile.isVideo {
                                        Image(systemName: "play.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.white)
                                            .padding(5)
                                            .background(.black.opacity(0.55), in: .circle)
                                            .padding(5)
                                    }
                                }
                        }
                        .accessibilityLabel(tile.isVideo ? "Video kaydı" : "Görsel kaydı")
                        .onAppear {
                            if tile.id == tiles.last?.id {
                                Task { await loadMore() }
                            }
                        }
                    }
                }
            }
            if loading { ProgressView().padding() }
        }
        .navigationTitle("Galeri")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: filter) { await reload() }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        let base = [model.effectiveQuery, filter.filterTerm].filter { !$0.isEmpty }.joined(separator: " ")
        if let r: SearchResult = try? await model.core.call(model.searchCommand(q: base, sort: "", limit: 60, offset: 0)) {
            items = r.items
            reachedEnd = r.items.count < 60
        }
    }

    private func loadMore() async {
        guard !loading, !reachedEnd else { return }
        loading = true
        defer { loading = false }
        let base = [model.effectiveQuery, filter.filterTerm].filter { !$0.isEmpty }.joined(separator: " ")
        if let r: SearchResult = try? await model.core.call(model.searchCommand(q: base, sort: "", limit: 60, offset: items.count)) {
            let known = Set(items.map(\.id))
            items += r.items.filter { !known.contains($0.id) }
            reachedEnd = r.items.count < 60
        }
    }
}

// MARK: - Link Havuzu

struct PhoneLinksView: View {
    @Environment(PhoneModel.self) private var model
    @State private var q = ""
    @State private var category: LinkCategory?
    @State private var onlyDead = false
    @State private var links: [LinkRow] = []
    @State private var deadTotal = 0
    @State private var loading = false
    @State private var reachedEnd = false
    @State private var checking = false
    @State private var checkedCount = 0
    @State private var checkTask: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        categoryChip(nil, title: String(localized: "Tümü"))
                        ForEach(LinkCategory.allCases) { c in
                            categoryChip(c, title: c.label)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))

                Toggle(isOn: $onlyDead) {
                    Label(deadTotal > 0 ? "Yalnızca kırık linkler (\(deadTotal))" : "Yalnızca kırık linkler", systemImage: "exclamationmark.triangle")
                }

                Button {
                    if checking {
                        checkTask?.cancel()
                    } else {
                        startChecking()
                    }
                } label: {
                    HStack {
                        Label(checking ? "Taranıyor (\(checkedCount)) — durdur" : "Kırık Linkleri Tara", systemImage: "stethoscope")
                        if checking { Spacer(); ProgressView() }
                    }
                }
            }

            if links.isEmpty && !loading {
                ContentUnavailableView(
                    onlyDead ? "Kırık link yok" : "Link bulunamadı",
                    systemImage: "link",
                    description: Text("Kaydedilen gönderilerdeki dış bağlantılar burada toplanır.")
                )
                .listRowSeparator(.hidden)
            } else {
                ForEach(links) { link in
                    NavigationLink {
                        PhoneLinkItemsView(link: link)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(link.host)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(PhoneTheme.accent)
                                Spacer()
                                if let code = link.status, code >= 400 || code == 0 {
                                    Text(code == 0 ? "Erişilemedi" : "HTTP \(code)")
                                        .font(.caption2.monospacedDigit())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.red.opacity(0.15), in: .capsule)
                                        .foregroundStyle(.red)
                                }
                            }
                            Text(link.title ?? link.url)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2)
                            Text(link.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                    }
                    .onAppear {
                        if link.id == links.last?.id { Task { await loadMore() } }
                    }
                    .swipeActions {
                        Button("Sil", role: .destructive) {
                            Task { await delete(link) }
                        }
                    }
                }
            }
        }
        .searchable(text: $q, prompt: "URL veya site ara")
        .navigationTitle("Link Havuzu")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: q) { _, _ in Task { await reload() } }
        .onChange(of: category) { _, _ in Task { await reload() } }
        .onChange(of: onlyDead) { _, _ in Task { await reload() } }
        .task { await reload() }
        .onDisappear { checkTask?.cancel() }
    }

    private func categoryChip(_ cat: LinkCategory?, title: String) -> some View {
        let active = category == cat
        return Button(title) {
            category = cat
        }
        .buttonStyle(.bordered)
        .tint(active ? PhoneTheme.accent : .secondary)
        .controlSize(.small)
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        if let page: LinksPage = try? await model.core.call(.linksPage(
            q: q.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category?.apiKey,
            onlyDead: onlyDead,
            limit: 60,
            offset: 0
        )) {
            links = page.links
            deadTotal = page.counts.dead
            reachedEnd = page.links.count < 60
        }
    }

    private func loadMore() async {
        guard !loading, !reachedEnd else { return }
        loading = true
        defer { loading = false }
        if let page: LinksPage = try? await model.core.call(.linksPage(
            q: q.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category?.apiKey,
            onlyDead: onlyDead,
            limit: 60,
            offset: links.count
        )) {
            let known = Set(links.map(\.id))
            links += page.links.filter { !known.contains($0.id) }
            reachedEnd = page.links.count < 60
        }
    }

    private func delete(_ link: LinkRow) async {
        if await model.perform(.deleteLink(id: link.id)) {
            links.removeAll { $0.id == link.id }
            await reload()
        }
    }

    private func startChecking() {
        checkTask?.cancel()
        checking = true
        checkedCount = 0
        checkTask = Task {
            defer { checking = false }
            while !Task.isCancelled {
                guard let n: Int = try? await model.core.call(.checkLinks(limit: 10), network: true), n > 0 else {
                    break
                }
                checkedCount += n
                await reload()
            }
            await reload()
        }
    }
}

private struct PhoneLinkItemsView: View {
    @Environment(PhoneModel.self) private var model
    let link: LinkRow
    @State private var items: [Item] = []
    @State private var loading = true

    var body: some View {
        List {
            if let u = URL(string: link.url) {
                Section {
                    Link(destination: u) {
                        Label("Tarayıcıda aç", systemImage: "safari")
                    }
                }
            }
            Section("Geçtiği kayıtlar") {
                if loading {
                    ProgressView()
                } else if items.isEmpty {
                    Text("Kayıt bulunamadı.").foregroundStyle(.secondary)
                } else {
                    ForEach(items) { item in
                        NavigationLink(value: item.id) { ItemRowView(item: item) }
                    }
                }
            }
        }
        .navigationTitle(link.host)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            items = (try? await model.core.call(.linkItems(id: link.id, limit: 60, offset: 0))) ?? []
            loading = false
        }
    }
}

// MARK: - Kurallar

struct PhoneRulesView: View {
    @Environment(PhoneModel.self) private var model
    @State private var rules: [RuleRow] = []
    @State private var query = ""
    @State private var tag = ""
    @State private var folderID: Int64?
    @State private var applyNow = true
    @State private var matchCount: Int?
    @State private var error: String?

    private var canAdd: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
            && (!tag.trimmingCharacters(in: .whitespaces).isEmpty || folderID != nil)
    }

    var body: some View {
        Form {
            Section {
                TextField("Arama (ör. site:github.com)", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let matchCount {
                    Text("Şu an \(matchCount) kayıt eşleşiyor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("Etiket ekle", text: $tag)
                    .textInputAutocapitalization(.never)
                Picker("Klasöre koy", selection: $folderID) {
                    Text("Klasör yok").tag(Int64?.none)
                    ForEach(model.folders) { f in
                        Text(f.name.replacingOccurrences(of: "/", with: " › ")).tag(Int64?.some(f.id))
                    }
                }
                Toggle("Mevcut kayıtlara uygula", isOn: $applyNow)
                Button("Kural ekle") {
                    Task { await add() }
                }
                .disabled(!canAdd)
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Yeni kural")
            } footer: {
                Text("Kaydedilen her yeni öğe kurallardan geçer.")
            }

            Section("Kurallar") {
                if rules.isEmpty {
                    Text("Henüz kural yok.").foregroundStyle(.secondary)
                } else {
                    ForEach(rules) { rule in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(rule.query).font(.callout.monospaced())
                                HStack(spacing: 8) {
                                    if let t = rule.tag { Label("#\(t)", systemImage: "tag").foregroundStyle(PhoneTheme.accent) }
                                    if let f = rule.folderName { Label(f, systemImage: "folder") }
                                    Text("\(rule.matches) eşleşme").foregroundStyle(.secondary)
                                }
                                .font(.caption)
                            }
                            Spacer()
                            Button("Uygula") {
                                Task {
                                    _ = await model.perform(.call("apply_rule", ["id": .int(rule.id)]))
                                    await load()
                                    await model.reload()
                                    await model.refreshMeta()
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Toggle("", isOn: Binding(
                                get: { rule.enabled },
                                set: { on in Task { await toggle(rule, enabled: on) } }
                            ))
                            .labelsHidden()
                        }
                        .swipeActions {
                            Button("Sil", role: .destructive) {
                                Task {
                                    _ = await model.perform(.call("delete_rule", ["id": .int(rule.id)]))
                                    await load()
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Kurallar")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: query) { _, v in
            Task {
                let clean = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if clean.isEmpty {
                    matchCount = nil
                } else {
                    matchCount = try? await model.core.call(.call("count", ["q": .string(clean)]), as: Int.self)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        rules = (try? await model.core.call(.call("rules", [:]))) ?? []
    }

    private func add() async {
        struct Added: Decodable { let applied: Int }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let r: Added = try await model.core.call(.call("add_rule", [
                "query": .string(q),
                "tag": t.isEmpty ? .null : .string(t),
                "folder_id": folderID.map { .int($0) } ?? .null,
                "apply": .bool(applyNow),
            ]))
            error = nil
            query = ""
            tag = ""
            folderID = nil
            matchCount = nil
            await load()
            if r.applied > 0 {
                await model.reload()
                await model.refreshMeta()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func toggle(_ rule: RuleRow, enabled: Bool) async {
        _ = await model.perform(.call("update_rule", [
            "id": .int(rule.id),
            "query": .string(rule.query),
            "tag": rule.tag.map { .string($0) } ?? .null,
            "folder_id": rule.folderId.map { .int($0) } ?? .null,
            "enabled": .bool(enabled),
        ]))
        await load()
    }
}

// MARK: - Kopyalar

struct PhoneDuplicatesView: View {
    @Environment(PhoneModel.self) private var model
    @State private var groups: [DuplicateGroup] = []
    @State private var loading = true

    var body: some View {
        List {
            if loading {
                ProgressView()
            } else if groups.isEmpty {
                ContentUnavailableView(
                    "Kopya kayıt bulunamadı",
                    systemImage: "square.on.square",
                    description: Text("Aynı görsel, video ya da çok benzer metne sahip kayıtlar burada gruplanır.")
                )
                .listRowSeparator(.hidden)
            } else {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.items) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                NavigationLink(value: item.id) { ItemRowView(item: item) }
                                Button("Yalnızca bunu sakla") {
                                    Task { await keepOnly(item.id, in: group) }
                                }
                                .font(.caption.weight(.medium))
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        Button("Benzer sayma", role: .cancel) {
                            Task { await ignore(group) }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    } header: {
                        Text(group.reasonLabel)
                    }
                }
            }
        }
        .navigationTitle("Kopyalar")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        loading = true
        groups = (try? await model.core.call(.call("duplicates", [:]))) ?? []
        loading = false
    }

    private func keepOnly(_ keepID: String, in group: DuplicateGroup) async {
        for item in group.items where item.id != keepID {
            await model.delete(item.id)
        }
        groups.removeAll { $0.id == group.id }
    }

    private func ignore(_ group: DuplicateGroup) async {
        _ = await model.perform(.call("ignore_duplicates", ["ids": .strings(group.items.map(\.id))]))
        groups.removeAll { $0.id == group.id }
    }
}

// MARK: - Dışa Aktar

struct PhoneExportSheet: View {
    @Environment(PhoneModel.self) private var model

    enum ExportFormat: String, CaseIterable, Identifiable {
        case markdown, csv, json, html
        var id: String { rawValue }
        var title: String {
            switch self {
            case .markdown: "Markdown (.md)"
            case .csv: "CSV (.csv)"
            case .json: "JSON (.json)"
            case .html: String(localized: "Tek HTML sayfası (.html)")
            }
        }
    }

    @State private var scopeAll = false
    @State private var format: ExportFormat = .markdown
    @State private var withMedia = false
    @State private var exporting = false
    @State private var shareURL: IdentifiableURL?
    @State private var exportError: String?

    private struct IdentifiableURL: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    private var hasFilter: Bool {
        model.scope != .all || !model.effectiveQuery.isEmpty
    }

    var body: some View {
        Form {
            Section("Kapsam") {
                Picker("Kayıtlar", selection: $scopeAll) {
                    if hasFilter { Text("Görünen liste").tag(false) }
                    Text("Tüm arşiv").tag(true)
                }
            }

            Section("Biçim") {
                Picker("Dosya türü", selection: $format) {
                    ForEach(ExportFormat.allCases) { f in Text(f.title).tag(f) }
                }
                if format != .html {
                    Toggle("Medya dosyalarını dahil et", isOn: $withMedia)
                }
            }

            Section {
                Button {
                    Task { await runExport() }
                } label: {
                    HStack {
                        Label(exporting ? "Hazırlanıyor…" : "Dışa aktar ve paylaş…", systemImage: "square.and.arrow.up")
                        if exporting { Spacer(); ProgressView() }
                    }
                }
                .disabled(exporting)
                if let exportError {
                    Text(exportError).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text(format == .html
                    ? "Görseller gömülü tek çevrimdışı HTML sayfası oluşturulur."
                    : (withMedia ? "Kayıtlar ve medya dosyaları tek klasör olarak Dosyalar'a aktarılır." : "Markdown dosyası vurguları, notları ve X yanıtlarını içerir."))
            }
        }
        .navigationTitle("Dışa Aktar")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if !hasFilter { scopeAll = true } }
        .sheet(item: $shareURL) { ShareSheet(url: $0.url) }
    }

    private func runExport() async {
        exporting = true
        exportError = nil
        defer { exporting = false }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wm-export-\(UUID().uuidString)", isDirectory: true)
        let q = scopeAll ? "" : model.effectiveQuery
        let title = scopeAll ? "wroopmark" : model.scope.title
        let english = Locale.current.language.languageCode?.identifier == "en"

        do {
            let r: ExportReport = try await model.core.call(.call("export", [
                "q": .string(q),
                "format": .string(format.rawValue),
                "dest": .string(dir.path),
                "media": .bool(withMedia),
                "title": .string(title),
                "lang": .string(english ? "en" : "tr"),
            ]))
            let url = (withMedia && format != .html) ? dir : URL(fileURLWithPath: r.path)
            shareURL = IdentifiableURL(url: url)
        } catch {
            exportError = error.localizedDescription
        }
    }
}

// MARK: - Klasör ve Etiket Yönetimi

struct PhoneFoldersTagsView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var addingFolder = false
    @State private var newFolderName = ""
    @State private var parentPrefix: String?
    @State private var renamingFolder: Folder?
    @State private var folderDraft = ""
    @State private var deletingFolder: Folder?
    @State private var renamingTag: TagCount?
    @State private var tagDraft = ""

    private var tree: [FolderNode] { FolderNode.tree(model.folders) }

    var body: some View {
        List {
            Section {
                Button {
                    parentPrefix = nil
                    newFolderName = ""
                    addingFolder = true
                } label: {
                    Label("Yeni klasör…", systemImage: "folder.badge.plus")
                }
                if tree.isEmpty {
                    Text("Henüz klasör yok.").foregroundStyle(.secondary)
                } else {
                    OutlineGroup(tree, children: \.children) { node in
                        HStack {
                            Button {
                                if let f = node.folder {
                                    model.scope = .folder(f.id, f.name)
                                    dismiss()
                                }
                            } label: {
                                Label {
                                    Text(node.name)
                                } icon: {
                                    Image(systemName: "folder")
                                }
                            }
                            .foregroundStyle(.primary)
                            Spacer()
                            if node.count > 0 {
                                Text("\(node.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            if let f = node.folder {
                                Button {
                                    parentPrefix = f.name
                                    newFolderName = ""
                                    addingFolder = true
                                } label: {
                                    Label("Alt klasör ekle…", systemImage: "folder.badge.plus")
                                }
                                Button {
                                    renamingFolder = f
                                    folderDraft = f.name
                                } label: {
                                    Label("Yeniden adlandır…", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    deletingFolder = f
                                } label: {
                                    Label("Sil", systemImage: "trash")
                                }
                            }
                        }
                        .swipeActions {
                            if let f = node.folder {
                                Button("Sil", role: .destructive) { deletingFolder = f }
                                Button("Adlandır") {
                                    renamingFolder = f
                                    folderDraft = f.name
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }
            } header: {
                Text("Klasörler")
            }

            if !model.tags.isEmpty {
                Section("Etiketler") {
                    ForEach(model.tags, id: \.key) { tag in
                        HStack {
                            Button("#\(tag.name)") {
                                model.scope = .tag(tag.key)
                                dismiss()
                            }
                            .foregroundStyle(.primary)
                            Spacer()
                            Text("\(tag.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Adlandır") {
                                renamingTag = tag
                                tagDraft = tag.name
                            }
                            .tint(.orange)
                        }
                        .contextMenu {
                            Button {
                                renamingTag = tag
                                tagDraft = tag.name
                            } label: {
                                Label("Yeniden adlandır…", systemImage: "pencil")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Klasörler ve Etiketler")
        .navigationBarTitleDisplayMode(.inline)
        .alert(parentPrefix == nil ? "Yeni klasör" : "Alt klasör ekle", isPresented: $addingFolder) {
            TextField("Ad (ör. Ders/Matematik)", text: $newFolderName)
            Button("Oluştur") {
                let raw = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                let full = parentPrefix.map { "\($0)/\(raw)" } ?? raw
                Task { _ = await model.addFolder(name: full) }
            }
            Button("Vazgeç", role: .cancel) {}
        }
        .alert("Klasörü yeniden adlandır", isPresented: Binding(
            get: { renamingFolder != nil },
            set: { if !$0 { renamingFolder = nil } }
        )) {
            TextField("Klasör adı", text: $folderDraft)
            Button("Kaydet") {
                if let f = renamingFolder {
                    let next = folderDraft
                    Task { await model.renameFolder(id: f.id, name: next) }
                }
                renamingFolder = nil
            }
            Button("Vazgeç", role: .cancel) { renamingFolder = nil }
        }
        .alert("Etiketi yeniden adlandır", isPresented: Binding(
            get: { renamingTag != nil },
            set: { if !$0 { renamingTag = nil } }
        )) {
            TextField("Etiket adı", text: $tagDraft)
                .textInputAutocapitalization(.never)
            Button("Kaydet") {
                if let t = renamingTag {
                    let next = tagDraft
                    Task { await model.renameTag(from: t.name, to: next) }
                }
                renamingTag = nil
            }
            Button("Vazgeç", role: .cancel) { renamingTag = nil }
        }
        .confirmationDialog(
            "Klasör silinsin mi? İçindeki kayıtlar silinmez.",
            isPresented: Binding(
                get: { deletingFolder != nil },
                set: { if !$0 { deletingFolder = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Klasörü sil", role: .destructive) {
                if let f = deletingFolder {
                    Task { await model.deleteFolder(id: f.id) }
                }
                deletingFolder = nil
            }
        }
    }
}

// MARK: - Sıralama ve Filtreler

struct PhoneFilterSheet: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let chips: [(token: String, title: String, symbol: String)] = [
        ("has:video", String(localized: "Videolu"), "play.rectangle"),
        ("has:image", String(localized: "Fotoğraflı"), "photo"),
        ("has:link", String(localized: "Bağlantılı"), "link"),
        ("has:note", String(localized: "Notlu"), "note.text"),
        ("has:ocr", String(localized: "Görselde yazılı"), "text.viewfinder"),
        ("has:highlight", String(localized: "Vurgulu"), "highlighter"),
        ("has:thread", String(localized: "Zincirli"), "text.line.first.and.arrowtriangle.forward"),
        ("is:untagged", String(localized: "Etiketsiz"), "tag.slash"),
        ("is:unfiled", String(localized: "Klasörsüz"), "tray"),
    ]

    private let sortOptions: [(id: String, label: String)] = [
        ("", String(localized: "Önerilen")),
        ("saved", String(localized: "Kaydedilme: yeniden eskiye")),
        ("saved_asc", String(localized: "Kaydedilme: eskiden yeniye")),
        ("posted", String(localized: "Paylaşılma: yeniden eskiye")),
        ("posted_asc", String(localized: "Paylaşılma: eskiden yeniye")),
        ("author", String(localized: "Kişiye göre (A–Z)")),
        ("random", String(localized: "Karışık")),
    ]

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Sıralama") {
                Picker("Sırala", selection: $model.sort) {
                    ForEach(sortOptions, id: \.id) { opt in
                        Text(opt.label).tag(opt.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section("İçerik süzgeçleri") {
                ForEach(chips, id: \.token) { chip in
                    let active = model.filterTokens.contains(chip.token)
                    Toggle(isOn: Binding(
                        get: { active },
                        set: { on in
                            if on { model.filterTokens.insert(chip.token) } else { model.filterTokens.remove(chip.token) }
                        }
                    )) {
                        Label(chip.title, systemImage: chip.symbol)
                    }
                }
            }

            if !model.filterTokens.isEmpty || !model.sort.isEmpty {
                Section {
                    Button("Filtreleri ve sıralamayı sıfırla", role: .destructive) {
                        model.filterTokens.removeAll()
                        model.sort = ""
                    }
                }
            }
        }
        .navigationTitle("Süz ve Sırala")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.sort) { _, _ in Task { await model.reload() } }
        .onChange(of: model.filterTokens) { _, _ in Task { await model.reload() } }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Uygula") { dismiss() }
            }
        }
    }
}

