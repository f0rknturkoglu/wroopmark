import AppKit
import CoreSpotlight
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    /// Deletions still undoable in the clean-up view are committed, and the database is cleanly checkpointed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            if let model, model.hasPendingTriage {
                await model.commitTriage()
            }
            await Core.shared.checkpointForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct WroopmarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @AppStorage("menuBarIcon") private var menuBarIcon = true

    var body: some Scene {
        WindowGroup("wroopmark", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 600)
                .tint(Theme.accent)
                .task {
                    delegate.model = model
                    await model.start()
                }
                // wroopmark://item/<id> (the browser extension), …/search, …/add
                .onOpenURL { model.open(url: $0) }
                // …in this window, instead of opening a new one per link.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                // A post picked in Spotlight.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String { model.reveal(id: id) }
                }
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
                Button("Seçilenleri sil") { model.requestDelete(Array(model.selection)) }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selection.isEmpty)
                Divider()
                Button("Kart görünümü") { model.layout = .grid }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Liste görünümü") { model.layout = .list }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Akış görünümü") { model.layout = .feed }
                    .keyboardShortcut("3", modifiers: .command)
                Divider()
                Button("Filtreler…") { model.showFilters = true }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Aramayı kaydet…") { model.showSaveSearch = true }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.searchToSave.isEmpty)
                Button("Ayıkla") { model.scope = .triage }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
                Button("İndirmeler") { model.showDownloads.toggle() }
                    .keyboardShortcut("j", modifiers: .command)
                Divider()
                Button(model.isBackingUp ? "Yedekleniyor…" : "Şimdi yedekle") { Task { await model.runBackup() } }
                    .disabled(model.backupFolder == nil || model.isBackingUp)
            }
            CommandMenu("Görünüm") {
                Picker("Tema", selection: $model.theme) {
                    ForEach(AppTheme.allCases) { th in
                        Label(th.label, systemImage: th.iconName).tag(th)
                    }
                }
            }
        }

        MenuBarExtra(isInserted: $menuBarIcon) {
            QuickAddMenu()
                .environment(model)
                .tint(Theme.accent)
        } label: {
            Image(systemName: "bookmark.fill")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(model.theme.colorScheme)
                .tint(Theme.accent)
        }
    }
}
