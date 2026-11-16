import AppIntents
import Foundation

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

struct SaveToWroopmarkIntent: AppIntent {
    static let title: LocalizedStringResource = "wroopmark'a Kaydet"
    static let description = IntentDescription("Bir bağlantıyı metni ve görselleriyle arşive kaydeder. Paylaşım sayfasından da kullanılabilir.")

    @Parameter(title: "Bağlantı")
    var url: URL

    @Parameter(title: "Etiketler", default: [])
    var tags: [String]

    @Parameter(title: "Klasör")
    var folder: FolderAppEntity?

    @Parameter(title: "Not")
    var note: String?

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        do {
            let item: Item = try await Core.shared.call(.addURL(url: url.absoluteString, tags: tags, note: note, folderID: folder?.folderID), network: true)
            let title = item.headline.isEmpty ? item.url : String(item.headline.prefix(80))
            return .result(value: item.id, dialog: "Kaydedildi: \(title)")
        } catch {
            // Offline: the link is kept, details come when the app opens.
            let id = try await PhoneModel.saveLinkOnly(url.absoluteString, tags: tags, folderID: folder?.folderID)
            if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try? await Core.shared.run(.setNote(id: id, note: note))
            }
            return .result(value: id, dialog: "Bağlantı kaydedildi; ayrıntılar wroopmark açılınca gelecek.")
        }
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
            args["title"] = .string(title)
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
    static let description = IntentDescription("Arşivinden rastgele bir kayıt seçip açar.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        let r: SearchResult = try await Core.shared.call(.search(q: "", sort: "random", limit: 1, offset: 0))
        if let id = r.items.first?.id {
            await MainActor.run {
                PhoneModel.pendingItemID = id
            }
        }
        return .result()
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

    @Parameter(title: "Anlamına göre", default: false)
    var semantic: Bool

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        if semantic { PhoneAI.register() }
        let cmd: CoreCommand = semantic
            ? .call("semantic_search", ["q": .string(query), "sort": .string(""), "limit": .int(Int64(limit)), "offset": .int(0)])
            : .search(q: query, sort: "", limit: limit, offset: 0)
        let r: SearchResult = try await Core.shared.call(cmd, network: semantic)
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
