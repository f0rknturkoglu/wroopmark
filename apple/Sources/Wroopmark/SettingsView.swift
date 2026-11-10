import SafariServices
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case appearance = "appearance"
    case media = "media"
    case ocr = "ocr"
    case library = "library"
    case backup = "backup"
    case quick = "quick"
    case extensionHost = "extension"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appearance: "Görünüm"
        case .media: "Medya"
        case .ocr: "Yazı Tanıma"
        case .library: "Kütüphane"
        case .backup: "Yedek"
        case .quick: "Hızlı Kayıt"
        case .extensionHost: "Eklenti"
        }
    }

    var icon: String {
        switch self {
        case .appearance: "rectangle.grid.2x2.fill"
        case .media: "play.rectangle.fill"
        case .ocr: "text.viewfinder"
        case .library: "internaldrive.fill"
        case .backup: "externaldrive.fill.badge.timemachine"
        case .quick: "bolt.fill"
        case .extensionHost: "puzzlepiece.extension.fill"
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var activeTab: SettingsTab = .appearance
    @AppStorage("menuBarIcon") private var menuBarIcon = true
    @State private var hotKeyOn = QuickSave.shared.hotKeyEnabled
    @State private var extensionStatus = ExtensionStatus.empty
    @State private var extensionError: String?
    @State private var backupFolderExists = false

    var body: some View {
        TabView(selection: $activeTab) {
            Tab(SettingsTab.appearance.label, systemImage: SettingsTab.appearance.icon, value: .appearance) {
                appearanceSection
            }
            Tab(SettingsTab.media.label, systemImage: SettingsTab.media.icon, value: .media) {
                mediaSection
            }
            Tab(SettingsTab.ocr.label, systemImage: SettingsTab.ocr.icon, value: .ocr) {
                ocrSection
            }
            Tab(SettingsTab.library.label, systemImage: SettingsTab.library.icon, value: .library) {
                librarySection
            }
            Tab(SettingsTab.backup.label, systemImage: SettingsTab.backup.icon, value: .backup) {
                backupSection
            }
            Tab(SettingsTab.quick.label, systemImage: SettingsTab.quick.icon, value: .quick) {
                quickSection
            }
            Tab(SettingsTab.extensionHost.label, systemImage: SettingsTab.extensionHost.icon, value: .extensionHost) {
                extensionSection
            }
        }
        .frame(minWidth: 640, idealWidth: 680, minHeight: 500, idealHeight: 540)
        .task {
            async let meta: Void = model.refreshMeta()
            async let tools: Void = model.loadVideoTools()
            async let ext = HostInstaller.status()
            _ = await (meta, tools)
            extensionStatus = await ext
        }
        .task(id: model.backupTarget?.path) {
            if let target = model.backupTarget {
                backupFolderExists = await HostInstaller.fileExists(atPath: target.path)
            } else {
                backupFolderExists = false
            }
        }
    }

    // MARK: - 1. Görünüm

    private var appearanceSection: some View {
        @Bindable var model = model
        return Form {
            Section {
                Picker("Varsayılan düzen", selection: $model.layout) {
                    Label("Kart Izgarası", systemImage: "square.grid.2x2").tag(LibraryLayout.grid)
                    Label("Detaylı Liste", systemImage: "list.bullet").tag(LibraryLayout.list)
                    Label("Geniş Akış", systemImage: "rectangle.grid.1x2").tag(LibraryLayout.feed)
                }
                .pickerStyle(.segmented)
            } header: {
                Label("Kütüphane Görünümü", systemImage: "rectangle.grid.2x2")
            } footer: {
                Text("Görünüm sistem ayarını izler; uygulama ayrı bir tema tutmaz.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 2. Medya

    private var mediaSection: some View {
        @Bindable var model = model
        return Form {
            Section {
                Toggle(isOn: $model.downloadVideos) {
                    Label("Videoları otomatik indir", systemImage: "arrow.down.circle")
                }
                .onChange(of: model.downloadVideos) { _, on in
                    Task { await model.setDownloadVideos(on) }
                }
            } footer: {
                Text("Görseller ve video kapakları her zaman indirilir. Kapalıyken videolar tek tek detay ekranından veya görüntüleyiciden indirilebilir.")
                    .foregroundStyle(.secondary)
            }

            Section("Durum") {
                LabeledContent("Diskteki medya") {
                    Text(ByteCountFormatter.string(fromByteCount: model.stats?.mediaBytes ?? 0, countStyle: .file))
                        .monospacedDigit()
                }
                if let pending = model.stats?.mediaPending, pending > 0 {
                    LabeledContent("İndirilmeyi bekleyen") {
                        Text("\(pending) kayıt").monospacedDigit()
                    }
                }
                LabeledContent("Harici video indirici") {
                    if model.videoTools.isEmpty {
                        Label("Kurulu değil", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else {
                        Label(model.videoTools.map(\.name).joined(separator: " → "), systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                }
            }

            Section {
                Button {
                    Task { await model.retryMedia() }
                } label: {
                    Label("Eksik medyaları şimdi tara ve indir", systemImage: "arrow.clockwise")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 3. OCR

    private var ocrSection: some View {
        @Bindable var model = model
        return Form {
            Section {
                Toggle(isOn: $model.ocrEnabled) {
                    Label("Görsellerdeki yazıyı tanı ve aranabilir yap", systemImage: "text.viewfinder")
                }
            } footer: {
                Text("macOS'un yerel Apple Vision altyapısı kullanılır. Tüm işlemler çevrimdışı ve cihazınızda gerçekleşir; Türkçe ve İngilizce metinleri tanır.")
                    .foregroundStyle(.secondary)
            }

            Section("Durum") {
                LabeledContent("Tanıma") {
                    Label(model.ocrEnabled ? "Etkin" : "Kapalı",
                          systemImage: model.ocrEnabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.ocrEnabled ? .green : .secondary)
                }
                if let n = model.stats?.ocrPending, n > 0 {
                    LabeledContent("Okunmayı bekleyen") {
                        Text("\(n) kayıt").monospacedDigit()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 4. Kütüphane

    private var librarySection: some View {
        Form {
            Section {
                LabeledContent("Konum") {
                    Text(Core.shared.libraryURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Button {
                    NSWorkspace.shared.open(Core.shared.libraryURL)
                } label: {
                    Label("Finder'da Göster", systemImage: "folder")
                }
            } header: {
                Label("Veritabanı ve Medya", systemImage: "internaldrive")
            }

            Section("İstatistik") {
                if let s = model.stats {
                    LabeledContent("Toplam kayıt") {
                        Text("\(s.items)").monospacedDigit()
                    }
                    LabeledContent("Etiketler") {
                        Text("\(s.tags)").monospacedDigit()
                    }
                    LabeledContent("Link havuzu") {
                        Text("\(s.links)").monospacedDigit()
                    }
                } else {
                    Label("İstatistikler yükleniyor…", systemImage: "chart.bar")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 5. Yedek

    private var backupSection: some View {
        @Bindable var model = model
        return Form {
            Section {
                LabeledContent("Hedef") {
                    Text(model.backupTarget?.path ?? "Klasör seçilmedi")
                        .font(.caption.monospaced())
                        .foregroundStyle(model.backupFolder == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack(spacing: Theme.Spacing.sm) {
                    Button { model.chooseBackupFolder() } label: {
                        Label("Klasör Seç…", systemImage: "folder")
                    }
                    if let target = model.backupTarget, backupFolderExists {
                        Button { NSWorkspace.shared.open(target) } label: {
                            Label("Finder'da göster", systemImage: "arrow.up.forward.square")
                        }
                        .help("Finder'da göster")
                    }
                }
                Toggle(isOn: $model.autoBackup) {
                    Label("Her gün otomatik yedekle", systemImage: "clock.arrow.circlepath")
                }
                .disabled(model.backupFolder == nil)
            } header: {
                Label("Yedek", systemImage: "externaldrive.badge.timemachine")
            } footer: {
                Text("Veritabanı, tüm medya ve her programın okuyabileceği bir dışa aktarım (items.jsonl) kopyalanır. İlk yedek her şeyi, sonrakiler yalnızca yenileri taşır.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: Theme.Spacing.md) {
                    Button {
                        Task { await model.runBackup() }
                    } label: {
                        Label(model.isBackingUp ? "Yedekleniyor…" : "Şimdi yedekle", systemImage: "externaldrive.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.backupFolder == nil || model.isBackingUp)
                    if model.isBackingUp { ProgressView().controlSize(.small) }
                    Spacer()
                    if let last = model.lastBackupAt {
                        Text("Son yedek: \(last.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                if let err = model.backupError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let r = model.lastBackupReport {
                    Label(
                        "\(r.items) kayıt · \(r.filesTotal) medya dosyası (\(r.filesCopied) yeni, \(ByteCountFormatter.string(fromByteCount: r.bytesCopied, countStyle: .file)) kopyalandı)",
                        systemImage: "checkmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }

            Section {
                Text("Geri yüklemek için: uygulamayı kapat, yedekteki library.sqlite ile media klasörünü kütüphane klasörüne kopyala (Kütüphane sekmesindeki konum).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 6. Hızlı Kayıt

    private var quickSection: some View {
        @Bindable var model = model
        return Form {
            Section {
                Toggle(isOn: $menuBarIcon) {
                    Label("Menü çubuğunda göster", systemImage: "menubar.rectangle")
                }
                Toggle(isOn: Binding(
                    get: { hotKeyOn },
                    set: { on in
                        hotKeyOn = on
                        QuickSave.shared.setHotKey(on)
                    }
                )) {
                    Label("\(QuickSave.hotKeyLabel) ile panodaki linki kaydet", systemImage: "keyboard")
                }
                Toggle(isOn: $model.spotlightEnabled) {
                    Label("Kayıtları Spotlight'ta göster", systemImage: "magnifyingglass")
                }
            } header: {
                Label("Hızlı Kayıt", systemImage: "bolt")
            } footer: {
                Text("Kısayol her uygulamada çalışır: bir bağlantı kopyala, kısayola bas. Spotlight'ta metin, yazar, etiketler ve görsellerdeki yazı aranır; hiçbir şey cihazdan çıkmaz.")
                    .foregroundStyle(.secondary)
            }

            Section("Bağlantılar") {
                Text("wroopmark://item/<id> · wroopmark://search?q=… · wroopmark://add?url=…")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 7. Eklenti

    private var extensionSection: some View {
        Form {
            Section {
                LabeledContent("Chromium (Chrome, Brave, Arc, Edge…)") {
                    Label(
                        extensionStatus.helperAvailable ? "Bağlantı hazır" : "Yardımcı bulunamadı",
                        systemImage: extensionStatus.helperAvailable ? "checkmark.circle" : "exclamationmark.triangle"
                    )
                    .foregroundStyle(extensionStatus.helperAvailable ? .green : .orange)
                }
                Text("1. Aşağıdan tarayıcını seç: eklentiler sayfası ve eklenti klasörü açılır (yolu panoda).\n2. Sağ üstte Geliştirici modu'nu aç.\n3. \"Paketlenmemiş öğe yükle\" → açılan klasörü seç.\nGüncellemelerden sonra eklentide ↻ yeniden yükle yeterli.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: Theme.Spacing.sm) {
                    let browsers = extensionStatus.installedBrowsers
                    ForEach(browsers) { b in
                        Button {
                            Task {
                                extensionError = await HostInstaller.openExtensionSetup(browser: b.app, page: b.page)
                            }
                        } label: {
                            Label(b.name, systemImage: "safari")
                        }
                    }
                    Button {
                        Task {
                            extensionError = await HostInstaller.openExtensionSetup(browser: nil, page: nil)
                        }
                    } label: {
                        Label(
                            browsers.isEmpty ? "Eklenti klasörünü göster" : "Yalnızca klasör",
                            systemImage: "folder"
                        )
                    }
                }
                if let extensionError {
                    Label(extensionError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Label("Chromium", systemImage: "puzzlepiece.extension")
            }

            Section {
                Button {
                    SFSafariApplication.showPreferencesForExtension(withIdentifier: "com.f0rknturkoglu.wroopmark.safari") { _ in }
                } label: {
                    Label("Safari'de aç", systemImage: "safari")
                }
            } header: {
                Label("Safari", systemImage: "safari")
            } footer: {
                Text("Uygulamanın içinde gelir. İmzasız kurulumda önce Safari → Ayarlar → Geliştirici → \"İmzasız eklentilere izin ver\" gerekir (Safari her açılışta sıfırlar).")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Eklenti kimliği") {
                    Text(HostInstaller.extensionID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                Button {
                    Task {
                        await HostInstaller.registerIfNeeded()
                        extensionStatus = await HostInstaller.status()
                    }
                } label: {
                    Label("Bağlantıyı yenile", systemImage: "arrow.clockwise")
                }
                .help("Tarayıcıların wroopmark'ı bulması için gereken kaydı yeniden yazar")
            }
        }
        .formStyle(.grouped)
    }
}
