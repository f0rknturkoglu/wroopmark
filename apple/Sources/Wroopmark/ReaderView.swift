import AVFoundation
import NaturalLanguage
import SwiftUI
import WebKit

// The reader, shared by the Mac and the iPhone: a saved page's readable
// copy (made by the core with Readability), or a post — text, pictures,
// quote and the author's thread — laid out like an article. Offline: the
// pictures come from the media store through `wroopmark-media:`. The page
// runs no script of its own; ours lives in a separate content world and
// only reports how far the reader got.

// MARK: Settings

enum ReaderTheme: String, CaseIterable, Identifiable {
    case auto, light, sepia, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Otomatik"
        case .light: "Açık"
        case .sepia: "Sepya"
        case .dark: "Koyu"
        }
    }
}

enum ReaderWidth: String, CaseIterable, Identifiable {
    case narrow, normal, wide
    var id: String { rawValue }
    var label: String {
        switch self {
        case .narrow: "Dar"
        case .normal: "Normal"
        case .wide: "Geniş"
        }
    }
    var css: String {
        switch self {
        case .narrow: "560px"
        case .normal: "680px"
        case .wide: "860px"
        }
    }
}

// MARK: Document

/// The HTML the reader shows for an item.
enum ReaderDocument {
    static func html(for item: Item, article: String?, theme: ReaderTheme, serif: Bool, size: Int, width: ReaderWidth) -> String {
        let body = article.map { articleBody(item, $0) } ?? postBody(item)
        return """
        <!doctype html><html lang="tr" data-theme="\(theme.rawValue)" data-font="\(serif ? "serif" : "sans")" style="--size:\(size)px;--width:\(width.css)">
        <head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>\(css)</style></head><body><main>\(body)</main></body></html>
        """
    }

    /// Minutes to read, at 220 words a minute.
    static func minutes(_ text: String) -> Int {
        max(1, Int((Double(text.split(whereSeparator: \.isWhitespace).count) / 220).rounded()))
    }

    private static func header(_ item: Item, words: String) -> String {
        let site = item.author ?? URL(string: item.url)?.host() ?? ""
        let when = Date(timeIntervalSince1970: TimeInterval(item.createdAt ?? item.savedAt)).formatted(date: .abbreviated, time: .omitted)
        var h = "<div class=\"meta\">\(esc(site)) · \(esc(when)) · \(minutes(words)) dk okuma</div>"
        if let t = item.title, !t.isEmpty { h += "<h1>\(esc(t))</h1>" }
        return h
    }

    private static func articleBody(_ item: Item, _ html: String) -> String {
        header(item, words: item.text + " " + strip(html)) + "<article>\(html)</article>" + source(item)
    }

    /// A post (X, TikTok, …) as an article: its text, pictures, quote and
    /// the rest of its thread.
    private static func postBody(_ item: Item) -> String {
        let all = ([item.text] + item.thread.map(\.text) + [item.quote?.item.text ?? ""]).joined(separator: " ")
        var out = header(item, words: all)
        let threadFiles = Set(item.thread.flatMap(\.media).map(\.url))
        out += "<div class=\"post\">\(paragraphs(item.text))</div>"
        out += media(item.media.filter { !threadFiles.contains($0.url) })
        if let q = item.quote?.item {
            out += "<div class=\"quote\"><div class=\"meta\">\(esc(q.author ?? ""))</div>\(paragraphs(q.text))\(media(q.media))</div>"
        }
        for part in item.thread {
            let files = Set(part.media.map(\.url))
            out += "<div class=\"part\">\(paragraphs(part.text))\(media(item.media.filter { files.contains($0.url) }))</div>"
        }
        if let s = item.summary, !s.isEmpty {
            out += "<div class=\"summary\"><div class=\"meta\">Özet</div>\(paragraphs(s))</div>"
        }
        return out + source(item)
    }

    private static func source(_ item: Item) -> String {
        guard let u = URL(string: item.url), u.scheme?.hasPrefix("http") == true else { return "" }
        return "<p class=\"source\"><a href=\"\(esc(item.url))\">Kaynağında aç ↗</a></p>"
    }

    private static func media(_ media: [Media]) -> String {
        media.compactMap { m in
            guard let f = m.file else { return nil }
            let img = "<img src=\"wroopmark-media:///\(esc(f))\" alt=\"\(esc(m.alt ?? ""))\">"
            return m.isVideo ? "<figure>\(img)<figcaption>▶︎ Video: uygulamada oynatılır</figcaption></figure>" : "<figure>\(img)</figure>"
        }
        .joined()
    }

    /// Plain text as paragraphs, with its links clickable.
    private static func paragraphs(_ text: String) -> String {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "<p>\(linkify(esc($0)).replacingOccurrences(of: "\n", with: "<br>"))</p>" }
            .joined()
    }

    private static func linkify(_ escaped: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"https?://[^\s<]+"#) else { return escaped }
        let range = NSRange(escaped.startIndex..., in: escaped)
        return re.stringByReplacingMatches(in: escaped, range: range, withTemplate: "<a href=\"$0\">$0</a>")
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func strip(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    private static let css = """
    :root{--bg:#fbfbfd;--fg:#1d1d1f;--muted:#6e6e73;--link:#6b3fe6;--code:#f0f0f4;--line:rgba(0,0,0,.12);--font:ui-serif,"New York",Georgia,serif}
    html[data-theme=sepia]{--bg:#f6efe2;--fg:#3a2e21;--muted:#7a6a55;--link:#8a4b14;--code:#ece2cf;--line:rgba(90,60,20,.18)}
    html[data-theme=dark]{--bg:#121214;--fg:#e8e8ed;--muted:#98989f;--link:#a98bff;--code:#222226;--line:rgba(255,255,255,.14)}
    @media (prefers-color-scheme:dark){html[data-theme=auto]{--bg:#121214;--fg:#e8e8ed;--muted:#98989f;--link:#a98bff;--code:#222226;--line:rgba(255,255,255,.14)}}
    html[data-font=sans]{--font:-apple-system,system-ui,sans-serif}
    html{background:var(--bg)}
    body{margin:0;background:var(--bg);color:var(--fg);font:var(--size)/1.65 var(--font);-webkit-text-size-adjust:100%;word-wrap:break-word}
    main{max-width:var(--width);margin:0 auto;padding:28px 22px 140px}
    h1{font-size:1.75em;line-height:1.2;margin:.2em 0 .8em}
    h2{font-size:1.35em;line-height:1.25;margin-top:1.6em}h3{font-size:1.15em;margin-top:1.4em}
    p,li{margin:0 0 1em}
    a{color:var(--link);text-decoration:none}a:hover{text-decoration:underline}
    img,video{max-width:100%;height:auto;border-radius:10px;display:block;margin:.6em auto}
    figure{margin:1.2em 0}figcaption{color:var(--muted);font:14px/1.4 -apple-system,system-ui;text-align:center;margin-top:.3em}
    pre{background:var(--code);padding:14px 16px;border-radius:10px;overflow-x:auto;line-height:1.45}
    code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.84em}
    p code,li code{background:var(--code);padding:.1em .35em;border-radius:5px}
    blockquote{border-left:3px solid var(--link);margin:1.2em 0;padding:.1em 0 .1em 16px;color:var(--muted)}
    table{border-collapse:collapse;width:100%;font-size:.9em;display:block;overflow-x:auto}td,th{border:1px solid var(--line);padding:6px 8px}
    hr{border:0;border-top:1px solid var(--line);margin:2em 0}
    .meta{color:var(--muted);font:14px/1.4 -apple-system,system-ui;margin-bottom:10px}
    .quote{border:1px solid var(--line);border-radius:14px;padding:14px 16px;margin:1.4em 0}
    .part{margin-top:1.4em;padding-top:1.2em;border-top:1px solid var(--line)}
    .summary{background:var(--code);border-radius:12px;padding:12px 16px;margin-top:2em}
    .source{margin-top:2.5em;font:15px -apple-system,system-ui}
    """
}

// MARK: Pictures from the media store

/// Serves `wroopmark-media:///<name>` from the library's media store.
final class ReaderMediaScheme: NSObject, WKURLSchemeHandler {
    static let scheme = "wroopmark-media"

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let name = task.request.url?.lastPathComponent ?? ""
        let valid = name.range(of: #"^[0-9a-f]{8,64}\.[A-Za-z0-9]{1,6}$"#, options: .regularExpression) != nil
        guard valid, let url = task.request.url, let data = try? Data(contentsOf: Core.shared.mediaURL(name)) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let type = switch (name as NSString).pathExtension.lowercased() {
        case "png": "image/png"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "mp4": "video/mp4"
        default: "image/jpeg"
        }
        task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

// MARK: Web view

/// Reports how far the page is read (0…1); runs in its own content world,
/// so it works with the page's own scripts turned off.
private let progressScript = """
(() => {
  const post = () => {
    const h = document.documentElement, max = h.scrollHeight - innerHeight;
    window.webkit.messageHandlers.progress.postMessage(max > 0 ? Math.min(1, scrollY / max) : 1);
  };
  let t; addEventListener('scroll', () => { clearTimeout(t); t = setTimeout(post, 120); }, {passive: true});
  post();
})();
"""

final class ReaderCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var onProgress: (Double) -> Void = { _ in }
    var restore: Double = 0
    var loaded: String?
    static let world = WKContentWorld.world(name: "wroopmark-reader")

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let v = message.body as? Double { onProgress(v) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        guard restore > 0.02 else { return }
        let f = restore
        restore = 0
        webView.evaluateJavaScript("scrollTo(0, (document.documentElement.scrollHeight - innerHeight) * \(f))", in: nil, in: Self.world)
    }

    /// Links open in the browser, not in the reader.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        await UIApplication.shared.open(url)
        #endif
        return .cancel
    }

    static func makeWebView(_ c: ReaderCoordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.setURLSchemeHandler(ReaderMediaScheme(), forURLScheme: ReaderMediaScheme.scheme)
        let ucc = config.userContentController
        ucc.addUserScript(WKUserScript(source: progressScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        ucc.add(c, contentWorld: world, name: "progress")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = c
        #if os(macOS)
        web.setValue(false, forKey: "drawsBackground")
        #else
        web.isOpaque = false
        web.backgroundColor = .clear
        #endif
        return web
    }
}

#if os(macOS)
struct ReaderWeb: NSViewRepresentable {
    let html: String
    let restore: Double
    let onProgress: (Double) -> Void

    func makeCoordinator() -> ReaderCoordinator { ReaderCoordinator() }
    func makeNSView(context: Context) -> WKWebView { ReaderCoordinator.makeWebView(context.coordinator) }
    func updateNSView(_ web: WKWebView, context: Context) { update(web, context.coordinator) }
}
#else
struct ReaderWeb: UIViewRepresentable {
    let html: String
    let restore: Double
    let onProgress: (Double) -> Void

    func makeCoordinator() -> ReaderCoordinator { ReaderCoordinator() }
    func makeUIView(context: Context) -> WKWebView { ReaderCoordinator.makeWebView(context.coordinator) }
    func updateUIView(_ web: WKWebView, context: Context) { update(web, context.coordinator) }
}
#endif

extension ReaderWeb {
    fileprivate func update(_ web: WKWebView, _ c: ReaderCoordinator) {
        c.onProgress = onProgress
        guard c.loaded != html else { return }
        // A settings change keeps the place on the page.
        if c.loaded == nil { c.restore = restore }
        c.loaded = html
        web.loadHTMLString(html, baseURL: URL(string: "about:blank"))
    }
}

// MARK: Speech

/// Reads the text aloud with the device's voice for its language.
@MainActor
@Observable
final class ReaderSpeech: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private(set) var speaking = false
    private(set) var paused = false

    override init() {
        super.init()
        synth.delegate = self
    }

    func toggle(_ text: String) {
        if synth.isSpeaking {
            if synth.isPaused { synth.continueSpeaking() } else { synth.pauseSpeaking(at: .word) }
            paused = synth.isPaused
            return
        }
        let u = AVSpeechUtterance(string: text)
        let lang = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? "tr"
        u.voice = AVSpeechSynthesisVoice(language: lang)
        synth.speak(u)
        speaking = true
        paused = false
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        speaking = false
        paused = false
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in
            self.speaking = false
            self.paused = false
        }
    }
}

// MARK: View

struct ReaderView: View {
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var item: Item?
    @State private var article: String?
    @State private var progress: Double = 0
    @State private var speech = ReaderSpeech()
    @AppStorage("readerTheme") private var theme: ReaderTheme = .auto
    @AppStorage("readerSerif") private var serif = true
    @AppStorage("readerSize") private var size = 19
    @AppStorage("readerWidth") private var width: ReaderWidth = .normal

    private struct ArticleReply: Decodable, Sendable { let html: String? }

    var body: some View {
        NavigationStack {
            Group {
                if let item {
                    ReaderWeb(
                        html: ReaderDocument.html(for: item, article: article, theme: theme, serif: serif, size: size, width: width),
                        restore: Self.position(id),
                        onProgress: { p in
                            progress = p
                            Self.remember(id, p)
                        }
                    )
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView()
                }
            }
            .background(background.ignoresSafeArea())
            .safeAreaInset(edge: .top, spacing: 0) {
                ProgressView(value: progress).progressViewStyle(.linear).tint(.accentColor).frame(height: 2)
            }
            .navigationTitle(item?.title ?? item?.author ?? "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { speech.toggle(spokenText) } label: {
                        Image(systemName: speech.speaking && !speech.paused ? "pause.circle" : "speaker.wave.2")
                    }
                    .help("Sesli oku")
                    .accessibilityLabel(speech.speaking && !speech.paused ? "Duraklat" : "Sesli oku")
                    .disabled(item == nil)
                    settingsMenu
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 640)
        #endif
        .task { await load() }
        .onDisappear { speech.stop() }
    }

    private var settingsMenu: some View {
        Menu {
            Picker("Tema", selection: $theme) {
                ForEach(ReaderTheme.allCases) { Text($0.label).tag($0) }
            }
            Picker("Yazı", selection: $serif) {
                Text("Serif").tag(true)
                Text("Sans").tag(false)
            }
            Picker("Genişlik", selection: $width) {
                ForEach(ReaderWidth.allCases) { Text($0.label).tag($0) }
            }
            Button("Büyüt", systemImage: "textformat.size.larger") { size = min(28, size + 1) }
            Button("Küçült", systemImage: "textformat.size.smaller") { size = max(13, size - 1) }
        } label: {
            Image(systemName: "textformat.size")
        }
        .help("Görünüm")
        .accessibilityLabel("Görünüm")
    }

    private var background: Color {
        switch theme {
        case .sepia: Color(red: 0.965, green: 0.937, blue: 0.886)
        case .dark: Color(red: 0.07, green: 0.07, blue: 0.08)
        case .light: Color(red: 0.984, green: 0.984, blue: 0.992)
        case .auto: Color.clear
        }
    }

    private var spokenText: String {
        guard let item else { return "" }
        if let a = article { return [item.title ?? "", ReaderDocument.strip(a)].joined(separator: ". ") }
        return ([item.text] + item.thread.map(\.text)).joined(separator: "\n\n")
    }

    private func load() async {
        item = try? await Core.shared.call(.get(id: id))
        let reply: ArticleReply? = try? await Core.shared.call(.call("article", ["id": .string(id)]))
        article = reply?.html
    }

    // Where each item was left (this device only).
    private static func position(_ id: String) -> Double {
        (UserDefaults.standard.dictionary(forKey: "readerPositions") as? [String: Double])?[id] ?? 0
    }

    private static func remember(_ id: String, _ p: Double) {
        var all = UserDefaults.standard.dictionary(forKey: "readerPositions") as? [String: Double] ?? [:]
        all[id] = p > 0.97 ? nil : p
        if all.count > 300 { all.removeValue(forKey: all.keys.first ?? "") }
        UserDefaults.standard.set(all, forKey: "readerPositions")
    }
}
