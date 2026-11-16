import AppKit
import Foundation
import Observation
import Security

/// Updates for the Mac app, which is not in the App Store: once a day it
/// asks GitHub for the latest release (nothing about the user is sent),
/// and on the user's word downloads it, checks it and swaps it in.
///
/// The new app is installed only if its signature is valid, Gatekeeper
/// accepts it (Developer ID, notarized) and it is signed by the same team
/// as the running one: a package put on the release page by anyone else
/// is never installed. A build without a Developer ID signature (built
/// from source) only opens the release page.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    struct Release: Equatable {
        let version: String
        let page: URL
        let zip: URL?
        let notes: String
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading
        case failed(String)
    }

    var phase: Phase = .idle
    @ObservationIgnored private var checkedAt: Date?

    private static let repo = "f0rknturkoglu/wroopmark"
    private static let enabledKey = "updatesAutoCheck"

    var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// At launch and then daily, if the user has not turned it off.
    func checkInBackground() {
        guard autoCheck else { return }
        if let checkedAt, Date.now.timeIntervalSince(checkedAt) < 20 * 3600 { return }
        Task { await check() }
    }

    func check() async {
        phase = .checking
        checkedAt = .now
        do {
            let release = try await Self.latest()
            phase = Self.isNewer(release.version, than: Self.currentVersion) ? .available(release) : .upToDate
        } catch {
            phase = .failed(String(localized: "Güncelleme denetlenemedi: \(error.localizedDescription)"))
        }
    }

    /// Downloads, verifies and installs; the app quits and opens again.
    func install(_ release: Release) async {
        guard let zip = release.zip, Self.ownTeam != nil else {
            NSWorkspace.shared.open(release.page)
            return
        }
        phase = .downloading
        do {
            let app = try await Self.download(zip)
            try Self.verify(app)
            try Self.swapAndRelaunch(with: app)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: GitHub

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }

        let tag_name: String
        let html_url: URL
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    private static func latest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("wroopmark-updater", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.noRelease }
        let r = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !r.draft, !r.prerelease else { throw UpdateError.noRelease }
        let arch = machineArch
        // wroopmark-<version>-macos-<arch>.zip; a universal one when there is no match.
        let zips = r.assets.filter { $0.name.hasSuffix(".zip") && $0.name.contains("-macos-") }
        let zip = zips.first { $0.name.contains("-\(arch).") } ?? zips.first { $0.name.contains("universal") }
        let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
        return Release(version: version, page: r.html_url, zip: zip?.browser_download_url, notes: r.body ?? "")
    }

    private static var machineArch: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    /// "1.10.0" is newer than "1.9.2"; anything after a "-" is ignored.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? [] }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: Download and check

    enum UpdateError: LocalizedError {
        case noRelease, badArchive, badSignature, otherTeam, cannotReplace

        var errorDescription: String? {
            switch self {
            case .noRelease: String(localized: "Yayınlanmış bir sürüm bulunamadı.")
            case .badArchive: String(localized: "İndirilen paket açılamadı.")
            case .badSignature: String(localized: "İndirilen uygulamanın imzası doğrulanamadı; kurulmadı.")
            case .otherTeam: String(localized: "İndirilen uygulama başka bir geliştiricinin imzasını taşıyor; kurulmadı.")
            case .cannotReplace: String(localized: "Uygulama yerine konamadı. Yeni sürümü indirme sayfasından elle kurabilirsin.")
            }
        }
    }

    /// The zip, unpacked into a fresh temporary folder; returns the .app.
    private static func download(_ url: URL) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.badArchive }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wroopmark-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: file, to: zip)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
        guard let app = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw UpdateError.badArchive }
        return app
    }

    /// Valid signature, accepted by Gatekeeper, same team as this app.
    private static func verify(_ app: URL) throws {
        guard let mine = ownTeam else { throw UpdateError.badSignature }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { throw UpdateError.badSignature }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else { throw UpdateError.badSignature }
        guard team(of: code) == mine else { throw UpdateError.otherTeam }
        // Gatekeeper: Developer ID and notarization.
        do {
            try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        } catch {
            throw UpdateError.badSignature
        }
    }

    /// The team that signed the running app; nil for an unsigned or ad-hoc build.
    static var ownTeam: String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var stat: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &stat) == errSecSuccess, let stat else { return nil }
        return team(of: stat)
    }

    private static func team(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// A small script waits for this app to quit, puts the old copy in the
    /// Trash, moves the new one to the same place and opens it.
    private static func swapAndRelaunch(with app: URL) throws {
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else { throw UpdateError.cannotReplace }
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
        old="$(mktemp -d)/wroopmark-old.app"
        mv "$1" "$old" && mv "$2" "$1" && open "$1" && mv "$old" ~/.Trash/ 2>/dev/null
        [ -d "$1" ] || { mv "$old" "$1"; open "$1"; }
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", target.path, app.path]
        try p.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.badArchive }
    }
}
