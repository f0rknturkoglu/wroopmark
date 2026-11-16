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

struct PhoneLibrary: View {
    @Environment(PhoneModel.self) private var model
    @State private var showAdd = false
    @State private var showSettings = false
    @State private var showFeed = false
    @State private var showTriage = false
    @State private var path: [String] = []

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            List {
                LibraryBanners()
                if model.scope == .today && model.query.isEmpty {
                    if !model.onThisDay.isEmpty {
                        Section("Geçmişte bugün") {
                            ForEach(model.onThisDay) { item in
                                NavigationLink(value: item.id) { ItemRowView(item: item) }
                                    .swipeActions {
                                        Button("Sil", role: .destructive) { Task { await model.delete(item.id) } }
                                    }
                            }
                        }
                    }
                    if !model.rediscover.isEmpty {
                        Section("Arşivden bugün için") {
                            ForEach(model.rediscover) { item in
                                NavigationLink(value: item.id) { ItemRowView(item: item) }
                                    .swipeActions {
                                        Button("Sil", role: .destructive) { Task { await model.delete(item.id) } }
                                    }
                            }
                        }
                    }
                } else {
                    ForEach(model.items) { item in
                        NavigationLink(value: item.id) { ItemRowView(item: item) }
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
            .onChange(of: model.query) { _, _ in model.queryChanged() }
            .onChange(of: model.scope) { _, _ in Task { await model.reload() } }
            .onChange(of: model.semanticSearch) { _, _ in Task { await model.reload() } }
            .refreshable {
                await model.syncNow()
                await model.reload()
            }
            .navigationDestination(for: String.self) { id in ItemView(id: id) }
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
                ToolbarItem(placement: .topBarTrailing) { ScopeMenu() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Bağlantı ekle")
                }
            }
            .sheet(isPresented: $showAdd) { AddURLView() }
            .onChange(of: model.openRequest) { _, id in
                if let id {
                    path = [id]
                    model.openRequest = nil
                }
            }
            .sheet(isPresented: $showSettings) { PhoneSettingsView() }
            .fullScreenCover(isPresented: $showFeed) { VideoFeedView(scope: model.scope, query: model.query) }
            .fullScreenCover(isPresented: $showTriage) { PhoneTriageView(scope: model.scope, query: model.query) }
        }
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

    var body: some View {
        @Bindable var model = model
        Menu {
            Picker("Görünüm", selection: $model.scope) {
                Label("Tümü", systemImage: "tray.full").tag(PhoneScope.all)
                Label("Bugün", systemImage: "calendar.day.timeline.left").tag(PhoneScope.today)
                Label("Etiketsiz", systemImage: "tag.slash").tag(PhoneScope.untagged)
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
    @State private var url = ""
    @State private var tags = ""
    @State private var saving = false
    @State private var pickingImport = false

    var body: some View {
        NavigationStack {
            Form {
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
                    }
                    TextField("Etiketler (virgülle)", text: $tags)
                        .textInputAutocapitalization(.never)
                    if saving { HStack { ProgressView(); Text("Sayfa indiriliyor…") } }
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
            .navigationTitle("Bağlantı")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") {
                        saving = true
                        Task {
                            let ok = await model.addURL(url.trimmingCharacters(in: .whitespaces), tags: phoneTags(tags))
                            saving = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(url.isEmpty || saving)
                }
            }
        }
        .presentationDetents([.medium])
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
            point("square.and.arrow.up", "Her uygulamadan kaydet", "Safari, X, Reddit… Paylaş → wroopmark. Listede yoksa paylaşım satırının sonundaki “Diğer”den ekle.")
            point("arrow.down.doc", "İnternetsiz oku", "Metin ve görseller telefona iner; sayfa silinse de arşivde kalır.")
            point("magnifyingglass", "Her şeyi bul", "Metinde, notlarında, etiketlerinde ara: tag:okunacak, from:@kişi.")
            point("laptopcomputer.and.iphone", "Mac'le birlikte (isteğe bağlı)", "Mac'te wroopmark kullanıyorsan iCloud Drive üzerinden iki yönlü eşitlenir.")
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
