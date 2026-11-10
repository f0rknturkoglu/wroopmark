import Foundation
import Testing
@testable import Wroopmark

struct CoreCommandTests {
    @Test func moveToFolderNilSerializesExplicitNull() throws {
        let data = try JSONEncoder().encode(CoreCommand.moveToFolder(id: "item-1", folderID: nil))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["cmd"] as? String == "move_to_folder")
        #expect(object["id"] as? String == "item-1")
        #expect(object["folder_id"] is NSNull)
    }

    @Test func moveToFolderNonNilSerializesIntegerID() throws {
        let data = try JSONEncoder().encode(CoreCommand.moveToFolder(id: "item-2", folderID: 42))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["cmd"] as? String == "move_to_folder")
        #expect(object["id"] as? String == "item-2")
        #expect(object["folder_id"] as? Int64 == 42)
    }

    @Test func moveItemsToFolderSerializesNullOrIDAndArray() throws {
        let data = try JSONEncoder().encode(CoreCommand.moveItemsToFolder(ids: ["a", "b"], folderID: nil))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["cmd"] as? String == "move_items_to_folder")
        #expect(object["ids"] as? [String] == ["a", "b"])
        #expect(object["folder_id"] is NSNull)
    }

    @Test func addURLOmitsOptionalNilNoteAndFolderID() throws {
        let data = try JSONEncoder().encode(
            CoreCommand.addURL(url: "https://example.com", tags: ["dev"], note: nil, folderID: nil)
        )
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["cmd"] as? String == "add_url")
        #expect(object["url"] as? String == "https://example.com")
        #expect(object["tags"] as? [String] == ["dev"])
        #expect(object.keys.contains("note") == false)
        #expect(object.keys.contains("folder_id") == false)
    }

    @Test func linksPageEncodesFiltersAndPagination() throws {
        let data = try JSONEncoder().encode(
            CoreCommand.linksPage(q: "swift", category: "video", onlyDead: true, limit: 100, offset: 200)
        )
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["cmd"] as? String == "links_page")
        #expect(object["q"] as? String == "swift")
        #expect(object["category"] as? String == "video")
        #expect(object["only_dead"] as? Bool == true)
        #expect(object["limit"] as? Int == 100)
        #expect(object["offset"] as? Int == 200)
    }
}

extension CoreCommandTests {
    @Test func linkItemsEncodesPagination() throws {
        let data = try JSONEncoder().encode(CoreCommand.linkItems(id: 7, limit: 60, offset: 120))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["cmd"] as? String == "link_items")
        #expect(object["id"] as? Int64 == 7)
        #expect(object["limit"] as? Int == 60)
        #expect(object["offset"] as? Int == 120)
    }
}
