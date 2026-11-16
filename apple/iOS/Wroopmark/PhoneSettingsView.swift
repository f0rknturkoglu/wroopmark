import SwiftUI
import UniformTypeIdentifiers

struct PhoneSettingsView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var confirmOffload = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let folder = model.syncFolder {
                        LabeledContent("Klasör", value: folder.lastPathComponent)
                        if let s = model.syncStatus {
                            if s.pending > 0 { LabeledContent("Gönderilmeyi bekleyen", value: "\(s.pending)") }
                            if model.syncWaiting > 0 { LabeledContent("iCloud'dan inen görsel", value: "\(model.syncWaiting)") }
                            ForEach(s.devices) { d in
                                LabeledContent {
                                    if let t = d.lastSync {
                                        Text(Date(timeIntervalSince1970: TimeInterval(t)).formatted(.relative(presentation: .named)))
                                    }
                                } label: {
                                    Label(d.name ?? d.id, systemImage: d.symbol)
                                }
                            }
                        }
                        Button {
                            Task { await model.syncNow() }
                        } label: {
                            HStack {
                                Text("Şimdi eşitle")
                                if model.isSyncing { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(model.isSyncing)
                        Button("Senkronu kapat", role: .destructive) { Task { await model.disableSync() } }
                    } else {
                        Button("Klasörü seç") { picking = true }
                    }
                    if let m = model.syncMessage { Text(m).font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    Text("Senkron")
                } footer: {
                    Text(model.syncFolder == nil
                         ? "Mac'te wroopmark → Ayarlar → Senkron → “iCloud Drive ile başlat” de, sonra burada iCloud Drive içindeki “wroopmark” klasörünü seç. Kayıtlar, etiketler, klasörler ve notlar iki yönlü eşitlenir."
                         : "Uygulamayı her açışında ve aşağı çekince eşitlenir.")
                }

                if model.syncFolder != nil {
                    Section {
                        Toggle("Videoları açınca indir", isOn: Binding(
                            get: { model.syncStatus?.videosOnDemand == true },
                            set: { on in Task { await model.setVideosOnDemand(on) } }
                        ))
                        if let o = model.offloadable, o.files > 0 {
                            Button("Telefondaki \(o.files) videoyu kaldır (\(ByteCountFormatter.string(fromByteCount: o.bytes, countStyle: .file)))", role: .destructive) {
                                confirmOffload = true
                            }
                        }
                    } header: {
                        Text("Videolar")
                    } footer: {
                        Text("Açıkken Mac'ten gelen videolar telefona kopyalanmaz: izlediğinde iCloud'dan iner, iOS yer gerektiğinde onları kendisi siler. Kapatırsan hepsi yeniden telefona iner.")
                    }
                    .task { await model.loadOffloadable() }
                    .confirmationDialog("Videolar telefondan kaldırılsın mı?", isPresented: $confirmOffload, titleVisibility: .visible) {
                        Button("Kaldır", role: .destructive) { Task { await model.offloadVideos() } }
                    } message: {
                        Text("Yalnızca iCloud'da da olan videolar kaldırılır; kayıtlar ve kapaklar kalır. İzlediğinde iCloud'dan yeniden iner.")
                    }
                }

                if let s = model.stats {
                    Section("Kütüphane") {
                        LabeledContent("Kayıt", value: "\(s.items)")
                        LabeledContent("Etiket", value: "\(s.tags)")
                        if let b = s.mediaBytes { LabeledContent("Medya", value: ByteCountFormatter.string(fromByteCount: b, countStyle: .file)) }
                        if let free = model.freeSpace {
                            LabeledContent("Telefonda boş alan", value: ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
                        }
                    }
                }

                Section {
                    if let ai = model.aiStatus {
                        LabeledContent(
                            "Anlam araması",
                            value: ai.embedReady
                                ? ai.vectors.map { "\($0.done) / \($0.total) kayıt" } ?? "Hazır"
                                : (ai.embedError ?? "Hazırlanıyor")
                        )
                        LabeledContent(
                            "Özet ve etiket önerisi",
                            value: ai.llmReady ? "Hazır" : (ai.llm ?? "Kullanılamıyor")
                        )
                    } else {
                        LabeledContent("Cihazdaki zeka", value: "Denetleniyor…")
                    }
                } header: {
                    Text("Zeka")
                } footer: {
                    Text("Arama anlamı ve özetler cihazda çalışır; internete veri gönderilmez.")
                }

                Section("Hakkında") {
                    Link(destination: URL(string: "https://github.com/f0rknturkoglu/wroopmark/blob/main/PRIVACY.md")!) {
                        Label("Gizlilik politikası", systemImage: "hand.raised")
                    }
                    Link(destination: URL(string: "https://github.com/f0rknturkoglu/wroopmark/issues")!) {
                        Label("Destek ve geri bildirim", systemImage: "questionmark.bubble")
                    }
                    LabeledContent("Sürüm", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }

                Section {
                    Text("Safari'de, X'te, her yerde Paylaş → wroopmark. Listede yoksa paylaşım satırının sonundaki “Diğer”den ekle. Bağlantı hemen kaydedilir; metin ve görseller uygulamayı açınca gelir.")
                        .font(.footnote)
                } header: {
                    Text("Telefondan kaydetmek")
                }
            }
            .navigationTitle("Ayarlar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Bitti") { dismiss() } } }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { Task { await model.useSyncFolder(url) } }
            }
            .task {
                await model.loadSyncStatus()
                await model.refreshMeta()
                await model.loadAIStatus()
            }
        }
    }
}
