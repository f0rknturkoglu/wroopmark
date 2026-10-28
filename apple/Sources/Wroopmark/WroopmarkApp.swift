import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        Core.shared.checkpointForQuit()
    }
}

@main
struct WroopmarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("wroopmark") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 600)
                .tint(Theme.accent)
                .task { await model.start() }
        }
        .defaultSize(width: 1360, height: 860)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Bağlantı ekle…") { model.showAdd = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Kütüphane") {
                Button("Yenile") { Task { await model.reload() } }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Seçilenleri etiketle…") { model.showBulkTags = true }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(model.selection.isEmpty)
                Button("Seçilenleri sil") { Task { await model.delete(Array(model.selection)) } }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selection.isEmpty)
                Divider()
                Button("Kart görünümü") { model.layout = .grid }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Liste görünümü") { model.layout = .list }
                    .keyboardShortcut("2", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .tint(Theme.accent)
                .frame(width: 520, height: 460)
        }
    }
}
