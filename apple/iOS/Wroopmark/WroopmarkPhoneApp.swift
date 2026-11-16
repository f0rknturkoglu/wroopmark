import CoreSpotlight
import SwiftUI
import UIKit

@MainActor
final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let type = options.shortcutItem?.type {
            PhoneModel.pendingAction = type
        }
        let cfg = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        cfg.delegateClass = PhoneSceneDelegate.self
        return cfg
    }
}

@MainActor
final class PhoneSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        PhoneModel.pendingAction = shortcutItem.type
        completionHandler(true)
    }
}

@main
struct WroopmarkPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
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
                // A post chosen in Spotlight or via Handoff.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String { model.openRequest = id }
                }
                .onContinueUserActivity("com.f0rknturkoglu.wroopmark.viewItem") { activity in
                    if let id = activity.userInfo?["id"] as? String { model.openRequest = id }
                }
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
