import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Medya") {
                Toggle("Videoları otomatik indir", isOn: Binding(
                    get: { model.downloadVideos },
                    set: { on in Task { await model.setDownloadVideos(on) } }
                ))
                Text("Görseller ve video kapakları her zaman indirilir. Kapalıyken videolar tek tek, görüntüleyiciden indirilebilir. TikTok videolarını tarayıcı eklentisi, TikTok sayfasının içinden indirir.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Diskte") {
                    Text(ByteCountFormatter.string(fromByteCount: model.stats?.mediaBytes ?? 0, countStyle: .file))
                }
                if let pending = model.stats?.mediaPending, pending > 0 {
                    LabeledContent("Sırada") { Text("\(pending) kayıt") }
                }
                Button("Eksik medyayı şimdi indir") { Task { await model.retryMedia() } }
            }
            Section("Görsellerdeki yazı (OCR)") {
                Toggle("Görsellerdeki yazıyı tanı ve aranabilir yap", isOn: Binding(
                    get: { model.ocrEnabled },
                    set: { model.ocrEnabled = $0 }
                ))
                Text("Açınca tüm kütüphane taranır, sonra yeni kayıtlar okunur. macOS'un kendi metin tanıması kullanılır; her şey cihazda kalır, Türkçe ve İngilizce okunur. Tarama sırasında bellek kullanımı geçici olarak artar.")
                    .font(.caption).foregroundStyle(.secondary)
                if let n = model.stats?.ocrPending, n > 0 {
                    LabeledContent("Sırada") { Text("\(n) kayıt") }
                }
            }
            Section("Kütüphane") {
                LabeledContent("Konum") {
                    Text(Core.shared.libraryURL.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Button("Finder'da göster") { NSWorkspace.shared.open(Core.shared.libraryURL) }
            }
            Section("Tarayıcı eklentisi") {
                LabeledContent("Bağlantı") {
                    Text(HostInstaller.helperURL == nil ? "Uygulama paketinde host yok" : "Chromium tarayıcılarına kayıtlı")
                }
                Text("Eklenti kimliği: \(HostInstaller.extensionID)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshMeta() }
    }
}
