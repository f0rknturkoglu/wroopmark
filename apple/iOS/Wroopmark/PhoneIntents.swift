import AppIntents
import Foundation

struct SaveToWroopmarkIntent: AppIntent {
    static let title: LocalizedStringResource = "wroopmark'a Kaydet"
    static let description = IntentDescription("Bir bağlantıyı metni ve görselleriyle arşive kaydeder. Paylaşım sayfasından da kullanılabilir.")

    @Parameter(title: "Bağlantı")
    var url: URL

    @Parameter(title: "Etiketler", default: [])
    var tags: [String]

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        do {
            let item: Item = try await Core.shared.call(.addURL(url: url.absoluteString, tags: tags, note: nil, folderID: nil), network: true)
            let title = item.headline.isEmpty ? item.url : String(item.headline.prefix(80))
            return .result(value: item.id, dialog: "Kaydedildi: \(title)")
        } catch {
            // Offline: the link is kept, details come when the app opens.
            let id = try await PhoneModel.saveLinkOnly(url.absoluteString, tags: tags)
            return .result(value: id, dialog: "Bağlantı kaydedildi; ayrıntılar wroopmark açılınca gelecek.")
        }
    }
}

struct SearchWroopmarkIntent: AppIntent {
    static let title: LocalizedStringResource = "wroopmark'ta Ara"
    static let description = IntentDescription("Arşivinde arar ve sonuçları gösterir.")
    static let openAppWhenRun = true

    @Parameter(title: "Arama")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult {
        PhoneModel.pendingQuery = query
        return .result()
    }
}

struct FindInWroopmarkIntent: AppIntent {
    static let title: LocalizedStringResource = "wroopmark'ta Bul"
    static let description = IntentDescription("Arşivde arar, bulunan kayıtların bağlantılarını döndürür.")

    @Parameter(title: "Arama")
    var query: String

    @Parameter(title: "En çok", default: 10, inclusiveRange: (1, 50))
    var limit: Int

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let r: SearchResult = try await Core.shared.call(.search(q: query, sort: "", limit: limit, offset: 0))
        return .result(value: r.items.map { "\($0.headline.prefix(120)) — \($0.url)" })
    }
}

struct WroopmarkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SaveToWroopmarkIntent(),
            phrases: ["\(.applicationName)'a kaydet", "Save to \(.applicationName)"],
            shortTitle: "Kaydet",
            systemImageName: "bookmark"
        )
        AppShortcut(
            intent: SearchWroopmarkIntent(),
            phrases: ["\(.applicationName)'ta ara", "Search \(.applicationName)"],
            shortTitle: "Ara",
            systemImageName: "magnifyingglass"
        )
    }
}
