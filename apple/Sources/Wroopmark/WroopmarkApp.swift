import AppKit
import CoreSpotlight
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    /// Deletions still undoable in the clean-up view are committed, and the database is cleanly checkpointed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            if let model {
                model.stopBackgroundWork()
                if model.hasPendingTriage {
                    await model.commitTriage()
                } else {
                    await model.waitForPendingTriage()
                }
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
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .sidebar) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { model.sidebarVisible.toggle() }
                } label: {
                    Label(
                        model.sidebarVisible ? "Kenar Çubuğunu Gizle" : "Kenar Çubuğunu Göster",
                        systemImage: "sidebar.left"
                    )
                }
                .keyboardShortcut("s", modifiers: [.control, .command])

                Button {
                    withAnimation(.snappy(duration: 0.2)) { model.showDetailPane.toggle() }
                } label: {
                    Label(
                        model.showDetailPane ? "Detay panelini gizle" : "Detay panelini göster",
                        systemImage: "sidebar.trailing"
                    )
                }
                .keyboardShortcut("i", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button { model.showAdd = true } label: {
                    Label("Bağlantı ekle…", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Kütüphane") {
                Button { Task { await model.reload() } } label: {
                    Label("Yenile", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button { model.showBulkTags = true } label: {
                    Label("Seçilenleri etiketle…", systemImage: "tag")
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(model.selection.isEmpty)
                Button { model.requestDelete(Array(model.selection)) } label: {
                    Label("Seçilenleri sil", systemImage: "trash")
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selection.isEmpty)
                Divider()
                Button { model.layout = .grid } label: {
                    Label("Kart görünümü", systemImage: "square.grid.2x2")
                }
                .keyboardShortcut("1", modifiers: .command)
                Button { model.layout = .list } label: {
                    Label("Liste görünümü", systemImage: "list.bullet")
                }
                .keyboardShortcut("2", modifiers: .command)
                Button { model.layout = .feed } label: {
                    Label("Akış görünümü", systemImage: "rectangle.grid.1x2")
                }
                .keyboardShortcut("3", modifiers: .command)
                Divider()
                Button { model.showFilters = true } label: {
                    Label("Filtreler…", systemImage: "line.3.horizontal.decrease.circle")
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                Button { model.showSaveSearch = true } label: {
                    Label("Aramayı kaydet…", systemImage: "bookmark")
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.searchToSave.isEmpty)
                Button { model.scope = .triage } label: {
                    Label("Ayıkla", systemImage: "arrow.left.arrow.right.square")
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
                Button { model.showDownloads.toggle() } label: {
                    Label("İndirmeler", systemImage: "arrow.down.circle")
                }
                .keyboardShortcut("j", modifiers: .command)
                Divider()
                Button { Task { await model.runBackup() } } label: {
                    Label(model.isBackingUp ? "Yedekleniyor…" : "Şimdi yedekle", systemImage: "externaldrive.badge.timemachine")
                }
                .disabled(model.backupFolder == nil || model.isBackingUp)
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
                .tint(Theme.accent)
        }
    }
}
