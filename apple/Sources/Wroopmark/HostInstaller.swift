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

    static func registerIfNeeded() {
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
