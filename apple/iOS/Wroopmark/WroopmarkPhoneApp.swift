import SwiftUI

@main
struct WroopmarkPhoneApp: App {
    @State private var model: PhoneModel

    init() {
        Self.moveLibraryToGroup()
        _model = State(initialValue: PhoneModel())
    }

    /// Before the share extension: the library lived in the app's own
    /// container. Moved once, before the core opens it.
    private static func moveLibraryToGroup() {
        let fm = FileManager.default
        let old = AppPaths.applicationSupportDirectory.appendingPathComponent("wroopmark", isDirectory: true)
        let new = AppPaths.defaultLibraryURL
        guard old.standardizedFileURL != new.standardizedFileURL,
              fm.fileExists(atPath: old.appendingPathComponent("library.sqlite").path),
              !fm.fileExists(atPath: new.appendingPathComponent("library.sqlite").path) else { return }
        try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: new)
        try? fm.moveItem(at: old, to: new)
    }
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(model)
                .tint(PhoneTheme.accent)
                .task { await model.start() }
                .onOpenURL { model.open($0) }
                .onChange(of: phase) { _, now in
                    // Coming back: the Mac may have saved things meanwhile.
                    if now == .active { Task { await model.becameActive() } }
                    if now == .background { model.enteredBackground() }
                }
        }
    }
}

enum PhoneTheme {
    static let accent = Color(red: 0.47, green: 0.29, blue: 0.93)
}
