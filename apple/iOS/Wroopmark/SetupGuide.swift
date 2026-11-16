import SwiftUI
import TipKit
import UniformTypeIdentifiers

/// The first-run guide: what the app is, and the three things only the user
/// can switch on (wroopmark in the share sheet, the Safari extension, an
/// iCloud folder for the backup). Shown once; Settings opens it again.
struct SetupGuide: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SetupGuide.seenKey) private var seen = false
    @State private var page = 0
    @State private var pickingFolder = false

    static let seenKey = "setupGuideSeen"
    private let pages = 5

    var body: some View {
        NavigationStack {
            TabView(selection: $page) {
                welcome.tag(0)
                shareSheet.tag(1)
                safari.tag(2)
                backup.tag(3)
                done.tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .safeAreaInset(edge: .bottom) {
                Button {
                    if page < pages - 1 { withAnimation { page += 1 } } else { finish() }
                } label: {
                    Text(page < pages - 1 ? "Devam" : "Başla")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(PhoneTheme.accent)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if page < pages - 1 { Button("Geç") { finish() } }
                }
            }
            .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { Task { await model.useSyncFolder(url) } }
            }
        }
        .interactiveDismissDisabled(page < pages - 1)
    }

    private func finish() {
        seen = true
        dismiss()
        Self.startTips()
    }

    /// Once per launch; a second call is ignored.
    static func startTips() {
        try? Tips.configure([.displayFrequency(.immediate)])
    }

    // MARK: Pages

    private var welcome: some View {
        GuidePage(symbol: "bookmark.fill", title: "wroopmark'a hoş geldin") {
            Text("Gördüğün ve sonra dönmek istediğin her şey (gönderiler, videolar, makaleler) metni ve görselleriyle telefonunda, internetsiz okunur ve aranır.")
            Text("Hesap yok, sunucu yok: arşivin yalnızca senin cihazında ve seçersen senin iCloud Drive'ında.")
        }
    }

    private var shareSheet: some View {
        GuidePage(symbol: "square.and.arrow.up", title: "Her uygulamadan kaydet") {
            Text("Safari'de, X'te, Instagram'da: Paylaş → wroopmark. Bağlantı hemen kaydedilir; metin ve görseller uygulamayı açınca gelir.")
            Text("Listede yoksa satırın sonundaki “Diğer”e dokun ve wroopmark'ı sık kullanılanlara ekle. Kendi kaydettiğin videoları ve fotoğrafları da böyle gönderisine ekleyebilirsin.")
            ShareLink(item: URL(string: "https://f0rknturkoglu.github.io/wroopmark/")!) {
                Label("Paylaşım menüsünü aç ve dene", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
        }
    }

    private var safari: some View {
        GuidePage(symbol: "safari", title: "Yer imlerin kendiliğinden gelsin") {
            Text("Safari eklentisini aç; Safari'de x.com yer imlerini, Bluesky, Threads ya da Instagram kaydedilenlerini gezdikçe gönderiler arşive akar.")
            VStack(alignment: .leading, spacing: 6) {
                step(1, "Ayarlar → Uygulamalar → Safari → Uzantılar")
                step(2, "wroopmark → aç")
                step(3, "İzinlerde bu siteler için “İzin Ver”")
            }
            Link(destination: URL(string: "https://x.com/i/bookmarks")!) {
                Label("Safari'de x.com yer imlerini aç", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.bordered)
        }
    }

    private var backup: some View {
        GuidePage(symbol: "icloud", title: "Arşivin güvende olsun") {
            Text("iCloud Drive'da bir klasör seç: kayıtlar, etiketler, notlar, vurgular, görseller ve eklediğin videolar orada yedeklenir. Telefonun değişirse aynı klasörü seçmen yeter.")
            Text("Mac'te de wroopmark varsa aynı klasörü seç; iki cihaz kendiliğinden eşitlenir.")
            if model.syncFolder != nil {
                Label("iCloud yedeği açık", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button { pickingFolder = true } label: {
                    Label("iCloud Drive klasörü seç…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var done: some View {
        GuidePage(symbol: "checkmark.seal.fill", title: "Hazırsın") {
            Text("Akış: videolarını ve gönderilerini tam ekran kaydır. Ayıkla: kayıtları tek tek geç, sola at sil, sağa at sakla. Oku: makaleyi sade okuyucuda aç, önemli yerleri vurgula.")
            Text("Bu rehber Ayarlar'da durur.")
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.subheadline.weight(.bold)).foregroundStyle(PhoneTheme.accent).frame(width: 18)
            Text(text).font(.subheadline)
        }
    }
}

private struct GuidePage<Content: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: symbol)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(PhoneTheme.accent)
                    .padding(.top, 32)
                Text(title).font(.largeTitle.weight(.bold))
                content
                    .font(.body)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: Tips

/// Small hints where a gesture is not obvious; each shows until used or closed.
struct FeedTip: Tip {
    var title: Text { Text("Akış") }
    var message: Text? { Text("Yukarı kaydırınca sonraki. Alttaki çubuğu sürükleyerek ileri sar; çıkmak için soldaki kenardan sağa kaydır.") }
    var image: Image? { Image(systemName: "play.rectangle.on.rectangle") }
}

struct TriageTip: Tip {
    var title: Text { Text("Ayıkla") }
    var message: Text? { Text("Kayıtlar tek tek gelir: sola at sil, sağa at sakla ya da önerilen klasöre taşı.") }
    var image: Image? { Image(systemName: "rectangle.stack.badge.minus") }
}

struct ReaderTip: Tip {
    var title: Text { Text("Oku ve vurgula") }
    var message: Text? { Text("Sade okuyucuda metni seç, Vurgula'ya dokun; vurgular aramada da çıkar.") }
    var image: Image? { Image(systemName: "highlighter") }
}
