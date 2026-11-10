import Foundation
import Synchronization
import Testing
@testable import Wroopmark

private final class AsyncGate: Sendable {
    private struct State {
        var reached = false
        var waitingForReach: CheckedContinuation<Void, Never>?
        var releaseContinuation: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    func waitForRelease() async {
        await withCheckedContinuation { releaseCont in
            let reachWaiter = state.withLock { st -> CheckedContinuation<Void, Never>? in
                st.reached = true
                st.releaseContinuation = releaseCont
                let w = st.waitingForReach
                st.waitingForReach = nil
                return w
            }
            reachWaiter?.resume()
        }
    }

    func waitUntilReached() async {
        await withCheckedContinuation { reachCont in
            let alreadyReached = state.withLock { st -> Bool in
                if st.reached { return true }
                st.waitingForReach = reachCont
                return false
            }
            if alreadyReached { reachCont.resume() }
        }
    }

    func release() {
        let cont = state.withLock { st -> CheckedContinuation<Void, Never>? in
            let c = st.releaseContinuation
            st.releaseContinuation = nil
            return c
        }
        cont?.resume()
    }
}

@MainActor
struct AppModelConcurrencyTests {
    @Test func overlappingReloadDiscardsStaleResultAndKeepsLoadingTrueUntilLatestFinishes() async throws {
        let (defaults, suite) = TestFixtures.makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let slowGate = AsyncGate()
        let fastGate = AsyncGate()
        let searchCount = Mutex<Int>(0)

        let mock = MockCoreClient { command in
            switch command {
            case .search(let q, _, _, _):
                let seq = searchCount.withLock { count -> Int in
                    count += 1
                    return count
                }
                if q == "slow" {
                    await slowGate.waitForRelease()
                    return .jsonData(TestFixtures.searchResultJSON(itemIDs: ["stale-\(seq)"]))
                } else {
                    await fastGate.waitForRelease()
                    return .jsonData(TestFixtures.searchResultJSON(itemIDs: ["fresh-\(seq)"]))
                }
            case .stats:
                return .jsonData(TestFixtures.statsJSON())
            case .tags, .folders:
                return .jsonData(TestFixtures.emptyArrayJSON())
            case .linkCounts:
                return .jsonData(TestFixtures.emptyLinkCountsJSON())
            case .downloads:
                return .jsonData(TestFixtures.emptyDownloadsJSON())
            default:
                return .voidOK
            }
        }

        let model = AppModel(core: mock, defaults: defaults, enableSystemIntegrations: false)
        defer { model.stopBackgroundWork() }

        model.query = "slow"
        let firstTask = Task { await model.reload() }
        await slowGate.waitUntilReached()

        model.query = "fast"
        let secondTask = Task { await model.reload() }
        await fastGate.waitUntilReached()

        // Release the slower, cancelled first response while the second reload is still waiting.
        slowGate.release()
        await firstTask.value

        #expect(model.isLoading == true)
        #expect(model.items.isEmpty)
        #expect(model.gridError == nil)

        // Release the newer second response and verify it wins.
        fastGate.release()
        await secondTask.value

        #expect(model.isLoading == false)
        #expect(model.items.map(\.id) == ["fresh-2"])
    }

    @Test func linksPaginationAndLeavingScopeReleasesLinkPoolMemory() async throws {
        let (defaults, suite) = TestFixtures.makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let mock = MockCoreClient { command in
            switch command {
            case .linksPage(_, _, _, _, let offset):
                if offset == 0 {
                    return .jsonData(TestFixtures.linksPageJSON(ids: [1, 2], total: 3))
                } else {
                    return .jsonData(TestFixtures.linksPageJSON(ids: [3], total: 3))
                }
            default:
                return .voidOK
            }
        }

        let model = AppModel(core: mock, defaults: defaults, enableSystemIntegrations: false)
        defer { model.stopBackgroundWork() }

        model.scope = .links(nil)
        await model.loadLinks(onlyDead: false, reset: true)

        #expect(model.links.map(\.id) == [1, 2])
        #expect(model.linksTotal == 3)
        #expect(model.linkCategoryCount(.github) == 3)
        #expect(model.reachedLinksEnd == false)

        await model.loadMoreLinks()

        #expect(model.links.map(\.id) == [1, 2, 3])
        #expect(model.reachedLinksEnd == true)

        model.scope = .all
        #expect(model.links.isEmpty)
        #expect(model.linkItems.isEmpty)
        #expect(model.selectedLink == nil)
        #expect(model.linksTotal == 0)
        #expect(model.linksError == nil)
    }

    @Test func selectLinkIgnoresStaleResponseWhenSelectionChangesQuickly() async throws {
        let (defaults, suite) = TestFixtures.makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let slowGate = AsyncGate()

        let linkAJSON = Data(#"{"id":10,"url":"https://a.example","host":"a.example","title":"A","description":null,"image":null,"first_seen":1,"manual":false,"item_count":1,"dead":false,"status":200,"checked_at":1}"#.utf8)
        let linkBJSON = Data(#"{"id":20,"url":"https://b.example","host":"b.example","title":"B","description":null,"image":null,"first_seen":2,"manual":false,"item_count":1,"dead":false,"status":200,"checked_at":1}"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let linkA = try decoder.decode(LinkRow.self, from: linkAJSON)
        let linkB = try decoder.decode(LinkRow.self, from: linkBJSON)

        let itemsA = Data(#"[{"id":"item-a","platform":"web","url":"https://a.example","text":"A","saved_at":1,"media":[],"links":[],"tags":[]}]"#.utf8)
        let itemsB = Data(#"[{"id":"item-b","platform":"web","url":"https://b.example","text":"B","saved_at":2,"media":[],"links":[],"tags":[]}]"#.utf8)

        let mock = MockCoreClient { command in
            switch command {
            case .linkItems(let id, _, _):
                if id == 10 {
                    await slowGate.waitForRelease()
                    return .jsonData(itemsA)
                }
                return .jsonData(itemsB)
            default:
                return .voidOK
            }
        }

        let model = AppModel(core: mock, defaults: defaults, enableSystemIntegrations: false)
        defer { model.stopBackgroundWork() }

        let selectA = Task { await model.select(link: linkA) }
        await slowGate.waitUntilReached()

        await model.select(link: linkB)
        #expect(model.selectedLink?.id == 20)
        #expect(model.linkItems.map(\.id) == ["item-b"])

        slowGate.release()
        await selectA.value

        #expect(model.selectedLink?.id == 20)
        #expect(model.linkItems.map(\.id) == ["item-b"])
    }

    @Test func errorsSurfaceToUIPropertiesAndNullUIGetStaysSilent() async throws {
        let (defaults, suite) = TestFixtures.makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let failSavedSearch = Mutex<Bool>(false)

        let mock = MockCoreClient { command in
            switch command {
            case .search:
                throw CoreError.server("arama hatasi")
            case .addFolder:
                throw CoreError.server("klasor eklenemedi")
            case .linksPage:
                throw CoreError.server("link havuzu okunamadi")
            case .linkItems:
                throw CoreError.server("link kayitlari okunamadi")
            case .downloads:
                throw CoreError.server("indirme listesi hatasi")
            case .uiGet:
                if failSavedSearch.withLock({ $0 }) {
                    throw CoreError.server("ayarlar okunamadi")
                }
                return .nullResult
            case .stats:
                return .jsonData(TestFixtures.statsJSON())
            case .tags, .folders:
                return .jsonData(TestFixtures.emptyArrayJSON())
            case .linkCounts:
                return .jsonData(TestFixtures.emptyLinkCountsJSON())
            default:
                return .voidOK
            }
        }

        let model = AppModel(core: mock, defaults: defaults, enableSystemIntegrations: false)
        defer { model.stopBackgroundWork() }

        await model.loadSavedSearches()
        #expect(model.savedSearches.isEmpty)
        #expect(model.errorMessage == nil)

        failSavedSearch.withLock { $0 = true }
        await model.loadSavedSearches()
        #expect(model.errorMessage == "ayarlar okunamadi")
        model.errorMessage = nil

        await model.reload()
        #expect(model.gridError == "arama hatasi")

        let added = await model.addFolder(name: "Rust")
        #expect(added == nil)
        #expect(model.errorMessage == "klasor eklenemedi")

        model.scope = .links(nil)
        await model.loadLinks(reset: true)
        #expect(model.linksError == "link havuzu okunamadi")

        let linkJSON = Data(#"{"id":1,"url":"https://example.com","host":"example.com","title":"Ex","description":null,"image":null,"first_seen":1,"manual":false,"item_count":1,"dead":false,"status":200,"checked_at":1}"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let link = try decoder.decode(LinkRow.self, from: linkJSON)
        await model.select(link: link)
        #expect(model.linkItemsError == "link kayitlari okunamadi")

        await model.refreshDownloads()
        #expect(model.downloadsError == "indirme listesi hatasi")
    }

    @Test func refreshMetaSkipsRedundantFetchesWhenStatsUnchanged() async throws {
        let (defaults, suite) = TestFixtures.makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let mock = MockCoreClient { command in
            switch command {
            case .stats:
                return .jsonData(TestFixtures.statsJSON())
            case .tags, .folders:
                return .jsonData(TestFixtures.emptyArrayJSON())
            case .linkCounts:
                return .jsonData(TestFixtures.emptyLinkCountsJSON())
            default:
                return .voidOK
            }
        }

        let model = AppModel(core: mock, defaults: defaults, enableSystemIntegrations: false)
        defer { model.stopBackgroundWork() }

        await model.refreshMeta()
        let firstCount = mock.recordedCommands.filter { $0 == .linkCounts }.count
        #expect(firstCount == 1)

        mock.resetRecordedCommands()
        await model.refreshMeta()
        let secondStatsCount = mock.recordedCommands.filter { $0 == .stats }.count
        let secondMetaCount = mock.recordedCommands.filter { $0 == .linkCounts || $0 == .tags || $0 == .folders }.count

        #expect(secondStatsCount == 1)
        #expect(secondMetaCount == 0)
    }

    @Test func moveToFolderUpdatesInPlaceOrRevertsOnFailure() async throws {
        let (defaults, suite) = TestFixtures.makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let shouldFailMove = Mutex<Bool>(false)

        let mock = MockCoreClient { command in
            switch command {
            case .moveToFolder:
                if shouldFailMove.withLock({ $0 }) {
                    throw CoreError.server("klasor tasima hatasi")
                }
                return .voidOK
            case .stats:
                return .jsonData(TestFixtures.statsJSON())
            case .tags, .folders:
                return .jsonData(TestFixtures.emptyArrayJSON())
            case .linkCounts:
                return .jsonData(TestFixtures.emptyLinkCountsJSON())
            default:
                return .voidOK
            }
        }

        let model = AppModel(core: mock, defaults: defaults, enableSystemIntegrations: false)
        defer { model.stopBackgroundWork() }

        model.items = [TestFixtures.makeItem(id: "i1", folderId: nil)]
        await model.moveToFolder(id: "i1", folderID: 9)

        #expect(model.items.first?.folderId == 9)
        let ranSearch = mock.recordedCommands.contains {
            if case .search = $0 { return true }
            return false
        }
        #expect(ranSearch == false)

        shouldFailMove.withLock { $0 = true }
        await model.moveToFolder(id: "i1", folderID: 15)

        #expect(model.items.first?.folderId == 9)
        #expect(model.errorMessage == "klasor tasima hatasi")
    }

    @Test func addURLsBatchesReloadAndSurfacesPartialFailures() async throws {
        let (defaults, suite) = TestFixtures.makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let mock = MockCoreClient { command in
            switch command {
            case .addURL(let url, _, _, _):
                if url.contains("bad.invalid") {
                    throw CoreError.server("url gecersiz")
                }
                let id = url.contains("one") ? "id-one" : "id-two"
                let json = """
                {"id":"\(id)","platform":"web","url":"\(url)","text":"ok","saved_at":1,"media":[],"links":[],"tags":[]}
                """
                return .jsonData(Data(json.utf8))
            case .search:
                return .jsonData(TestFixtures.searchResultJSON(itemIDs: ["id-one", "id-two"]))
            case .stats:
                return .jsonData(TestFixtures.statsJSON(items: 2))
            case .tags, .folders:
                return .jsonData(TestFixtures.emptyArrayJSON())
            case .linkCounts:
                return .jsonData(TestFixtures.emptyLinkCountsJSON())
            default:
                return .voidOK
            }
        }

        let model = AppModel(core: mock, defaults: defaults, enableSystemIntegrations: false)
        defer { model.stopBackgroundWork() }

        await model.addURLs([
            "https://one.example",
            "https://bad.invalid",
            "https://two.example",
        ])

        let commands = mock.recordedCommands
        let addCount = commands.filter { if case .addURL = $0 { return true }; return false }.count
        let searchCount = commands.filter { if case .search = $0 { return true }; return false }.count

        #expect(addCount == 3)
        #expect(searchCount == 1)
        #expect(model.selection == ["id-two"])
        #expect(model.errorMessage?.contains("bad.invalid") == true)
    }

    @Test func triageMoveAndUndoExecuteSeriallyAndClearFolderToNil() async throws {
        let (defaults, suite) = TestFixtures.makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let mock = MockCoreClient { command in
            switch command {
            case .stats:
                return .jsonData(TestFixtures.statsJSON())
            case .tags, .folders:
                return .jsonData(TestFixtures.emptyArrayJSON())
            case .linkCounts:
                return .jsonData(TestFixtures.emptyLinkCountsJSON())
            default:
                return .voidOK
            }
        }

        let model = AppModel(core: mock, defaults: defaults, enableSystemIntegrations: false)
        defer { model.stopBackgroundWork() }

        let folderJSON = Data(#"{"id":7,"name":"Okunacak","count":0,"created_at":1}"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let folder = try decoder.decode(Folder.self, from: folderJSON)

        model.scope = .triage
        model.items = [TestFixtures.makeItem(id: "t1", folderId: nil)]
        model.total = 1

        model.triageMoveToFolder(folder)
        model.undoTriage()
        await model.waitForPendingTriage()

        #expect(model.items.map(\.id) == ["t1"])
        #expect(model.triageKept == 0)

        let triageCommands = mock.recordedCommands.filter {
            switch $0 {
            case .moveToFolder, .setReviewed: return true
            default: return false
            }
        }
        #expect(triageCommands == [
            .moveToFolder(id: "t1", folderID: 7),
            .setReviewed(ids: ["t1"], reviewed: true),
            .setReviewed(ids: ["t1"], reviewed: false),
            .moveToFolder(id: "t1", folderID: nil),
        ])
    }
}
