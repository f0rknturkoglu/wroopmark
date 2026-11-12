import AppKit
import SafariServices
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "general"
    case appearance = "appearance"
    case library = "library"
    case media = "media"
    case ocr = "ocr"
    case backup = "backup"
    case extensionHost = "extension"
    case about = "about"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: "Genel"
        case .appearance: "Görünüm"
        case .library: "Kütüphane"
        case .media: "Medya"
        case .ocr: "Yazı Tanıma"
        case .backup: "Yedek"
        case .extensionHost: "Eklenti"
        case .about: "Hakkında"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .library: "internaldrive"
        case .media: "play.rectangle"
        case .ocr: "text.viewfinder"
        case .backup: "externaldrive.badge.timemachine"
        case .extensionHost: "puzzlepiece.extension"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("settingsTab") private var activeTab: SettingsTab = .general
    @AppStorage("menuBarIcon") private var menuBarIcon = true
    @State private var hotKeyOn = QuickSave.shared.hotKeyEnabled
    @State private var extensionStatus = ExtensionStatus.empty
    @State private var extensionError: String?
    @State private var backupFolderExists = false

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: tabSelection) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.label, systemImage: tab.icon)
                        .tag(tab)
                }
            }
            .listStyle(.sidebar)
            .tint(Theme.accent)
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            activeSection
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 780, height: 560)
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

    private var tabSelection: Binding<SettingsTab?> {
        Binding(
            get: { activeTab },
            set: { if let value = $0 { activeTab = value } }
        )
    }

    @ViewBuilder
    private var activeSection: some View {
        switch activeTab {
        case .general: generalSection
        case .appearance: appearanceSection
        case .library: librarySection
        case .media: mediaSection
        case .ocr: ocrSection
        case .backup: backupSection
        case .extensionHost: extensionSection
        case .about: aboutSection
        }
    }

    // MARK: - Genel

    private var generalSection: some View {
        @Bindable var model = model
        return Form {
            Section {
                Toggle(isOn: $menuBarIcon) {
                    Label("Menü çubuğunda göster", systemImage: "menubar.rectangle")
                }
            } header: {
                Text("Menü Çubuğu")
            } footer: {
                Text("Kapalıyken uygulama yalnızca Dock ve uygulama menüsünden açılır.")
                    .foregroundStyle(.secondary)
            }

            Section {
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
                Text("Sistem Entegrasyonu")
            } footer: {
                Text("Kısayol her uygulamada çalışır. Spotlight'ta metin, yazar, etiketler ve görsellerdeki yazı aranır; hiçbir şey cihazdan çıkmaz.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("wroopmark://item/<id> · wroopmark://search?q=… · wroopmark://add?url=…")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } header: {
                Text("Bağlantılar")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Görünüm

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
                Text("Kütüphane Görünümü")
            } footer: {
                Text("Görünüm sistem ayarını izler; uygulama ayrı bir tema tutmaz.")
                    .foregroundStyle(.secondary)
            }

            Section {
                AppearancePreview()
            } header: {
                Text("Önizleme")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Kütüphane

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
                Text("Veritabanı ve Medya")
            }

            Section {
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
                    LabeledContent("Diskteki medya") {
                        Text(ByteCountFormatter.string(fromByteCount: s.mediaBytes ?? 0, countStyle: .file))
                            .monospacedDigit()
                    }
                } else {
                    Label("İstatistikler yükleniyor…", systemImage: "chart.bar")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("İstatistik")
            }

            Section {
                Button {
                    Task {
                        await model.reload()
                        await model.refreshMeta()
                    }
                } label: {
                    Label("Kütüphaneyi yenile", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Medya

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

            Section {
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
            } header: {
                Text("Durum")
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

    // MARK: - Yazı Tanıma

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

            Section {
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
            } header: {
                Text("Durum")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Yedek

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
                Text("Yedek")
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

    // MARK: - Eklenti

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
                Text("Chromium")
            }

            Section {
                Button {
                    SFSafariApplication.showPreferencesForExtension(withIdentifier: "com.f0rknturkoglu.wroopmark.safari") { _ in }
                } label: {
                    Label("Safari'de aç", systemImage: "safari")
                }
            } header: {
                Text("Safari")
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

    // MARK: - Hakkında

    private var aboutSection: some View {
        Form {
            Section {
                HStack(spacing: Theme.Spacing.lg) {
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 64, height: 64)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("wroopmark")
                            .font(.title2.weight(.semibold))
                        Text("Sürüm \(appVersion)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text("Kaydettiklerin, çevrimdışı ve aranabilir.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Theme.Spacing.xs)
            }

            Section {
                Link(destination: URL(string: "https://github.com/f0rknturkoglu/wroopmark")!) {
                    Label("GitHub'da aç", systemImage: "arrow.up.forward.square")
                }
                Button {
                    NSWorkspace.shared.open(Core.shared.libraryURL)
                } label: {
                    Label("Kütüphane klasörünü aç", systemImage: "folder")
                }
            } header: {
                Text("Bağlantılar")
            }

            Section {
                LabeledContent("Lisans", value: "MIT")
                LabeledContent("Telif", value: "© 2026 Furkan Türkoğlu")
            } footer: {
                Text("Sunucu, hesap ve bulut yok; arşiv yalnızca bu Mac'te durur.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "geliştirme"
    }
}

/// A miniature library card so the appearance tab shows what the chosen
/// layout actually looks like instead of an empty form.
private struct AppearancePreview: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .fill(Theme.Stroke.subtleFill)
                .frame(width: 88, height: 64)
                .overlay {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                        .strokeBorder(Theme.Stroke.surfaceBorder, lineWidth: Theme.Stroke.hairlineWidth)
                }

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Kütüphane görünümü")
                    .font(.subheadline.weight(.semibold))
                Text("Etiketler, notlar ve medya tek bakışta.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: Theme.Spacing.xs) {
                    Text("#okunacak")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                        .overlay {
                            Capsule()
                                .strokeBorder(Theme.accent.opacity(0.18), lineWidth: Theme.Stroke.hairlineWidth)
                        }
                    CountPill(value: "12")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Stroke.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(Theme.Stroke.surfaceBorder, lineWidth: Theme.Stroke.hairlineWidth)
        }
    }
}
