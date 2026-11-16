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
        let all = ([item.text] + item.thread.map(\.text) + item.replies.map(\.text) + [item.quote?.item.text ?? ""]).joined(separator: " ")
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
        if !item.replies.isEmpty {
            out += "<h2>Yanıtlar</h2>"
            for r in item.replies {
                out += "<div class=\"part\"><div class=\"meta\">\(esc(r.author ?? ""))</div>\(paragraphs(r.text))</div>"
            }
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
    mark{background:rgba(255,214,10,.42);color:inherit;border-radius:3px;padding:0 1px}
    mark[data-c=green]{background:rgba(52,199,89,.34)}mark[data-c=blue]{background:rgba(10,132,255,.3)}mark[data-c=pink]{background:rgba(255,55,95,.28)}
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

// MARK: Highlights

struct ReaderHighlight: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let quote: String
    var prefix: String = ""
    var note: String?
    var color: String = "yellow"
    var at: Int64 = 0

    static let colors = ["yellow", "green", "blue", "pink"]

    static func swatch(_ c: String) -> Color {
        switch c {
        case "green": Color(red: 0.2, green: 0.78, blue: 0.35)
        case "blue": Color(red: 0.04, green: 0.52, blue: 1)
        case "pink": Color(red: 1, green: 0.22, blue: 0.37)
        default: Color(red: 1, green: 0.84, blue: 0.04)
        }
    }
}

/// Text the reader has selected: the passage and the words just before it,
/// both cut from the same flattened text the marks are found in.
struct ReaderSelection: Equatable {
    let quote: String
    let prefix: String
}

// MARK: Web view

/// Our script, in its own content world (the page's scripts stay off):
/// reports how far the page is read and what is selected, finds and marks
/// highlights, and says which mark was tapped.
private let readerScript = """
(() => {
  const post = (name, v) => window.webkit.messageHandlers[name].postMessage(v);
  const root = () => document.querySelector('main') || document.body;
  const nodes = () => { const w = document.createTreeWalker(root(), NodeFilter.SHOW_TEXT); const out = []; let n; while ((n = w.nextNode())) out.push(n); return out; };
  const flat = (ns) => { let s = ''; const map = []; for (const n of ns) { map.push([n, s.length]); s += n.data; } return [s, map]; };

  const mark = (h) => {
    const ns = nodes(), [s, map] = flat(ns);
    let at = h.prefix ? s.indexOf(h.prefix + h.quote) : -1;
    if (at >= 0) at += h.prefix.length; else at = s.indexOf(h.quote);
    if (at < 0 || !h.quote) return;
    const end = at + h.quote.length;
    for (const [n, off] of map) {
      const ne = off + n.data.length;
      if (ne <= at || off >= end) continue;
      let node = n; const a = Math.max(at, off) - off, b = Math.min(end, ne) - off;
      if (b < node.data.length) node.splitText(b);
      if (a > 0) node = node.splitText(a);
      const m = document.createElement('mark'); m.dataset.h = h.id; m.dataset.c = h.color || 'yellow';
      node.parentNode.insertBefore(m, node); m.appendChild(node);
    }
  };
  window.__wm = {
    apply: (list) => list.forEach(mark),
    remove: (id) => { document.querySelectorAll('mark[data-h="' + id + '"]').forEach(m => m.replaceWith(...m.childNodes)); root().normalize(); },
    color: (id, c) => document.querySelectorAll('mark[data-h="' + id + '"]').forEach(m => m.dataset.c = c),
    show: (id) => { const m = document.querySelector('mark[data-h="' + id + '"]'); if (m) m.scrollIntoView({block: 'center', behavior: 'smooth'}); },
    clear: () => getSelection().removeAllRanges(),
  };

  let t; addEventListener('scroll', () => { clearTimeout(t); t = setTimeout(() => {
    const h = document.documentElement, max = h.scrollHeight - innerHeight;
    post('progress', max > 0 ? Math.min(1, scrollY / max) : 1);
  }, 120); }, {passive: true});
  post('progress', 0);

  let st; document.addEventListener('selectionchange', () => { clearTimeout(st); st = setTimeout(() => {
    const sel = getSelection();
    if (!sel || sel.isCollapsed || !root().contains(sel.anchorNode)) { post('selection', ''); return; }
    const r = sel.getRangeAt(0), [s, map] = flat(nodes());
    const pos = (c, o) => { for (const [n, off] of map) if (n === c) return off + o; return -1; };
    const a = pos(r.startContainer, r.startOffset), b = pos(r.endContainer, r.endOffset);
    if (a < 0 || b <= a) { post('selection', JSON.stringify({quote: sel.toString().trim(), prefix: ''})); return; }
    post('selection', JSON.stringify({quote: s.slice(a, b), prefix: s.slice(Math.max(0, a - 32), a)}));
  }, 250); });

  document.addEventListener('click', (e) => {
    const m = e.target.closest && e.target.closest('mark[data-h]');
    if (m && getSelection().isCollapsed) post('mark', m.dataset.h);
  });
})();
"""

/// What SwiftUI uses to talk to the page.
@MainActor
final class ReaderBridge {
    weak var web: WKWebView?

    func run(_ js: String) {
        web?.evaluateJavaScript(js, in: nil, in: ReaderCoordinator.world) { _ in }
    }

    func apply(_ list: [ReaderHighlight]) {
        guard let data = try? JSONEncoder().encode(list), let json = String(data: data, encoding: .utf8) else { return }
        run("__wm.apply(\(json))")
    }

    func remove(_ id: String) { run("__wm.remove(\(Self.quoted(id)))") }
    func color(_ id: String, _ c: String) { run("__wm.color(\(Self.quoted(id)), \(Self.quoted(c)))") }
    func show(_ id: String) { run("__wm.show(\(Self.quoted(id)))") }
    func clearSelection() { run("__wm.clear()") }

    private static func quoted(_ s: String) -> String {
        (try? String(data: JSONEncoder().encode(s), encoding: .utf8)) ?? "\"\""
    }
}

final class ReaderCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var onProgress: (Double) -> Void = { _ in }
    var onSelection: (ReaderSelection?) -> Void = { _ in }
    var onMark: (String) -> Void = { _ in }
    var highlights: [ReaderHighlight] = []
    var restore: Double = 0
    var loaded: String?
    weak var bridge: ReaderBridge?
    static let world = WKContentWorld.world(name: "wroopmark-reader")

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "progress":
            if let v = message.body as? Double { onProgress(v) }
        case "selection":
            let text = message.body as? String ?? ""
            let sel = text.data(using: .utf8).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
            if let q = sel?["quote"], !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onSelection(ReaderSelection(quote: q, prefix: sel?["prefix"] ?? ""))
            } else {
                onSelection(nil)
            }
        case "mark":
            if let id = message.body as? String { onMark(id) }
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        MainActor.assumeIsolated { bridge?.apply(highlights) }
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
        ucc.addUserScript(WKUserScript(source: readerScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        for name in ["progress", "selection", "mark"] {
            ucc.add(c, contentWorld: world, name: name)
        }
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
    let highlights: [ReaderHighlight]
    let bridge: ReaderBridge
    let onProgress: (Double) -> Void
    let onSelection: (ReaderSelection?) -> Void
    let onMark: (String) -> Void

    func makeCoordinator() -> ReaderCoordinator { ReaderCoordinator() }
    func makeNSView(context: Context) -> WKWebView { ReaderCoordinator.makeWebView(context.coordinator) }
    func updateNSView(_ web: WKWebView, context: Context) { update(web, context.coordinator) }
}
#else
struct ReaderWeb: UIViewRepresentable {
    let html: String
    let restore: Double
    let highlights: [ReaderHighlight]
    let bridge: ReaderBridge
    let onProgress: (Double) -> Void
    let onSelection: (ReaderSelection?) -> Void
    let onMark: (String) -> Void

    func makeCoordinator() -> ReaderCoordinator { ReaderCoordinator() }
    func makeUIView(context: Context) -> WKWebView { ReaderCoordinator.makeWebView(context.coordinator) }
    func updateUIView(_ web: WKWebView, context: Context) { update(web, context.coordinator) }
}
#endif

extension ReaderWeb {
    fileprivate func update(_ web: WKWebView, _ c: ReaderCoordinator) {
        c.onProgress = onProgress
        c.onSelection = onSelection
        c.onMark = onMark
        c.highlights = highlights
        c.bridge = bridge
        bridge.web = web
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
    /// Called after a highlight is added, changed or removed, so the app
    /// can send it to its other devices soon (set by the app's model).
    @MainActor static var onEdit: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var item: Item?
    @State private var article: String?
    @State private var progress: Double = 0
    @State private var speech = ReaderSpeech()
    @State private var bridge = ReaderBridge()
    @State private var highlights: [ReaderHighlight] = []
    @State private var selection: ReaderSelection?
    @State private var editing: ReaderHighlight?
    @State private var showList = false
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
                        highlights: highlights,
                        bridge: bridge,
                        onProgress: { p in
                            progress = p
                            Self.remember(id, p)
                        },
                        onSelection: { selection = $0 },
                        onMark: { hid in editing = highlights.first { $0.id == hid } }
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
            .overlay(alignment: .bottom) {
                if let sel = selection {
                    HStack(spacing: 10) {
                        Button { Task { await add(sel, note: false) } } label: { Label("Vurgula", systemImage: "highlighter") }
                        Button { Task { await add(sel, note: true) } } label: { Label("Not ekle", systemImage: "note.text.badge.plus") }
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(10)
                    .background(.regularMaterial, in: .capsule)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: selection)
            .navigationTitle(item?.title ?? item?.author ?? "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showList = true } label: {
                        Label("Vurgular", systemImage: highlights.isEmpty ? "highlighter" : "list.bullet.rectangle")
                    }
                    .help("Vurgular ve notlar")
                    .disabled(highlights.isEmpty)
                    Button { speech.toggle(spokenText) } label: {
                        Image(systemName: speech.speaking && !speech.paused ? "pause.circle" : "speaker.wave.2")
                    }
                    .help("Sesli oku")
                    .accessibilityLabel(speech.speaking && !speech.paused ? "Duraklat" : "Sesli oku")
                    .disabled(item == nil)
                    settingsMenu
                }
            }
            .sheet(item: $editing) { h in
                HighlightEditor(highlight: h) { change in Task { await apply(change, to: h) } }
            }
            .sheet(isPresented: $showList) {
                HighlightList(highlights: highlights) { h in
                    showList = false
                    bridge.show(h.id)
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
        highlights = (try? await Core.shared.call(.call("highlights", ["id": .string(id)]))) ?? []
    }

    // MARK: Highlights

    enum Change {
        case note(String)
        case color(String)
        case delete
    }

    private func add(_ sel: ReaderSelection, note: Bool) async {
        selection = nil
        bridge.clearSelection()
        let before = Set(highlights.map(\.id))
        guard let list: [ReaderHighlight] = try? await Core.shared.call(.call("highlight", [
            "id": .string(id), "quote": .string(sel.quote), "prefix": .string(sel.prefix),
        ])) else { return }
        highlights = list
        Self.onEdit?()
        let added = list.filter { !before.contains($0.id) }
        bridge.apply(added)
        if note { editing = added.first }
    }

    private func apply(_ change: Change, to h: ReaderHighlight) async {
        var args: [String: CoreArg] = ["id": .string(id), "hid": .string(h.id)]
        switch change {
        case .note(let n): args["note"] = .string(n)
        case .color(let c): args["color"] = .string(c)
        case .delete: args["delete"] = .bool(true)
        }
        guard let list: [ReaderHighlight] = try? await Core.shared.call(.call("highlight", args)) else { return }
        highlights = list
        Self.onEdit?()
        switch change {
        case .color(let c): bridge.color(h.id, c)
        case .delete: bridge.remove(h.id)
        case .note: break
        }
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

/// One highlight: its passage, a note, a color, or remove it.
private struct HighlightEditor: View {
    @Environment(\.dismiss) private var dismiss
    let highlight: ReaderHighlight
    let change: (ReaderView.Change) -> Void
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(highlight.quote).font(.callout).italic()
                }
                Section("Not") {
                    TextField("Bu bölüm hakkında…", text: $note, axis: .vertical).lineLimit(3...8)
                }
                Section("Renk") {
                    HStack(spacing: 14) {
                        ForEach(ReaderHighlight.colors, id: \.self) { c in
                            Button { change(.color(c)) } label: {
                                Circle().fill(ReaderHighlight.swatch(c)).frame(width: 28, height: 28)
                                    .overlay { if c == highlight.color { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) } }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(c)
                        }
                    }
                }
                Section {
                    Button("Vurguyu kaldır", role: .destructive) {
                        change(.delete)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Vurgu")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bitti") {
                        if note != (highlight.note ?? "") { change(.note(note)) }
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
        .onAppear { note = highlight.note ?? "" }
    }
}

/// All highlights of the item; choosing one scrolls to it.
private struct HighlightList: View {
    @Environment(\.dismiss) private var dismiss
    let highlights: [ReaderHighlight]
    let open: (ReaderHighlight) -> Void

    var body: some View {
        NavigationStack {
            List(highlights) { h in
                Button { open(h) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(ReaderHighlight.swatch(h.color)).frame(width: 4)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(h.quote).font(.callout).lineLimit(4)
                            if let n = h.note, !n.isEmpty { Text(n).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Vurgular")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Kapat") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }
}
