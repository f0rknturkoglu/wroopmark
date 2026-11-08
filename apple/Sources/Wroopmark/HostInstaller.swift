import AppKit
import Foundation

/// Registers the `wroopmark` helper inside the app bundle as the native
/// messaging host of every Chromium browser on the machine, so installing
/// the app is all the browser extension needs. Runs on every launch and only
/// writes when a manifest is missing or points elsewhere.
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

    // MARK: Chromium extension folder

    /// Where the browser loads the unpacked extension from. Fixed, so moving
    /// or deleting the source checkout never breaks it; refreshed from the
    /// copy inside the app at every launch (an app update → "reload" in the
    /// browser picks up the new extension).
    static var extensionFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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

    /// Chromium browsers on this Mac: (name, app URL, extensions page).
    static var installedBrowsers: [(name: String, app: URL, page: String)] {
        let known: [(String, String, String)] = [
            ("com.google.Chrome", "Chrome", "chrome://extensions"),
            ("com.brave.Browser", "Brave", "brave://extensions"),
            ("company.thebrowser.Browser", "Arc", "arc://extensions"),
            ("com.microsoft.edgemac", "Edge", "edge://extensions"),
            ("com.vivaldi.Vivaldi", "Vivaldi", "vivaldi://extensions"),
            ("org.chromium.Chromium", "Chromium", "chrome://extensions"),
            ("net.imput.helium", "Helium", "chrome://extensions"),
        ]
        return known.compactMap { id, name, page in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { (name, $0, page) }
        }
    }

    /// Shows the folder to pick in "Load unpacked", with its path on the
    /// clipboard, and the browser's extensions page next to it.
    static func openExtensionSetup(browser: URL?, page: String?) {
        syncExtension()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(extensionFolder.path, forType: .string)
        NSWorkspace.shared.activateFileViewerSelecting([extensionFolder])
        if let browser, let page, let url = URL(string: page) {
            NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
        }
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
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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
