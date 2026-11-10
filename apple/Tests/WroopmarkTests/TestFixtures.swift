import Foundation
import Synchronization
@testable import Wroopmark

enum MockResult: Sendable {
    case jsonData(Data)
    case nullResult
    case voidOK
}

final class MockCoreClient: CoreClient, Sendable {
    let libraryURL: URL
    private let commands = Mutex<[CoreCommand]>([])
    private let shouldOpen = Mutex<Bool>(true)
    private let handler: @Sendable (CoreCommand) async throws -> MockResult

    init(
        libraryURL: URL = URL(fileURLWithPath: "/tmp/wroopmark-mock", isDirectory: true),
        openResult: Bool = true,
        handler: @escaping @Sendable (CoreCommand) async throws -> MockResult
    ) {
        self.libraryURL = libraryURL
        self.shouldOpen.withLock { $0 = openResult }
        self.handler = handler
    }

    var recordedCommands: [CoreCommand] {
        commands.withLock { $0 }
    }

    func resetRecordedCommands() {
        commands.withLock { $0.removeAll() }
    }

    func mediaURL(_ name: String) -> URL {
        libraryURL.appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(String(name.prefix(2)), isDirectory: true)
            .appendingPathComponent(name)
    }

    func ensureOpen() async -> Bool {
        shouldOpen.withLock { $0 }
    }

    func call<T: Decodable & Sendable>(_ command: CoreCommand, as type: T.Type, network: Bool) async throws -> T {
        try Task.checkCancellation()
        commands.withLock { $0.append(command) }
        switch try await handler(command) {
        case .jsonData(let data):
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: data)
        case .nullResult, .voidOK:
            throw CoreError.emptyResult
        }
    }

    func callOptional<T: Decodable & Sendable>(_ command: CoreCommand, as type: T.Type, network: Bool) async throws -> T? {
        try Task.checkCancellation()
        commands.withLock { $0.append(command) }
        switch try await handler(command) {
        case .nullResult:
            return nil
        case .jsonData(let data):
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: data)
        case .voidOK:
            throw CoreError.emptyResult
        }
    }

    func run(_ command: CoreCommand, network: Bool) async throws {
        try Task.checkCancellation()
        commands.withLock { $0.append(command) }
        _ = try await handler(command)
    }
}

enum TestFixtures {
    static func makeIsolatedDefaults() -> (defaults: UserDefaults, suite: String) {
        let suite = "com.wroopmark.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        return (defaults, suite)
    }

    static func makeItem(
        id: String,
        title: String? = nil,
        text: String = "Ornek gonderi",
        folderId: Int64? = nil
    ) -> Item {
        Item(
            id: id,
            platform: "x",
            url: "https://x.com/user/status/\(id)",
            authorHandle: "user",
            authorName: "Test User",
            title: title,
            text: text,
            extra: nil,
            ocr: nil,
            createdAt: 1_700_000_000,
            savedAt: 1_700_000_100,
            media: [],
            links: [],
            quote: nil,
            tags: [],
            note: nil,
            folderId: folderId
        )
    }

    static func statsJSON(items: Int = 1, tags: Int = 0, links: Int = 0, videosQueued: Int = 0) -> Data {
        let json = """
        {
          "items": \(items),
          "by_platform": {"x": \(items)},
          "tags": \(tags),
          "links": \(links),
          "media_pending": 0,
          "ocr_pending": 0,
          "media_bytes": 0,
          "videos_missing": 0,
          "videos_queued": \(videosQueued)
        }
        """
        return Data(json.utf8)
    }

    static func emptyLinkCountsJSON(total: Int = 0, dead: Int = 0) -> Data {
        let json = """
        {
          "total": \(total),
          "dead": \(dead),
          "github": \(total),
          "drive": 0,
          "mega": 0,
          "youtube": 0,
          "arxiv": 0,
          "twitter": 0,
          "other": 0
        }
        """
        return Data(json.utf8)
    }

    static func searchResultJSON(itemIDs: [String], total: Int? = nil) -> Data {
        let encodedItems = itemIDs.enumerated().map { idx, id in
            """
            {
              "id": "\(id)",
              "platform": "x",
              "url": "https://x.com/user/status/\(id)",
              "author_handle": "user",
              "author_name": "User",
              "title": "Title \(id)",
              "text": "Body \(id)",
              "saved_at": \(1_700_000_000 + idx),
              "media": [],
              "links": [],
              "tags": []
            }
            """
        }.joined(separator: ",")
        let json = """
        {
          "items": [\(encodedItems)],
          "total": \(total ?? itemIDs.count),
          "links": []
        }
        """
        return Data(json.utf8)
    }

    static func linksPageJSON(
        ids: [Int64],
        total: Int,
        deadTotal: Int = 0,
        githubCount: Int? = nil
    ) -> Data {
        let encodedLinks = ids.map { id in
            """
            {
              "id": \(id),
              "url": "https://github.com/org/repo-\(id)",
              "host": "github.com",
              "title": "Repo \(id)",
              "description": null,
              "image": null,
              "first_seen": \(1_700_000_000 + id),
              "manual": false,
              "item_count": 1,
              "dead": false,
              "status": 200,
              "checked_at": 1700000100
            }
            """
        }.joined(separator: ",")
        let json = """
        {
          "links": [\(encodedLinks)],
          "total": \(total),
          "dead_total": \(deadTotal),
          "counts": {
            "total": \(githubCount ?? total),
            "dead": \(deadTotal),
            "github": \(githubCount ?? total),
            "drive": 0,
            "mega": 0,
            "youtube": 0,
            "arxiv": 0,
            "twitter": 0,
            "other": 0
          }
        }
        """
        return Data(json.utf8)
    }

    static func emptyDownloadsJSON() -> Data {
        Data(#"{"active":[],"queued":[],"completed":[],"failed":[]}"#.utf8)
    }

    static func emptyArrayJSON() -> Data {
        Data("[]".utf8)
    }
}
