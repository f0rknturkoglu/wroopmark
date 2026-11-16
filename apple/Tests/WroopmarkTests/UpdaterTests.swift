import Testing
@testable import Wroopmark

struct UpdaterTests {
    @Test func comparesVersionsByNumber() {
        #expect(Updater.isNewer("1.10.0", than: "1.9.2"))
        #expect(Updater.isNewer("1.6.1", than: "1.6.0"))
        #expect(Updater.isNewer("2.0", than: "1.99.99"))
        #expect(!Updater.isNewer("1.6.0", than: "1.6.0"))
        #expect(!Updater.isNewer("1.6", than: "1.6.0"))
        #expect(!Updater.isNewer("1.5.9", than: "1.6.0"))
        #expect(!Updater.isNewer("1.6.0-beta", than: "1.6.0"))
    }
}
