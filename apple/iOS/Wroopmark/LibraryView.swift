import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The library: a list that opens posts on the iPhone, three columns
/// (scopes, list, post) on the iPad.
struct LibraryView: View {
    @Environment(\.horizontalSizeClass) private var size
    @Environment(PhoneModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if size == .regular { PadLibrary() } else { PhoneLibrary() }
        }
        .sheet(item: $model.sharedPage) { ShareSheet(url: $0.url) }
        .overlay {
            if model.makingPage {
                ProgressView("Sayfa hazırlanıyor…")
                    .padding(20)
                    .background(.regularMaterial, in: .rect(cornerRadius: 14))
            }
        }
    }
}

/// The system share sheet for one file.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct ReadingTarget: Identifiable {
    let id: String
}

/// Rich per-row context menu + swipe actions shared between iPhone and iPad lists.
struct ItemRowActions: ViewModifier {
    @Environment(PhoneModel.self) private var model
    let item: Item
    let onRead: (String) -> Void

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    onRead(item.id)
                } label: {
                    Label("Oku", systemImage: "book")
                }
                .tint(.indigo)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Sil", role: .destructive) {
                    Task { await model.delete(item.id) }
                }
            }
            .contextMenu {
                Button {
                    onRead(item.id)
                } label: {
                    Label("Oku", systemImage: "book")
                }
                if let u = URL(string: item.url), u.scheme?.hasPrefix("http") == true {
                    Link(destination: u) {
                        Label("Kaynağında aç", systemImage: "safari")
                    }
                    Button {
                        UIPasteboard.general.string = item.url
                    } label: {
                        Label("Bağlantıyı kopyala", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: u) {
                        Label("Paylaş", systemImage: "square.and.arrow.up")
                    }
                }
                Menu {
                    if item.folderId != nil {
                        Button {
                            Task { await model.moveItems([item.id], to: nil) }
                        } label: {
                            Label("Klasörden çıkar", systemImage: "tray")
                        }
                        if !model.folders.isEmpty { Divider() }
                    }
                    ForEach(model.folders) { f in
                        Button {
                            Task { await model.moveItems([item.id], to: f.id) }
                        } label: {
                            HStack {
                                Text(f.name.replacingOccurrences(of: "/", with: " › "))
                                if item.folderId == f.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    Label("Klasöre taşı", systemImage: "folder")
                }
                Divider()
                Button("Sil", role: .destructive) {
                    Task { await model.delete(item.id) }
                }
            }
    }
}

struct PhoneLibrary: View {
    @Environment(PhoneModel.self) private var model
    @State private var showAdd = false
    @State private var showSettings = false
    @State private var showFeed = false
    @State private var showTriage = false
    @State private var activeTool: PhoneTool?
    @State private var readingTarget: ReadingTarget?
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<String>()
    @State private var showBatchTags = false
    @State private var confirmBatchDelete = false
    @State private var batchTagsInput = ""
    @State private var path: [String] = []

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            List(selection: $selection) {
                LibraryBanners()
                if model.scope == .today && model.effectiveQuery.isEmpty && model.sort.isEmpty {
                    if !model.onThisDay.isEmpty {
                        Section("Geçmişte bugün") {
                            ForEach(model.onThisDay) { item in
                                NavigationLink(value: item.id) { ItemRowView(item: item) }
                                    .tag(item.id)
                                    .modifier(ItemRowActions(item: item) { readingTarget = ReadingTarget(id: $0) })
                            }
                        }
                    }
                    if !model.rediscover.isEmpty {
                        Section("Arşivden bugün için") {
                            ForEach(model.rediscover) { item in
                                NavigationLink(value: item.id) { ItemRowView(item: item) }
                                    .tag(item.id)
                                    .modifier(ItemRowActions(item: item) { readingTarget = ReadingTarget(id: $0) })
                            }
                        }
                    }
                } else {
                    ForEach(model.items) { item in
                        NavigationLink(value: item.id) { ItemRowView(item: item) }
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
            .environment(\.editMode, $editMode)
            .navigationTitle(model.scope.title)
            .navigationSubtitle(model.total > 0 ? "\(model.total) kayıt" : "")
            .searchable(text: $model.query, prompt: "Ara: kelime, tag:dev, from:@kişi")
            .searchSuggestions {
                Button { model.filterTokens.insert("has:video") } label: { Label("Videolu kayıtlar", systemImage: "play.rectangle") }
                Button { model.filterTokens.insert("has:highlight") } label: { Label("Vurgulu kayıtlar", systemImage: "highlighter") }
                Button { model.filterTokens.insert("is:untagged") } label: { Label("Etiketsiz kayıtlar", systemImage: "tag.slash") }
                ForEach(model.tags.prefix(5), id: \.key) { t in
                    Button("#\(t.name) (\(t.count))") {
                        model.query = "tag:\(t.key)"
                    }
                }
            }
            .onChange(of: model.query) { _, _ in model.queryChanged() }
            .onChange(of: model.scope) { _, _ in Task { await model.reload() } }
            .onChange(of: model.sort) { _, _ in Task { await model.reload() } }
            .onChange(of: model.filterTokens) { _, _ in Task { await model.reload() } }
            .onChange(of: model.semanticSearch) { _, _ in Task { await model.reload() } }
            .refreshable {
                await model.syncNow()
                await model.reload()
            }
            .navigationDestination(for: String.self) { id in ItemView(id: id) }
            .safeAreaInset(edge: .bottom) {
                if editMode == .active {
                    batchActionBar
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: model.isSyncing ? "arrow.triangle.2.circlepath" : "gearshape")
                            .symbolEffect(.rotate, isActive: model.isSyncing)
                    }
                    .accessibilityLabel("Ayarlar")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { showTriage = true } label: { Image(systemName: "rectangle.stack.badge.minus") }
                        .accessibilityLabel("Ayıkla")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showFeed = true } label: { Image(systemName: "play.rectangle.on.rectangle") }
                        .accessibilityLabel("Akış")
                }
                if model.aiStatus?.embedReady == true {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { model.semanticSearch.toggle() } label: {
                            Image(systemName: model.semanticSearch ? "sparkles.rectangle.stack.fill" : "sparkles")
                        }
                        .accessibilityLabel(model.semanticSearch ? "Anlamına göre arama açık" : "Anlamına göre ara")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { activeTool = .filters } label: {
                        Image(systemName: model.filterTokens.isEmpty && model.sort.isEmpty ? "arrow.up.arrow.down.circle" : "arrow.up.arrow.down.circle.fill")
                    }
                    .accessibilityLabel("Süz ve Sırala")
                }
                ToolbarItem(placement: .topBarTrailing) { ScopeMenu() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            withAnimation {
                                if editMode == .active {
                                    editMode = .inactive
                                    selection.removeAll()
                                } else {
                                    editMode = .active
                                }
                            }
                        } label: {
                            Label(editMode == .active ? "Seçimi bitir" : "Çoklu seç", systemImage: "checklist")
                        }
                        Button { activeTool = .foldersTags } label: { Label("Klasörler ve Etiketler", systemImage: "folder.badge.gearshape") }
                        Button { activeTool = .gallery } label: { Label("Galeri", systemImage: "photo.on.rectangle") }
                        Button { activeTool = .links } label: { Label("Link Havuzu", systemImage: "link") }
                        Button { activeTool = .rules } label: { Label("Kurallar", systemImage: "slider.horizontal.3") }
                        Button { activeTool = .duplicates } label: { Label("Kopyalar", systemImage: "square.on.square") }
                        Divider()
                        Button { activeTool = .export } label: { Label("Dışa Aktar…", systemImage: "square.and.arrow.up") }
                    } label: {
                        Image(systemName: "wrench.and.screwdriver")
                    }
                    .accessibilityLabel("Araçlar")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Bağlantı veya not ekle")
                }
            }
            .alert("Seçilenleri etiketle", isPresented: $showBatchTags) {
                TextField("Etiketler (virgülle)", text: $batchTagsInput)
                    .textInputAutocapitalization(.never)
                Button("Ekle") {
                    let tags = phoneTags(batchTagsInput)
                    let ids = Array(selection)
                    Task {
                        await model.tagItems(ids, add: tags)
                        editMode = .inactive
                        selection.removeAll()
                    }
                }
                Button("Vazgeç", role: .cancel) {}
            }
            .sheet(isPresented: $showAdd) { AddURLView() }
            .sheet(item: $activeTool) { PhoneToolSheet(tool: $0) }
            .fullScreenCover(item: $readingTarget) { ReaderView(id: $0.id) }
            .onChange(of: model.openRequest) { _, id in
                if let id {
                    path = [id]
                    model.openRequest = nil
                }
            }
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
            .sheet(isPresented: $showSettings) { PhoneSettingsView() }
            .fullScreenCover(isPresented: $showFeed) { VideoFeedView(scope: model.scope, query: model.query) }
            .fullScreenCover(isPresented: $showTriage) { PhoneTriageView(scope: model.scope, query: model.query) }
        }
    }

    private var batchActionBar: some View {
        HStack(spacing: 14) {
            Text("\(selection.count) seçili")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            Spacer()
            Menu {
                Button("Klasörden çıkar") {
                    let ids = Array(selection)
                    Task {
                        await model.moveItems(ids, to: nil)
                        editMode = .inactive
                        selection.removeAll()
                    }
                }
                ForEach(model.folders) { f in
                    Button(f.name.replacingOccurrences(of: "/", with: " › ")) {
                        let ids = Array(selection)
                        Task {
                            await model.moveItems(ids, to: f.id)
                            editMode = .inactive
                            selection.removeAll()
                        }
                    }
                }
            } label: {
                Label("Klasör", systemImage: "folder")
            }
            .disabled(selection.isEmpty)

            Button {
                batchTagsInput = ""
                showBatchTags = true
            } label: {
                Label("Etiketle", systemImage: "tag")
            }
            .disabled(selection.isEmpty)

            Button(role: .destructive) {
                confirmBatchDelete = true
            } label: {
                Label("Sil", systemImage: "trash")
            }
            .disabled(selection.isEmpty)
            // Many items at once, and with sync on, on every device too.
            .confirmationDialog("\(selection.count) kaydı silmek istediğine emin misin?", isPresented: $confirmBatchDelete, titleVisibility: .visible) {
                Button("Sil", role: .destructive) {
                    let ids = Array(selection)
                    Task {
                        await model.deleteItems(ids)
                        editMode = .inactive
                        selection.removeAll()
                    }
                }
                Button("Vazgeç", role: .cancel) {}
            } message: {
                Text("Senkron açıksa diğer cihazlardan da silinir.")
            }

            Button("Bitti") {
                withAnimation {
                    editMode = .inactive
                    selection.removeAll()
                }
            }
            .fontWeight(.semibold)
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Notes above the list: errors, offline saves, a link on the clipboard,
/// low space.
struct LibraryBanners: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        Group {
            if let e = model.errorMessage {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote)
            }
            if let n = model.notice {
                Label(n, systemImage: "wifi.slash").font(.footnote).foregroundStyle(.secondary)
                    .onTapGesture { model.notice = nil }
            }
            if model.clipboardHasLink {
                HStack(spacing: 10) {
                    Image(systemName: "doc.on.clipboard").foregroundStyle(PhoneTheme.accent)
                    Text("Panoda bir bağlantı var").font(.subheadline.weight(.medium))
                    Spacer(minLength: 4)
                    // The system paste button: no "allow paste" prompt.
                    // Text, not URL: a link copied as text would leave a
                    // URL paste button disabled.
                    PasteButton(payloadType: String.self) { texts in
                        guard let link = texts.lazy.compactMap { firstLink(in: $0) }.first else { return }
                        Task {
                            _ = await model.addURL(link, tags: [])
                            model.dismissClipboard()
                        }
                    }
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    Button { model.dismissClipboard() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Kapat")
                }
                .padding(.vertical, 4)
            }
            if model.lowSpace {
                Label("Telefonda yer az (1 GB'tan az): yeni görseller yer açılana kadar indirilmiyor.", systemImage: "externaldrive.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct ScopeMenu: View {
    @Environment(PhoneModel.self) private var model
    @State private var savingSearch = false
    @State private var searchName = ""

    var body: some View {
        @Bindable var model = model
        Menu {
            Picker("Görünüm", selection: $model.scope) {
                Label("Tümü", systemImage: "tray.full").tag(PhoneScope.all)
                Label("Bugün", systemImage: "calendar.day.timeline.left").tag(PhoneScope.today)
                Label("Etiketsiz", systemImage: "tag.slash").tag(PhoneScope.untagged)
            }
            if !model.savedSearches.isEmpty {
                Menu("Kayıtlı aramalar") {
                    ForEach(model.savedSearches) { s in
                        Button {
                            model.query = ""
                            model.scope = .saved(s)
                        } label: {
                            Label(s.name, systemImage: "magnifyingglass")
                        }
                    }
                    if case .saved(let cur) = model.scope {
                        Divider()
                        Button("“\(cur.name)” aramasını sil", role: .destructive) {
                            Task { await model.deleteSavedSearch(cur) }
                        }
                    }
                }
            }
            if !model.searchToSave.isEmpty {
                Button {
                    searchName = ""
                    savingSearch = true
                } label: {
                    Label("Bu aramayı kaydet…", systemImage: "bookmark")
                }
            }
            Menu("Platform") {
                let counts = model.stats?.byPlatform ?? [:]
                ForEach(Platform.allCases.filter { (counts[$0.rawValue] ?? 0) > 0 }) { p in
                    Button { model.scope = .platform(p.rawValue) } label: {
                        Label("\(p.label) (\(counts[p.rawValue] ?? 0))", systemImage: p.symbol)
                    }
                }
            }
            if !model.folders.isEmpty {
                Menu("Klasörler") {
                    ForEach(model.folders) { f in
                        Button { model.scope = .folder(f.id, f.name) } label: {
                            Label("\(f.name.replacingOccurrences(of: "/", with: " › ")) (\(f.count))", systemImage: "folder")
                        }
                    }
                }
            }
            if !model.tags.isEmpty {
                Menu("Etiketler") {
                    ForEach(model.tags.prefix(40), id: \.key) { t in
                        Button("#\(t.name) (\(t.count))") { model.scope = .tag(t.key) }
                    }
                }
            }
            if model.scope != .all && model.scope != .today {
                Divider()
                Button {
                    Task { await model.sharePage(query: model.effectiveQuery, title: model.scope.title) }
                } label: {
                    Label("Tek sayfa olarak paylaş", systemImage: "square.and.arrow.up")
                }
            }
        } label: {
            Image(systemName: model.scope == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Süzgeç")
        .alert("Aramayı kaydet", isPresented: $savingSearch) {
            TextField("Arama adı", text: $searchName)
            Button("Kaydet") {
                let name = searchName
                Task { await model.saveSearch(name: name) }
            }
            Button("Vazgeç", role: .cancel) {}
        }
    }
}

struct ItemRowView: View {
    let item: Item

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: (Platform(rawValue: item.platform) ?? .web).symbol)
                        .font(.caption2)
                        .foregroundStyle(PhoneTheme.accent)
                    Text(item.author ?? URL(string: item.url)?.host() ?? (Platform(rawValue: item.platform) ?? .web).label)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(item.saved.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                let text = item.headline.isEmpty ? (item.quote?.item.text ?? "") : item.headline
                if !text.isEmpty {
                    Text(text).font(.callout).lineLimit(3)
                }
                if !item.tags.isEmpty {
                    Text(item.tags.map { "#\($0)" }.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(PhoneTheme.accent)
                        .lineLimit(1)
                }
            }
            if let file = item.cover?.file {
                LocalImage(file: file, maxPixel: 200)
                    .frame(width: 64, height: 64)
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay(alignment: .bottomTrailing) {
                        if item.allMedia.contains(where: \.isVideo) {
                            Image(systemName: "play.fill").font(.caption2).padding(4).background(.ultraThinMaterial, in: .circle).padding(3)
                        }
                    }
            }
        }
        .padding(.vertical, 4)
    }
}

struct AddURLView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isNote = false
    @State private var url = ""
    @State private var noteTitle = ""
    @State private var noteBody = ""
    @State private var tags = ""
    @State private var folderID: Int64?
    @State private var saving = false
    @State private var pickingImport = false
    @State private var pickingPhotos = false
    @State private var pickedPhotos: [PhotosPickerItem] = []

    private var canSave: Bool {
        if isNote {
            return !noteBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !noteTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Tür", selection: $isNote) {
                    Text("Bağlantı").tag(false)
                    Text("Not Kartı").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                if isNote {
                    Section("Not") {
                        TextField("Başlık (isteğe bağlı)", text: $noteTitle)
                        TextField("Aklındakini, alıntıyı veya fikri yaz…", text: $noteBody, axis: .vertical)
                            .lineLimit(4...10)
                    }
                } else {
                    Section("Bağlantı") {
                        HStack {
                            TextField("https://…", text: $url)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            // The system paste button: no "allow paste" prompt.
                            PasteButton(payloadType: String.self) { texts in
                                if let link = texts.lazy.compactMap { firstLink(in: $0) }.first { url = link }
                            }
                            .labelStyle(.iconOnly)
                            .buttonBorderShape(.capsule)
                            .accessibilityLabel("Panodan yapıştır")
                        }
                    }
                }

                Section("Düzenle") {
                    Picker("Klasör", selection: $folderID) {
                        Text("Klasör yok").tag(Int64?.none)
                        ForEach(model.folders) { f in
                            Text(f.name.replacingOccurrences(of: "/", with: " › ")).tag(Int64?.some(f.id))
                        }
                    }
                    TextField("Etiketler (virgülle)", text: $tags)
                        .textInputAutocapitalization(.never)
                    if !model.tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(model.tags.prefix(12), id: \.key) { t in
                                    Button("#\(t.name)") {
                                        var list = phoneTags(tags)
                                        if !list.contains(t.name) {
                                            list.append(t.name)
                                            tags = list.joined(separator: ", ")
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                }
                            }
                        }
                    }
                    if saving { HStack { ProgressView(); Text("Kaydediliyor…") } }
                }

                Section {
                    Button {
                        pickingImport = true
                    } label: {
                        HStack {
                            Label("Dosyadan içe aktar…", systemImage: "square.and.arrow.down")
                            if model.isImporting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(saving || model.isImporting)
                    Button {
                        pickingPhotos = true
                    } label: {
                        Label("Fotoğraflar'dan içe aktar…", systemImage: "photo.on.rectangle.angled")
                    }
                    .disabled(saving || model.isImporting)
                    .photosPicker(isPresented: $pickingPhotos, selection: $pickedPhotos, maxSelectionCount: 50, matching: .any(of: [.videos, .images]))
                    .onChange(of: pickedPhotos) { _, chosen in
                        guard !chosen.isEmpty else { return }
                        pickedPhotos = []
                        Task { await model.importPhotos(chosen) }
                    }
                    if let msg = model.importMessage, !msg.isEmpty, !model.isImporting {
                        Text(msg).font(.footnote).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Veri paketi (.zip), yer imleri (bookmarks.html), CSV ya da video/görsel.")
                }
            }
            .fileImporter(isPresented: $pickingImport, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    // Stays open: the result is shown under the button.
                    Task { await model.importURLs(urls) }
                }
            }
            .navigationTitle(isNote ? "Yeni Not" : "Bağlantı")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") {
                        saving = true
                        let tagList = phoneTags(tags)
                        Task {
                            let ok = if isNote {
                                await model.addNote(title: noteTitle, text: noteBody, tags: tagList, folderID: folderID)
                            } else {
                                await model.addURL(url.trimmingCharacters(in: .whitespaces), tags: tagList, folderID: folderID)
                            }
                            saving = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(!canSave || saving)
                }
            }
        }
        .presentationDetents([.large])
    }
}

/// First run: what the app does on its own; the Mac is optional.
struct WelcomeView: View {
    let add: () -> Void
    let sync: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Kaydettiklerin, çevrimdışı").font(.title2.weight(.bold))
                Text("Okumak, izlemek, sonra bulmak istediğin her şey tek yerde, telefonunda.")
                    .foregroundStyle(.secondary)
            }
            point("square.and.arrow.up", String(localized: "Her uygulamadan kaydet"), String(localized: "Safari, X, Reddit… Paylaş → wroopmark. Listede yoksa paylaşım satırının sonundaki “Diğer”den ekle."))
            point("arrow.down.doc", String(localized: "İnternetsiz oku"), String(localized: "Metin ve görseller telefona iner; sayfa silinse de arşivde kalır."))
            point("magnifyingglass", String(localized: "Her şeyi bul"), String(localized: "Metinde, notlarında, etiketlerinde ara: tag:okunacak, from:@kişi."))
            point("laptopcomputer.and.iphone", String(localized: "Mac'le birlikte (isteğe bağlı)"), String(localized: "Mac'te wroopmark kullanıyorsan iCloud Drive üzerinden iki yönlü eşitlenir."))
            HStack {
                Button(action: add) { Label("Bağlantı ekle", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                Button("Mac'le eşitle", action: sync)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 24)
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(PhoneTheme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// The first web link in a piece of text (a copied link, or a post's text
/// with one in it).
func firstLink(in text: String) -> String? {
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    let range = NSRange(text.startIndex..., in: text)
    return detector?.matches(in: text, range: range)
        .compactMap(\.url)
        .first { $0.scheme == "http" || $0.scheme == "https" }?
        .absoluteString
}
