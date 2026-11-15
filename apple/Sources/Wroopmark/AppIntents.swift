import AppIntents
import AppKit
import Foundation

// Shortcuts, Siri and Apple Intelligence: "search wroopmark", "save to
// wroopmark", and a search whose results other shortcuts can use. Nothing
// runs until one is invoked.

struct SearchWroopmarkIntent: AppIntent {
    static let title: LocalizedStringResource = "wroopmark'ta Ara"
    static let description = IntentDescription("Arşivinde arar ve sonuçları wroopmark'ta gösterir.")
    static let openAppWhenRun = true

    @Parameter(title: "Arama", description: "Kelimeler ve süzgeçler, ör. tag:dev from:@jack")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult {
        var c = URLComponents()
        c.scheme = "wroopmark"
        c.host = "search"
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        if let url = c.url { NSWorkspace.shared.open(url) }
        return .result()
    }
}

struct SaveToWroopmarkIntent: AppIntent {
    static let title: LocalizedStringResource = "wroopmark'a Kaydet"
    static let description = IntentDescription("Bir bağlantıyı metni ve görselleriyle arşive kaydeder.")

    @Parameter(title: "Bağlantı")
    var url: URL

    @Parameter(title: "Etiketler", default: [])
    var tags: [String]

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let item: Item = try await Core.shared.call(.addURL(url: url.absoluteString, tags: tags, note: nil, folderID: nil), network: true)
        let title = item.headline.isEmpty ? item.url : String(item.headline.prefix(80))
        return .result(value: item.id, dialog: "Kaydedildi: \(title)")
    }
}

struct FindInWroopmarkIntent: AppIntent {
    static let title: LocalizedStringResource = "wroopmark'ta Bul"
    static let description = IntentDescription("Arşivde arar ve bulunan kayıtların bağlantılarını döndürür (başka kısayollarda kullanmak için).")

    @Parameter(title: "Arama")
    var query: String

    @Parameter(title: "Anlamına göre", default: false)
    var meaning: Bool

    @Parameter(title: "En çok", default: 10, inclusiveRange: (1, 50))
    var limit: Int

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let cmd: CoreCommand = meaning
            ? .call("semantic_search", ["q": .string(query), "limit": .int(Int64(limit))])
            : .search(q: query, sort: "", limit: limit, offset: 0)
        let r: SearchResult = try await Core.shared.call(cmd)
        return .result(value: r.items.map { "\($0.headline.prefix(120)) — \($0.url)" })
    }
}

struct WroopmarkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchWroopmarkIntent(),
            phrases: ["\(.applicationName)'ta ara", "Search \(.applicationName)"],
            shortTitle: "Ara",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: SaveToWroopmarkIntent(),
            phrases: ["\(.applicationName)'a kaydet", "Save to \(.applicationName)"],
            shortTitle: "Kaydet",
            systemImageName: "bookmark"
        )
    }
}
