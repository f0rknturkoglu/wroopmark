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

    @Test func needsVideoAttachFileAndSnapshotRoundTrip() async throws {
        let dir = try Self.library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let core = Core(libraryURL: dir)

        try await core.run(.call("import_items", [
            "items": .array([
                .object([
                    "platform": .string("tiktok"),
                    "url": .string("https://www.tiktok.com/@a/video/789"),
                    "author_handle": .string("ali"),
                    "text": .string("klip"),
                    "media": .array([.object([
                        "kind": .string("video"),
                        "url": .string("https://v.example/789.mp4"),
                    ])]),
                ]),
                .object([
                    "platform": .string("tiktok"),
                    "url": .string("https://www.tiktok.com/@a/video/790"),
                    "author_handle": .string("ali"),
                    "text": .string("önceki klip"),
                ]),
            ]),
        ]))
        let waiting: [Item] = try await core.call(.call("needs_video", ["limit": .int(10)]))
        #expect(waiting.first?.id == "tiktok:789")

        let mov = dir.appendingPathComponent("clip.mov")
        try Data("ftypqt  ".utf8).write(to: mov)
        let attached: Bool = try await core.call(.call("attach_file", ["id": .string("tiktok:789"), "path": .string(mov.path)]))
        #expect(attached)
        let remaining: [Item] = try await core.call(.call("needs_video", ["limit": .int(10)]))
        #expect(remaining.isEmpty)

        let snap = dir.appendingPathComponent("page.webarchive")
        try Data("bplist00".utf8).write(to: snap)
        let snapName: String = try await core.call(.call("set_snapshot", [
            "id": .string("tiktok:789"),
            "path": .string(snap.path),
            "text": .string("kaydedilen sayfa metni"),
        ]))
        let item: Item = try await core.call(.call("get", ["id": .string("tiktok:789")]))
        #expect(item.media.first?.videoFile?.hasSuffix(".mov") == true)
        #expect(item.snapshot == snapName)

        let folder: Folder = try await core.call(.addFolder(name: "Klipler"))
        try await core.run(.moveToFolder(id: "tiktok:790", folderID: folder.id))
        try await core.run(.setTags(id: "tiktok:790", tags: ["hazir"]))
        let suggestions: [BatchSuggestion] = try await core.call(.call("suggest_batch", ["q": .string(""), "limit": .int(10)]))
        #expect(suggestions.first?.id == "tiktok:789")
        #expect(suggestions.first?.folderId == folder.id)
        #expect(suggestions.first?.folderName == "Klipler")

        await core.checkpointForQuit()
    }
}
