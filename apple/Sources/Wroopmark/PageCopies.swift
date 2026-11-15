import AppKit
import SwiftUI
import WebKit

// v0.4: a copy of every saved web page, taken with WebKit off screen, so
// the archive keeps the page when the site changes or disappears. Stored as
// a `.webarchive` in the media store (opens in Safari, too); the text WebKit
// reads (scripts run) becomes the item's article text for search and the
// reading view.

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
        // Late scripts and lazy pictures: give them a moment, scrolled down.
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

extension AppModel {
    /// Copies saved pages that have none yet, one at a time, unhurried.
    func startPageCopies() {
        guard pageCopies, pageCopyTask == nil else { return }
        struct Row: Decodable, Sendable {
            let id: String
            let url: String
        }
        pageCopyTask = Task(priority: .utility) { [weak self] in
            defer { self?.pageCopyTask = nil }
            let copier = PageCopier()
            while let self, self.pageCopies, !Task.isCancelled {
                guard let rows: [Row] = try? await self.core.call(.call("snapshot_pending", ["limit": .int(5)])), !rows.isEmpty else { break }
                for row in rows {
                    guard self.pageCopies, !Task.isCancelled else { return }
                    let copy = URL(string: row.url).map { url in Task { await copier.copy(url) } }
                    let result = await copy?.value
                    // Pages over 40 MB are not worth the space.
                    if let result, result.data.count < 40 << 20 {
                        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wroopmark-\(UUID().uuidString).webarchive")
                        if (try? result.data.write(to: tmp)) != nil {
                            _ = await self.perform(.call("set_snapshot", ["id": .string(row.id), "path": .string(tmp.path), "text": .string(result.text)]))
                        }
                        try? FileManager.default.removeItem(at: tmp)
                    } else {
                        _ = await self.perform(.call("snapshot_failed", ["id": .string(row.id)]))
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
                await self.refreshLoaded()
            }
        }
    }
}

/// The saved copy of a page, and a plain reading view of its text.
struct PageCopyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: Item
    @State private var reading = false
    @State private var article: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title ?? item.url).font(.headline).lineLimit(1)
                    Text("Kaydedildiği hâli · \(URL(string: item.url)?.host() ?? "")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Görünüm", selection: $reading) {
                    Text("Sayfa").tag(false)
                    Text("Okuma").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                if let file = item.snapshot {
                    Button("Finder'da göster") { NSWorkspace.shared.activateFileViewerSelecting([model.core.mediaURL(file)]) }
                }
                Button("Kapat") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(Theme.Spacing.md)
            Divider()
            if reading {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        if let t = item.title { Text(t).font(.title.weight(.semibold)) }
                        Text(article ?? item.text)
                            .font(.system(size: 17, design: .serif))
                            .lineSpacing(6)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(Theme.Spacing.xxl)
                    .frame(maxWidth: .infinity)
                }
            } else if let file = item.snapshot {
                WebArchiveView(file: model.core.mediaURL(file), base: URL(string: item.url))
            }
        }
        .frame(minWidth: 900, minHeight: 680)
        .task {
            if let full: Item = try? await model.core.call(.get(id: item.id)), let e = full.extra, !e.isEmpty { article = e }
        }
    }
}

/// A `.webarchive` shown as it was saved; scripts stay off, so nothing
/// reaches out to the site.
struct WebArchiveView: NSViewRepresentable {
    let file: URL
    let base: URL?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: config)
        if let data = try? Data(contentsOf: file) {
            web.load(data, mimeType: "application/x-webarchive", characterEncodingName: "utf-8", baseURL: base ?? file)
        }
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
