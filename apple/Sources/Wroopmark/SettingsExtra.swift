import AppKit
import SwiftUI

// Settings tabs added in v0.2 / v0.3: rules, on-device intelligence,
// import / export, and agents (MCP).

// MARK: - Rules

struct RulesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var tag = ""
    @State private var folderID: Int64?
    @State private var applyNow = true
    @State private var matches: Int?

    private var canAdd: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
            && (!tag.trimmingCharacters(in: .whitespaces).isEmpty || folderID != nil)
    }

    var body: some View {
        Form {
            Section {
                TextField("Arama", text: $query, prompt: Text("site:github.com  ya da  from:@karpathy  ya da  \"yapay zeka\""))
                    .font(.body.monospaced())
                if let matches {
                    Text("Şu an \(matches) kayıt bu aramaya uyuyor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("Etiket ekle", text: $tag, prompt: Text("dev/github"))
                Picker("Klasöre koy", selection: $folderID) {
                    Text("Klasör yok").tag(Int64?.none)
                    ForEach(FolderNode.flattened(model.folderTree)) { node in
                        if let f = node.folder { Text(node.displayPath).tag(Int64?.some(f.id)) }
                    }
                }
                Toggle("Mevcut kayıtlara da uygula", isOn: $applyNow)
                HStack {
                    Spacer()
                    Button("Kural ekle") {
                        let (q, t, f, a) = (query, tag, folderID, applyNow)
                        Task {
                            if await model.addRule(query: q, tag: t.isEmpty ? nil : t, folderID: f, apply: a) {
                                query = ""
                                tag = ""
                                folderID = nil
                                matches = nil
                            }
                        }
                    }
                    .disabled(!canAdd)
                    .keyboardShortcut(.defaultAction)
                }
                if let e = model.rulesError {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Yeni kural")
            } footer: {
                Text("Yeni kaydedilen her şey kurallardan geçer: aramaya uyan kayda etiket eklenir, klasörü yoksa klasöre konur. Arama kutusundaki her terim kullanılabilir (site:, from:, platform:, has:video, kelimeler…).")
                    .foregroundStyle(.secondary)
            }

            Section("Kurallar") {
                if model.rules.isEmpty {
                    Text("Henüz kural yok.").foregroundStyle(.secondary)
                }
                ForEach(model.rules) { rule in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                        Toggle("", isOn: Binding(get: { rule.enabled }, set: { on in Task { await model.setRule(rule, enabled: on) } }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.query).font(.callout.monospaced())
                            HStack(spacing: Theme.Spacing.sm) {
                                if let t = rule.tag { Label("#\(t)", systemImage: "tag").foregroundStyle(Theme.accent) }
                                if let f = rule.folderName { Label(f, systemImage: "folder") }
                                Text("\(rule.matches) eşleşme").foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                        Spacer()
                        Button("Uygula") { Task { await model.applyRule(rule) } }
                            .controlSize(.small)
                            .help("Bu kuralı arşivdeki tüm kayıtlara şimdi uygula")
                        Button(role: .destructive) {
                            Task { await model.deleteRule(rule) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Kuralı sil")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.loadRules() }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            matches = await model.ruleMatches(query)
        }
    }
}

// MARK: - Intelligence

struct IntelligenceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let s = model.aiStatus
        Form {
            Section {
                Toggle(isOn: $model.semanticSearch) {
                    Label("Anlamına göre ara", systemImage: "sparkle.magnifyingglass")
                }
                Toggle(isOn: $model.aiIndexing) {
                    Label("Arka planda anlam dizini oluştur", systemImage: "square.stack.3d.up")
                }
                if let v = s?.vectors {
                    LabeledContent("Dizin") {
                        HStack {
                            if v.total > 0 { ProgressView(value: Double(v.done), total: Double(v.total)).frame(width: 140) }
                            Text("\(v.done) / \(v.total)").monospacedDigit()
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Dizini yeniden oluştur") { Task { await model.rebuildVectors() } }
                        .controlSize(.small)
                }
            } header: {
                Text("Anlamsal arama")
            } footer: {
                Text("Arama kutusundaki ✦ düğmesiyle açılır. Yazdığın kelimelerin yanına cihazdaki dil modeli eş anlamlıları ve diğer dildeki karşılıkları ekler; ayrıca her kaydın anlam vektörüne bakılır. Dizin kayıt başına ~0,5 KB, modeller yalnızca iş varken ayrı bir süreçte çalışır.")
                    .foregroundStyle(.secondary)
            }

            Section("Bu Mac'teki modeller") {
                status("Anlam vektörleri (NaturalLanguage)", ok: s?.embedReady == true, detail: s?.embedReady == true ? "hazır" : (s?.embedError ?? s?.error ?? "denetleniyor…"))
                status("Dil modeli (Apple Intelligence)", ok: s?.llmReady == true, detail: s?.llmReady == true ? "hazır" : (s?.llm ?? "denetleniyor…"))
                if let st = s?.stubs, st.pending + st.failed > 0 {
                    LabeledContent("İçe aktarılan linkler") {
                        Text("\(st.pending) bekliyor" + (st.failed > 0 ? ", \(st.failed) getirilemedi" : ""))
                    }
                }
                HStack {
                    Spacer()
                    Button("Yenile") { Task { await model.loadAIStatus() } }.controlSize(.small)
                }
            }

            Section {
                Text("Detay panelinde “Özetle ve etiket öner”, ayıklama ekranında her kart kendiliğinden özetlenir. Önerilen etiketler tek tıkla eklenir; hiçbir şey otomatik etiketlenmez. Hepsi cihazda, internete bir şey gitmez.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Özet ve etiket önerisi")
            }

            Section {
                Button("Kopyaları bul…") { model.showDuplicates = true }
            } header: {
                Text("Temizlik")
            } footer: {
                Text("Aynı görseli/videoyu ya da aynı metni taşıyan, ya da anlamca neredeyse aynı olan kayıtlar.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await model.loadAIStatus() }
    }

    private func status(_ title: String, ok: Bool, detail: String) -> some View {
        LabeledContent(title) {
            Label(detail, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? .green : .secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Import / export

struct TransferSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Button("Dosya ya da klasör seç…") { model.chooseImport() }
                    .disabled(model.isTransferring)
                if let s = model.transferStatus {
                    Text(s).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("İçe aktar")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dosyaları pencereye sürükleyip bırakmak da olur.")
                    Text("• Tarayıcı yer imleri: bookmarks.html (klasörler “Yer imleri” altına)")
                    Text("• TikTok / Instagram / X veri paketi (.zip ya da açılmış klasör): favoriler, beğeniler, kaydedilenler; izleme geçmişi alınmaz")
                    Text("• Pocket, Raindrop ve benzeri CSV dışa aktarımları")
                    Text("• Video ve görseller: eski indirdiğin TikTok videoları dosya adındaki numarayla gönderisine bağlanır")
                }
                .foregroundStyle(.secondary)
            }

            Section {
                ForEach(AppModel.ExportFormat.allCases) { f in
                    Button("\(f.label)…") { model.chooseExport(f) }
                        .disabled(model.isTransferring)
                }
            } header: {
                Text("Dışa aktar")
            } footer: {
                Text("Şu an ekranda olan görünüm ve arama aktarılır (her şey için kenar çubuğunda Tümü'nü seç). Markdown her kaydı ayrı not yapar, görseller yanına kopyalanır; Obsidian kasasına doğrudan konabilir.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Agents (MCP)

struct AgentsSettings: View {
    @State private var copied: String?

    private var cli: String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/wroopmark").path
        return FileManager.default.isExecutableFile(atPath: bundled) ? bundled : "/Applications/wroopmark.app/Contents/Helpers/wroopmark"
    }

    private var claudeCode: String { "claude mcp add wroopmark -- \"\(cli)\" mcp" }

    private var desktopJSON: String {
        """
        {
          "mcpServers": {
            "wroopmark": {
              "command": "\(cli)",
              "args": ["mcp"]
            }
          }
        }
        """
    }

    var body: some View {
        Form {
            Section {
                Text("Claude, Cursor gibi ajanlar arşivinde arama yapabilir, kaydı okuyabilir (görsellerin dosya yolları dahil), link kaydedip etiketleyebilir. Sunucu yalnızca ajan bağlanınca çalışır ve ajanla birlikte kapanır; uygulamanın açık olması gerekmez.")
                    .foregroundStyle(.secondary)
            }
            Section("Claude Code") {
                snippet(claudeCode, key: "code")
            }
            Section("Claude Desktop, Cursor ve diğerleri") {
                snippet(desktopJSON, key: "json")
                Text("Claude Desktop: Ayarlar → Geliştirici → Yapılandırmayı düzenle. Yalnızca okuma izni için \"args\": [\"mcp\", \"--read-only\"].")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Araçlar") {
                Text("search (filtreler ve anlamsal arama) · get_item · related · search_links · list_tags · list_folders · stats · save_url · tag_items · move_to_folder · set_note")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private func snippet(_ text: String, key: String) -> some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied == key ? "Kopyalandı" : "Kopyala") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = key
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Sync

struct SyncSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.syncStatus
        Form {
            if s?.enabled == true {
                Section {
                    LabeledContent("Klasör") {
                        Text(s?.dir ?? "").font(.callout).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    }
                    LabeledContent("Bu cihaz", value: s?.name ?? s?.device ?? "")
                    if let p = s?.pending, p > 0 { LabeledContent("Gönderilmeyi bekleyen", value: "\(p) kayıt") }
                    HStack {
                        if model.isSyncing { ProgressView().controlSize(.small) }
                        if let m = model.syncMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Şimdi eşitle") { Task { await model.syncNow(quiet: false); await model.loadSyncStatus() } }
                            .disabled(model.isSyncing)
                    }
                } header: {
                    Text("Senkron açık")
                }
                Section("Cihazlar") {
                    ForEach(s?.devices ?? []) { d in
                        LabeledContent {
                            if let t = d.lastSync {
                                Text(Date(timeIntervalSince1970: TimeInterval(t)).formatted(.relative(presentation: .named)))
                                    .foregroundStyle(.secondary)
                            }
                        } label: {
                            Label(d.name ?? d.id, systemImage: d.id == s?.device ? "laptopcomputer" : "iphone")
                        }
                    }
                }
                Section {
                    Picker("Medya", selection: Binding(get: { s?.media ?? "images" }, set: { m in Task { await model.setSyncMedia(m) } })) {
                        Text("Görseller (önerilen)").tag("images")
                        Text("Görseller ve videolar").tag("all")
                        Text("Yalnızca metin").tag("none")
                    }
                } footer: {
                    Text("Görseller klasöre kopyalanır, öbür cihaz hemen gösterir. Videolar her cihazda kendi iner; “Görseller ve videolar” iCloud'da birkaç GB tutabilir.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("Senkronu kapat", role: .destructive) { Task { await model.disableSync() } }
                } footer: {
                    Text("Bu cihazın kütüphanesi ve klasördeki dosyalar yerinde kalır.").foregroundStyle(.secondary)
                }
            } else {
                Section {
                    if let icloud = AppModel.iCloudFolder {
                        Button {
                            Task { await model.enableSync(at: icloud) }
                        } label: {
                            Label("iCloud Drive ile başlat", systemImage: "icloud")
                        }
                        .disabled(model.isSyncing)
                    }
                    Button("Başka bir klasör seç…") { model.chooseSyncFolder() }
                        .disabled(model.isSyncing)
                    if model.isSyncing {
                        HStack { ProgressView().controlSize(.small); Text("İlk eşitleme: kütüphane klasöre yazılıyor…").font(.caption) }
                    }
                    if let m = model.syncMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
                } header: {
                    Text("Cihazlar arası senkron")
                } footer: {
                    Text("Kayıtlar, etiketler, klasörler, notlar ve kayıtlı aramalar seçtiğin klasör üzerinden diğer cihazlara (iPhone, başka Mac) gider. Veritabanı klasöre konmaz; her cihaz yalnızca kendi değişikliklerini ekler, aynı şeyi iki yerde değiştirirsen son yapılan geçerli olur. Sunucu yok, hesap yok.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.loadSyncStatus() }
    }
}
