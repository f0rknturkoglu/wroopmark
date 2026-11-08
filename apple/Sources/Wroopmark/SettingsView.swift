import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case appearance = "appearance"
    case media = "media"
    case ocr = "ocr"
    case library = "library"
    case extensionHost = "extension"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appearance: "Görünüm"
        case .media: "Medya"
        case .ocr: "Yazı Tanıma"
        case .library: "Kütüphane"
        case .extensionHost: "Eklenti"
        }
    }

    var icon: String {
        switch self {
        case .appearance: "paintbrush.fill"
        case .media: "play.rectangle.fill"
        case .ocr: "text.viewfinder"
        case .library: "internaldrive.fill"
        case .extensionHost: "puzzlepiece.extension.fill"
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var activeTab: SettingsTab = .appearance

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // Modern iOS / macOS Style Top Segmented Icon Bar
            HStack(spacing: 6) {
                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            activeTab = tab
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 17, weight: activeTab == tab ? .semibold : .regular))
                            Text(tab.label)
                                .font(.system(size: 11, weight: activeTab == tab ? .semibold : .medium))
                        }
                        .foregroundStyle(activeTab == tab ? Theme.accent : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            activeTab == tab ? Color.primary.opacity(0.07) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            Divider()

            // Tab Content Pane (clean fixed-size cards, no vertical scrolling)
            VStack(alignment: .leading, spacing: 16) {
                switch activeTab {
                case .appearance:
                    appearanceSection
                case .media:
                    mediaSection
                case .ocr:
                    ocrSection
                case .library:
                    librarySection
                case .extensionHost:
                    extensionSection
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 560, height: 420)
        .task {
            await model.refreshMeta()
            await model.loadVideoTools()
        }
    }

    // MARK: - 1. Görünüm (Theme & Appearance)

    private var appearanceSection: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tema Seçimi")
                    .font(.headline)
                Text("Uygulamanın açık, koyu veya sistem temasına göre görünmesini sağlar.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                ForEach(AppTheme.allCases) { th in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            model.theme = th
                        }
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: th.iconName)
                                .font(.system(size: 24))
                                .foregroundStyle(model.theme == th ? Theme.accent : .secondary)
                            Text(th.label)
                                .font(.system(size: 12, weight: model.theme == th ? .semibold : .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(model.theme == th ? Theme.accent.opacity(0.12) : Color.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(model.theme == th ? Theme.accent : Theme.hairline, lineWidth: model.theme == th ? 1.5 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("Varsayılan Düzen")
                    .font(.subheadline.weight(.semibold))
                Picker("", selection: $model.layout) {
                    Text("Kart Izgarası (Grid)").tag(LibraryLayout.grid)
                    Text("Detaylı Liste (List)").tag(LibraryLayout.list)
                    Text("Geniş Akış (Feed)").tag(LibraryLayout.feed)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    // MARK: - 2. Medya

    private var mediaSection: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 14) {
            Toggle("Videoları otomatik indir", isOn: $model.downloadVideos)
                .onChange(of: model.downloadVideos) { _, on in
                    Task { await model.setDownloadVideos(on) }
                }

            Text("Görseller ve video kapakları her zaman indirilir. Kapalıyken videolar tek tek detay ekranından veya görüntüleyiciden indirilebilir.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            HStack {
                Text("Diskteki medya boyutu:")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: model.stats?.mediaBytes ?? 0, countStyle: .file))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
            }

            if let pending = model.stats?.mediaPending, pending > 0 {
                HStack {
                    Text("İndirilmeyi bekleyen:")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(pending) kayıt")
                        .monospacedDigit()
                }
            }

            HStack {
                Text("Harici video indirici:")
                    .foregroundStyle(.secondary)
                Spacer()
                if model.videoTools.isEmpty {
                    Text("Kurulu değil").foregroundStyle(.orange)
                } else {
                    Text(model.videoTools.map(\.name).joined(separator: " → "))
                        .foregroundStyle(.green)
                }
            }

            Button("Eksik medyaları şimdi tara ve indir") {
                Task { await model.retryMedia() }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    // MARK: - 3. OCR (Yazı Tanıma)

    private var ocrSection: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 14) {
            Toggle("Görsellerdeki yazıyı tanı ve aranabilir yap", isOn: $model.ocrEnabled)

            Text("macOS'un yerel Apple Vision altyapısı kullanılır. Tüm işlemler çevrimdışı ve cihazınızda gerçekleşir; Türkçe ve İngilizce metinleri tanır.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            HStack {
                Text("Durum:")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.ocrEnabled ? "Etkin" : "Kapalı")
                    .foregroundStyle(model.ocrEnabled ? .green : .secondary)
            }

            if let n = model.stats?.ocrPending, n > 0 {
                HStack {
                    Text("Okunmayı bekleyen:")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(n) kayıt")
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - 4. Kütüphane

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Veritabanı ve Medya Konumu")
                    .font(.subheadline.weight(.semibold))
                Text(Core.shared.libraryURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            Button {
                NSWorkspace.shared.open(Core.shared.libraryURL)
            } label: {
                Label("Finder'da Göster", systemImage: "folder")
            }
            .buttonStyle(.bordered)

            Divider()

            if let s = model.stats {
                HStack(spacing: 20) {
                    statBox(title: "Toplam Kayıt", value: "\(s.items)")
                    statBox(title: "Etiketler", value: "\(s.tags)")
                    statBox(title: "Link Havuzu", value: "\(s.links)")
                }
            }
        }
    }

    private func statBox(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.bold)).monospacedDigit()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - 5. Eklenti & Host

    private var extensionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Tarayıcı Entegrasyonu:")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(HostInstaller.helperURL == nil ? "Host bulunamadı" : "Chromium & Safari Aktif")
                    .foregroundStyle(HostInstaller.helperURL == nil ? .orange : .green)
                    .font(.subheadline.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Eklenti Kimliği:")
                    .font(.caption).foregroundStyle(.secondary)
                Text(HostInstaller.extensionID)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }

            Divider()

            Text("Chrome, Brave, Edge veya Arc tarayıcınızda Wroopmark eklentisini açarak sayfaları, X yer imlerini ve linkleri arşivinize aktarabilirsiniz.")
                .font(.caption).foregroundStyle(.secondary)

            Button("Eklenti Bağlantısını Yeniden Kaydet") {
                Task { await HostInstaller.registerIfNeeded() }
            }
            .buttonStyle(.bordered)
        }
    }
}
