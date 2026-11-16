import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct PhoneSettingsView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var pickingImport = false
    @State private var pickingPhotos = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
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
                        Button {
                            picking = true
                        } label: {
                            Label("iCloud Drive klasörü seç…", systemImage: "icloud")
                        }
                    }
                    if let m = model.syncMessage { Text(m).font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    Text("iCloud Yedeği ve Senkron")
                } footer: {
                    Text(model.syncFolder == nil
                         ? "iCloud Drive'da bir klasör seç: arşivin (kayıtlar, etiketler, klasörler, notlar, vurgular, görseller ve eklediğin videolar) orada yedeklenir. Telefonun değişirse aynı klasörü seçmen yeter; Mac'te de wroopmark varsa iki cihaz kendiliğinden eşitlenir."
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

                Section("Araçlar ve Dışa Aktarma") {
                    NavigationLink { PhoneGalleryView() } label: { Label("Galeri", systemImage: "photo.on.rectangle") }
                    NavigationLink { PhoneLinksView() } label: { Label("Link Havuzu", systemImage: "link") }
                    NavigationLink { PhoneRulesView() } label: { Label("Kurallar", systemImage: "slider.horizontal.3") }
                    NavigationLink { PhoneDuplicatesView() } label: { Label("Kopyalar", systemImage: "square.on.square") }
                    NavigationLink { PhoneExportSheet() } label: { Label("Dışa Aktar…", systemImage: "square.and.arrow.up") }
                }

                Section {
                    Button {
                        pickingImport = true
                    } label: {
                        HStack {
                            Label("Dosyalardan içe aktar…", systemImage: "square.and.arrow.down")
                            if model.isImporting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(model.isImporting)
                    Button {
                        pickingPhotos = true
                    } label: {
                        Label("Fotoğraflar'dan içe aktar…", systemImage: "photo.on.rectangle.angled")
                    }
                    .disabled(model.isImporting)
                    .photosPicker(isPresented: $pickingPhotos, selection: $pickedPhotos, maxSelectionCount: 50, matching: .any(of: [.videos, .images]))
                    .onChange(of: pickedPhotos) { _, chosen in
                        guard !chosen.isEmpty else { return }
                        pickedPhotos = []
                        Task { await model.importPhotos(chosen) }
                    }
                    if let msg = model.importMessage, !msg.isEmpty {
                        Text(msg).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("İçe aktar")
                } footer: {
                    Text("TikTok, Instagram, Threads, X veya Reddit veri paketi (.zip ya da klasör), tarayıcı bookmarks.html, Pocket/Raindrop CSV, ya da video ve görseller.")
                }
                .fileImporter(isPresented: $pickingImport, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
                    if case .success(let urls) = result { Task { await model.importURLs(urls) } }
                }

                Section {
                    if let ai = model.aiStatus {
                        LabeledContent(
                            "Anlam araması",
                            value: ai.embedReady
                                ? ai.vectors.map { String(localized: "\($0.done) / \($0.total) kayıt") } ?? String(localized: "Hazır")
                                : (ai.embedError ?? String(localized: "Hazırlanıyor"))
                        )
                        LabeledContent(
                            "Özet ve etiket önerisi",
                            value: ai.llmReady ? String(localized: "Hazır") : (ai.llm ?? String(localized: "Kullanılamıyor"))
                        )
                        if let snap = ai.snapshots, snap.done + snap.pending > 0 {
                            LabeledContent("Sayfa kopyaları", value: "\(snap.done) / \(snap.done + snap.pending)")
                        }
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
                    Text("Safari eklentisi: Ayarlar → Uygulamalar → Safari → Genişletmeler → wroopmark. Açtığında Safari'de x.com yer imleri, Bluesky, Threads ve Instagram kaydedilenleri kendiliğinden arşive akar.")
                        .font(.footnote)
                } header: {
                    Text("Telefondan kaydetmek")
                }
            }
            .navigationTitle("Ayarlar")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { ItemView(id: $0) }
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
