import AppIntents
import AppKit
import Foundation

// Shortcuts, Siri and Apple Intelligence: "search wroopmark", "save to
// wroopmark", and a search whose results other shortcuts can use. Nothing
// runs until one is invoked.

struct FolderAppEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Klasör"
    static let defaultQuery = FolderAppEntityQuery()

    let id: String
    let name: String

    var folderID: Int64? { Int64(id) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name.replacingOccurrences(of: "/", with: " › "))")
    }
}

struct FolderAppEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [FolderAppEntity] {
        let all: [Folder] = (try? await Core.shared.call(.folders)) ?? []
        let want = Set(identifiers)
        return all.filter { want.contains(String($0.id)) }.map { FolderAppEntity(id: String($0.id), name: $0.name) }
    }

    func suggestedEntities() async throws -> [FolderAppEntity] {
        let all: [Folder] = (try? await Core.shared.call(.folders)) ?? []
        return all.map { FolderAppEntity(id: String($0.id), name: $0.name) }
    }
}

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

    @Parameter(title: "Klasör")
    var folder: FolderAppEntity?

    @Parameter(title: "Not")
    var note: String?

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let item: Item = try await Core.shared.call(
            .addURL(url: url.absoluteString, tags: tags, note: note, folderID: folder?.folderID),
            network: true
        )
        let title = item.headline.isEmpty ? item.url : String(item.headline.prefix(80))
        return .result(value: item.id, dialog: "Kaydedildi: \(title)")
    }
}

struct SaveNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "wroopmark'a Not Ekle"
    static let description = IntentDescription("Bağlantı gerektirmeden hızlı bir metin veya not kartı kaydeder.")

    @Parameter(title: "Başlık")
    var title: String?

    @Parameter(title: "Metin")
    var text: String

    @Parameter(title: "Etiketler", default: [])
    var tags: [String]

    @Parameter(title: "Klasör")
    var folder: FolderAppEntity?

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        var args: [String: CoreArg] = [
            "text": .string(text),
            "tags": .strings(tags),
        ]
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args["title"] = .string(title.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let fid = folder?.folderID {
            args["folder_id"] = .int(fid)
        }
        let item: Item = try await Core.shared.call(.call("add_note", args))
        return .result(value: item.id, dialog: "Not kaydedildi.")
    }
}

struct OpenRandomItemIntent: AppIntent {
    static let title: LocalizedStringResource = "wroopmark'tan Rastgele Kayıt Aç"
    static let description = IntentDescription("Arşivinden rastgele bir kayıt seçip gösterir.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        let r: SearchResult = try await Core.shared.call(.search(q: "", sort: "random", limit: 1, offset: 0))
        if let id = r.items.first?.id,
           let url = URL(string: "wroopmark://item/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)") {
            await MainActor.run {
                _ = NSWorkspace.shared.open(url)
            }
        }
        return .result()
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
        AppShortcut(
            intent: SaveNoteIntent(),
            phrases: ["\(.applicationName)'a not ekle", "Add note to \(.applicationName)"],
            shortTitle: "Not Ekle",
            systemImageName: "note.text"
        )
        AppShortcut(
            intent: OpenRandomItemIntent(),
            phrases: ["\(.applicationName)'tan rastgele aç", "Random from \(.applicationName)"],
            shortTitle: "Rastgele Aç",
            systemImageName: "sparkles"
        )
    }
}
