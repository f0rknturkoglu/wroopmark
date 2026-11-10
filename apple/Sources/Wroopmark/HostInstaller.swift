import AppKit
import Foundation

struct ExtensionStatus: Equatable, Sendable {
    struct Browser: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let app: URL
        let page: String
    }

    let helperAvailable: Bool
    let installedBrowsers: [Browser]

    static let empty = ExtensionStatus(helperAvailable: false, installedBrowsers: [])
}

/// Registers the `wroopmark` helper inside the app bundle as the native
/// messaging host of every Chromium browser on the machine, so installing
/// the app is all the browser extension needs. Disk and LaunchServices checks
/// run off `@MainActor`.
enum HostInstaller {
    static let hostName = "com.wroopmark.host"
    /// Fixed by the "key" in extensions/chromium/manifest.json.
    static let extensionID = "kdkgliladllpidmnacdcackcamaknlej"

    static let browserDirs = [
        "Google/Chrome", "Google/Chrome Beta", "Google/Chrome Canary", "Chromium",
        "BraveSoftware/Brave-Browser", "Microsoft Edge", "Vivaldi", "Arc/User Data", "net.imput.helium",
    ]

    /// The helper binary shipped in Contents/Helpers.
    static var helperURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/wroopmark")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Asynchronously performs disk checks and writes on a background utility thread.
    static func registerIfNeeded() async {
        await Task.detached(priority: .utility) {
            registerSync()
            syncExtension()
        }.value
    }

    /// Resolves helper availability and installed Chromium browsers off the main thread.
    static func status() async -> ExtensionStatus {
        await Task.detached(priority: .utility) {
            let helperAvailable = helperURL != nil
            let known: [(String, String, String)] = [
                ("com.google.Chrome", "Chrome", "chrome://extensions"),
                ("com.brave.Browser", "Brave", "brave://extensions"),
                ("company.thebrowser.Browser", "Arc", "arc://extensions"),
                ("com.microsoft.edgemac", "Edge", "edge://extensions"),
                ("com.vivaldi.Vivaldi", "Vivaldi", "vivaldi://extensions"),
                ("org.chromium.Chromium", "Chromium", "chrome://extensions"),
                ("net.imput.helium", "Helium", "chrome://extensions"),
            ]
            let browsers = known.compactMap { id, name, page in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map {
                    ExtensionStatus.Browser(id: id, name: name, app: $0, page: page)
                }
            }
            return ExtensionStatus(helperAvailable: helperAvailable, installedBrowsers: browsers)
        }.value
    }

    static func fileExists(atPath path: String) async -> Bool {
        await Task.detached(priority: .utility) {
            FileManager.default.fileExists(atPath: path)
        }.value
    }

    // MARK: Chromium extension folder

    /// Where the browser loads the unpacked extension from. Fixed, so moving
    /// or deleting the source checkout never breaks it; refreshed from the
    /// copy inside the app at every launch (an app update -> "reload" in the
    /// browser picks up the new extension).
    static var extensionFolder: URL {
        AppPaths.applicationSupportDirectory
            .appendingPathComponent("wroopmark/chromium-extension", isDirectory: true)
    }

    private static var bundledExtension: URL? {
        let url = Bundle.main.resourceURL?.appendingPathComponent("ChromiumExtension", isDirectory: true)
        return url.flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) ? $0 : nil }
    }

    /// Copies files that differ; leaves the folder alone when nothing changed.
    private static func syncExtension() {
        guard let source = bundledExtension else { return }
        let fm = FileManager.default
        guard let files = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for case let file as URL in files {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let rel = file.path.replacingOccurrences(of: source.path + "/", with: "")
            let target = extensionFolder.appendingPathComponent(rel)
            if let a = try? Data(contentsOf: file), let b = try? Data(contentsOf: target), a == b { continue }
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            try? fm.copyItem(at: file, to: target)
        }
    }

    /// Syncs the extension off `@MainActor`, then reveals it and opens the browser.
    @MainActor
    static func openExtensionSetup(browser: URL?, page: String?) async -> String? {
        await Task.detached(priority: .utility) {
            syncExtension()
        }.value
        let folder = extensionFolder
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(folder.path, forType: .string)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        if let browser, let page, let url = URL(string: page) {
            do {
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                return error.localizedDescription
            }
        }
        return nil
    }

    private static func registerSync() {
        guard let helper = helperURL else { return }
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "wroopmark",
            "path": helper.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else { return }
        let fm = FileManager.default
        let support = AppPaths.applicationSupportDirectory
        for dir in browserDirs {
            let base = support.appendingPathComponent(dir, isDirectory: true)
            guard fm.fileExists(atPath: base.path) else { continue }
            let hosts = base.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            let file = hosts.appendingPathComponent("\(hostName).json")
            if let existing = try? Data(contentsOf: file),
               let obj = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
               obj["path"] as? String == helper.path {
                continue
            }
            try? fm.createDirectory(at: hosts, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}
