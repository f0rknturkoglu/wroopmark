import SwiftUI
import UIKit
import WebKit

/// Loads one page in a hidden web view and returns its web archive and text.
@MainActor
final class PageCopier: NSObject, WKNavigationDelegate {
    private var loaded: CheckedContinuation<Bool, Never>?

    private static let readerJS = """
    (() => {
      const pick = document.querySelector('article') || document.querySelector('main') || document.body;
      return pick ? String(pick.innerText || '').slice(0, 60000) : '';
    })()
    """

    func copy(_ url: URL) async -> (data: Data, text: String)? {
        let config = WKWebViewConfiguration()
        // No cookies or storage are kept between pages.
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.allowsInlineMediaPlayback = false
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 1800), configuration: config)
        web.navigationDelegate = self
        defer {
            web.stopLoading()
            web.navigationDelegate = nil
        }
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            loaded = c
            web.load(URLRequest(url: url, timeoutInterval: 30))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(35))
                self?.finish(false)
            }
        }
        guard ok else { return nil }
        // Give late scripts and lazy pictures a moment, scrolled down.
        try? await Task.sleep(for: .seconds(1.5))
        _ = try? await web.evaluateJavaScript("window.scrollTo(0, document.body ? document.body.scrollHeight : 0)")
        try? await Task.sleep(for: .seconds(1))
        let text = (try? await web.evaluateJavaScript(Self.readerJS)) as? String ?? ""
        let data: Data? = await withCheckedContinuation { c in
            web.createWebArchiveData { result in c.resume(returning: try? result.get()) }
        }
        guard let data, !data.isEmpty else { return nil }
        return (data, text)
    }

    private func finish(_ ok: Bool) {
        loaded?.resume(returning: ok)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish(false) }
}

extension PhoneModel {
    /// Saves readable offline `.webarchive` copies for saved web pages while
    /// the app is open, there is room on the phone and Low Power Mode is off.
    func startPageCopies() {
        guard pageCopyTask == nil, !lowSpace, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        struct Row: Decodable, Sendable {
            let id: String
            let url: String
        }
        pageCopyTask = Task(priority: .utility) { [weak self] in
            defer { self?.pageCopyTask = nil }
            let copier = PageCopier()
            while let self, !self.lowSpace, !ProcessInfo.processInfo.isLowPowerModeEnabled, !Task.isCancelled {
                guard let rows: [Row] = try? await self.core.call(.call("snapshot_pending", ["limit": .int(3)])), !rows.isEmpty else { break }
                for row in rows {
                    guard !self.lowSpace, !ProcessInfo.processInfo.isLowPowerModeEnabled, !Task.isCancelled else { return }
                    let result = if let url = URL(string: row.url) { await copier.copy(url) } else { nil as (data: Data, text: String)? }
                    if let result, result.data.count < 40 << 20 {
                        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wm-snap-\(UUID().uuidString).webarchive")
                        if (try? result.data.write(to: tmp)) != nil {
                            _ = try? await self.core.run(.call("set_snapshot", ["id": .string(row.id), "path": .string(tmp.path), "text": .string(result.text)]))
                        }
                        try? FileManager.default.removeItem(at: tmp)
                    } else {
                        _ = try? await self.core.run(.call("snapshot_failed", ["id": .string(row.id)]))
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
                await self.loadAIStatus()
            }
            await self?.loadAIStatus()
        }
    }

    func stopPageCopies() {
        pageCopyTask?.cancel()
        pageCopyTask = nil
    }
}

/// Shows the saved `.webarchive` copy of a page offline.
struct PageCopySheet: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: Item

    var body: some View {
        NavigationStack {
            Group {
                if let file = item.snapshot {
                    WebArchiveView(file: model.core.mediaURL(file), base: URL(string: item.url))
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle(item.title ?? (URL(string: item.url)?.host() ?? String(localized: "Sayfanın kopyası")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kapat") { dismiss() }
                }
            }
        }
    }
}

/// A `.webarchive` shown as it was saved; scripts stay off, so nothing
/// reaches out to the site.
struct WebArchiveView: UIViewRepresentable {
    let file: URL
    let base: URL?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: config)
        if let data = try? Data(contentsOf: file) {
            web.load(data, mimeType: "application/x-webarchive", characterEncodingName: "utf-8", baseURL: base ?? file)
        }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
