import Foundation
import Testing
@testable import Wroopmark

/// The core's JSON goes through the real FFI and back into the app's models,
/// so a key that never matches (an item's folder came back empty for months)
/// fails here first.
struct CoreDecodingTests {
    private static func library() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wroopmark-decoding-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func itemFoldersTagsAndHighlightsComeBack() async throws {
        let dir = try Self.library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let core = Core(libraryURL: dir)

        try await core.run(.call("import_items", [
            "tags": .strings(["okuma"]),
            "items": .array([.object([
                "platform": .string("web"),
                "url": .string("https://example.com/decoding"),
                "title": .string("Çözme testi"),
                "text": .string("bir iki üç dört beş"),
                "author_handle": .string("yazar"),
                "created_at": .int(1_700_000_000),
            ])]),
        ]))
        let found: SearchResult = try await core.call(.search(q: "", sort: "", limit: 10, offset: 0))
        let id = try #require(found.items.first?.id)

        let folder: Folder = try await core.call(.call("add_folder", ["name": .string("Ders/Rust")]))
        try await core.run(.moveToFolder(id: id, folderID: folder.id))
        let _: [ReaderHighlight] = try await core.call(.call("highlight", [
            "id": .string(id), "quote": .string("iki üç"), "prefix": .string("bir "), "note": .string("önemli"),
        ]))

        let item: Item = try await core.call(.call("get", ["id": .string(id)]))
        #expect(item.folderId == folder.id)
        #expect(item.tags == ["okuma"])
        #expect(item.authorHandle == "yazar")
        #expect(item.createdAt == 1_700_000_000)
        #expect(item.title == "Çözme testi")

        let folders: [Folder] = try await core.call(.folders)
        #expect(folders.first { $0.id == folder.id }?.createdAt != nil)

        let marks: [ReaderHighlight] = try await core.call(.call("highlights", ["id": .string(id)]))
        #expect(marks.first?.quote == "iki üç")
        #expect(marks.first?.note == "önemli")

        await core.checkpointForQuit()
    }
}
