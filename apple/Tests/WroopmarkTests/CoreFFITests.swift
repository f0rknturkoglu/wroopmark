import Foundation
import Testing
@testable import Wroopmark

struct CoreFFITests {
    private static func makeTempLibraryURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wroopmark-core-ffi-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func ensureOpenCoalescesConcurrentCallers() async throws {
        let dir = try Self.makeTempLibraryURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let core = Core(libraryURL: dir)
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask { await core.ensureOpen() }
            }
            var values: [Bool] = []
            for await ok in group { values.append(ok) }
            return values
        }

        #expect(results.count == 8)
        #expect(results.allSatisfy { $0 })

        await core.checkpointForQuit()
        await core.checkpointForQuit()
    }

    @Test func uiGetHandlesNullOptionalRoundTripAndInvalidKeyErrors() async throws {
        let dir = try Self.makeTempLibraryURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let core = Core(libraryURL: dir)

        let missing: String? = try await core.callOptional(.uiGet(key: "ui.missing"), as: String.self)
        #expect(missing == nil)

        try await core.run(.uiSet(key: "ui.saved_searches", value: #"[{"id":"1","name":"Swift","query":"swift"}]"#))
        let stored: String? = try await core.callOptional(.uiGet(key: "ui.saved_searches"), as: String.self)
        #expect(stored == #"[{"id":"1","name":"Swift","query":"swift"}]"#)

        do {
            let _: String? = try await core.callOptional(.uiGet(key: "forbidden_prefix"), as: String.self)
            Issue.record("Expected invalid UI key to throw CoreError.server")
        } catch let error as CoreError {
            if case .server(let msg) = error {
                #expect(msg.isEmpty == false)
            } else {
                Issue.record("Expected CoreError.server, got \(error)")
            }
        }

        await core.checkpointForQuit()
    }

    @Test func linksPaginationAndCountsRoundTripThroughRustFFI() async throws {
        let dir = try Self.makeTempLibraryURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let core = Core(libraryURL: dir)
        try await core.run(.addLink(url: "https://github.com/apple/swift"))
        try await core.run(.addLink(url: "https://arxiv.org/abs/2401.00001"))
        try await core.run(.addLink(url: "https://github.com/rust-lang/rust"))

        let counts: LinkCounts = try await core.call(.linkCounts)
        #expect(counts.total == 3)
        #expect(counts.github == 2)
        #expect(counts.arxiv == 1)

        let page1: LinksPage = try await core.call(.linksPage(q: "", category: "github", onlyDead: false, limit: 1, offset: 0))
        #expect(page1.total == 2)
        #expect(page1.links.count == 1)
        #expect(page1.counts.total == 3)

        let page2: LinksPage = try await core.call(.linksPage(q: "", category: "github", onlyDead: false, limit: 1, offset: 1))
        #expect(page2.total == 2)
        #expect(page2.links.count == 1)
        #expect(page1.links.first?.id != page2.links.first?.id)

        let linkID = try #require(page1.links.first?.id)
        let items: [Item] = try await core.call(.linkItems(id: linkID, limit: 60, offset: 0))
        #expect(items.isEmpty)

        await core.checkpointForQuit()
    }

    @Test func cancelledTaskThrowsCancellationError() async throws {
        let dir = try Self.makeTempLibraryURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let core = Core(libraryURL: dir)
        let task = Task { () throws -> Stats in
            try await Task.sleep(for: .milliseconds(50))
            return try await core.call(.stats)
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Cancelled task should throw CancellationError")
        } catch is CancellationError {
            // Expected cancellation path
        }

        await core.checkpointForQuit()
    }

    @Test func checkpointForQuitDrainsConcurrentWorkAndRejectsFutureCalls() async throws {
        let dir = try Self.makeTempLibraryURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let core = Core(libraryURL: dir)
        let opened = await core.ensureOpen()
        try #require(opened)

        await withTaskGroup(of: Bool.self) { group in
            for idx in 0..<6 {
                group.addTask {
                    do {
                        try await core.run(.uiSet(key: "ui.k\(idx)", value: "v\(idx)"))
                        return true
                    } catch {
                        return false
                    }
                }
            }
            await core.checkpointForQuit()
            for await _ in group {}
        }

        await #expect(throws: CoreError.libraryNotOpen) {
            let _: Stats = try await core.call(.stats)
        }
    }
}
