import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Paylaş → wroopmark: the link is stored at once (no network, so the
/// sheet never waits); the app fetches the text and pictures when it opens.
/// A video or picture the user has (saved from the app, a screen
/// recording, a photo) is put on its post: the one shared with it, the one
/// its file name points to, or one the user picks.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(context: extensionContext))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

private struct ShareView: View {
    let context: NSExtensionContext?

    enum Phase: Equatable {
        case saving
        case saved(new: Bool)
        /// Files came without a link: which post are they of?
        case choosing
        case failed(String)
    }

    @State private var phase: Phase = .saving
    @State private var savedID: String?
    @State private var link = ""
    @State private var tags = ""
    @State private var note = ""
    @State private var folderID: Int64?
    @State private var folders: [Folder] = []
    @State private var topTags: [TagCount] = []
    @State private var selectedQuote: String?
    @State private var saveQuoteHighlight = true
    @State private var files: [URL] = []
    @State private var candidates: [Item] = []
    @State private var attaching = false

    private var hasVideo: Bool { files.contains { Self.isVideo($0) } }

    private var parsedTags: [String] {
        tags.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                if phase == .choosing {
                    choosing
                } else {
                    status
                }
                if case .saved = phase {
                    if let q = selectedQuote, !q.isEmpty {
                        Section("Seçili metin") {
                            Toggle("Vurgu olarak kaydet", isOn: $saveQuoteHighlight)
                            Text("“\(q)”")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    Section {
                        if !folders.isEmpty {
                            Picker("Klasör", selection: $folderID) {
                                Text("Klasör yok").tag(Int64?.none)
                                ForEach(folders) { f in
                                    Text(f.name.replacingOccurrences(of: "/", with: " › ")).tag(Int64?.some(f.id))
                                }
                            }
                        }
                        TextField("Etiketler (virgülle)", text: $tags)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !topTags.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(topTags.prefix(10), id: \.key) { t in
                                        Button("#\(t.name)") {
                                            var cur = parsedTags
                                            if !cur.contains(t.name) {
                                                cur.append(t.name)
                                                tags = cur.joined(separator: ", ")
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                    }
                                }
                            }
                        }
                        TextField("Not", text: $note, axis: .vertical)
                            .lineLimit(1...4)
                    }
                }
            }
            .navigationTitle("wroopmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if phase == .choosing {
                        Button("Vazgeç") { Task { await close() } }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if phase != .choosing {
                        Button("Bitti") { Task { await finish() } }
                            .disabled(phase == .saving)
                    }
                }
            }
        }
        .task {
            async let meta: Void = loadMeta()
            await save()
            _ = await meta
        }
    }

    @ViewBuilder
    private var status: some View {
        Section {
            switch phase {
            case .saving, .choosing:
                HStack { ProgressView(); Text("Kaydediliyor…") }
            case .saved(let new):
                Label(new ? "wroopmark'a kaydedildi" : "Zaten arşivdeydi", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if !link.isEmpty {
                Text(link).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        } footer: {
            if case .saved = phase {
                Text(files.isEmpty ? "Metin ve görseller wroopmark'ı açınca gelir." : "Dosya gönderisine eklendi; internetsiz de açılır.")
            }
        }
    }

    @ViewBuilder
    private var choosing: some View {
        Section {
            ForEach(candidates) { item in
                Button { Task { await attach(to: item) } } label: {
                    CandidateRow(item: item)
                }
                .buttonStyle(.plain)
                .disabled(attaching)
            }
        } header: {
            Text(hasVideo ? "Bu video hangi gönderinin?" : "Bu görsel hangi gönderinin?")
        } footer: {
            Text(hasVideo
                ? "Videosu telefonda olmayan son kayıtlar. Gönderiyi önce bağlantısıyla kaydettiysen burada çıkar."
                : "Son kaydedilenler.")
        }
        Section {
            Button {
                Task { await saveAsNew() }
            } label: {
                Label("Yeni kayıt olarak kaydet", systemImage: "plus.circle")
            }
            .disabled(attaching)
        }
    }

    // MARK: Saving

    private struct Saved: Decodable, Sendable {
        let id: String
        let new: Bool
    }

    private func loadMeta() async {
        folders = (try? await Core.shared.call(.folders)) ?? []
        topTags = ((try? await Core.shared.call(.tags)) ?? []).sorted { $0.count > $1.count }
    }

    private func save() async {
        let shared = await sharedContent()
        files = shared.files
        selectedQuote = shared.quote
        guard let (url, title) = shared.link else {
            if let textNote = shared.note, files.isEmpty {
                do {
                    let saved: Item = try await Core.shared.call(.call("add_note", ["text": .string(textNote)]))
                    savedID = saved.id
                    link = textNote
                    selectedQuote = nil
                    phase = .saved(new: true)
                } catch {
                    phase = .failed(error.localizedDescription)
                }
                return
            }
            if files.isEmpty {
                phase = .failed(String(localized: "Paylaşılan şeyde bağlantı yok"))
            } else {
                await chooseOrMatch()
            }
            return
        }
        link = url.absoluteString
        do {
            let r: Saved = try await Core.shared.call(.call("save_link", ["url": .string(url.absoluteString), "title": title.map(CoreArg.string) ?? .null]))
            savedID = r.id
            for f in files {
                _ = try? await Core.shared.call(.call("attach_file", ["id": .string(r.id), "path": .string(f.path)])) as Bool
            }
            phase = .saved(new: r.new)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// A file named after its post (an old TikTok download) finds it on its
    /// own; otherwise the user picks the post.
    private func chooseOrMatch() async {
        if files.allSatisfy({ Self.namesItsPost($0) }) {
            await saveAsNew()
            return
        }
        if hasVideo {
            candidates = (try? await Core.shared.call(.call("needs_video", ["limit": .int(30)]))) ?? []
        }
        if candidates.isEmpty {
            let recent: SearchResult? = try? await Core.shared.call(.search(q: "", sort: "saved", limit: 20, offset: 0))
            candidates = recent?.items ?? []
        }
        phase = candidates.isEmpty ? .saving : .choosing
        if candidates.isEmpty { await saveAsNew() }
    }

    private func attach(to item: Item) async {
        attaching = true
        defer { attaching = false }
        for f in files {
            _ = try? await Core.shared.call(.call("attach_file", ["id": .string(item.id), "path": .string(f.path)])) as Bool
        }
        savedID = item.id
        link = item.headline
        phase = .saved(new: false)
    }

    /// Each file becomes a post of its own (or joins the post its name points to).
    private func saveAsNew() async {
        attaching = true
        defer { attaching = false }
        do {
            let r: FilesReport = try await Core.shared.call(.call("import_files", ["paths": .strings(files.map(\.path))]))
            phase = .saved(new: r.new > 0)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func finish() async {
        if let id = savedID {
            let add = parsedTags
            if !add.isEmpty { _ = try? await Core.shared.run(.editTags(ids: [id], add: add, remove: [])) }
            if let folderID { _ = try? await Core.shared.run(.moveToFolder(id: id, folderID: folderID)) }
            let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty { _ = try? await Core.shared.run(.setNote(id: id, note: n)) }
            if saveQuoteHighlight, let q = selectedQuote, !q.isEmpty {
                struct HighlightRef: Decodable { let id: String }
                let _: [HighlightRef]? = try? await Core.shared.call(.call("highlight", ["id": .string(id), "quote": .string(q)]))
            }
        }
        await close()
    }

    private func close() async {
        await Core.shared.checkpointForQuit()
        for f in files { try? FileManager.default.removeItem(at: f) }
        context?.completeRequest(returningItems: nil)
    }

    // MARK: What was shared

    private struct Shared {
        var link: (URL, String?)?
        var note: String?
        var quote: String?
        var files: [URL] = []
    }

    /// The URL in what was shared (a web URL, or the first link in text:
    /// X and others share "text … https://…"), optional selected quote text
    /// or pure note text, and copies of any attached media files.
    private func sharedContent() async -> Shared {
        let items = context?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let title = items.first?.attributedContentText?.string
        var out = Shared()
        var texts: [String] = []
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if let type = [UTType.movie, .image].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }),
               let file = await Self.copy(provider, type: type) {
                out.files.append(file)
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
               url.scheme?.hasPrefix("http") == true,
               out.link == nil {
                out.link = (url, title)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { texts.append(clean) }
                if out.link == nil, let url = Self.firstLink(in: text) {
                    out.link = (url, nil)
                }
            }
        }
        let rawText = texts.joined(separator: "\n")
        if let (u, _) = out.link {
            let stripped = rawText
                .replacingOccurrences(of: u.absoluteString, with: "")
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
            if stripped.count >= 8 && stripped != title {
                out.quote = stripped
            }
        } else if !rawText.isEmpty {
            out.note = rawText
        } else if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, out.link == nil {
            out.note = t
        }
        return out
    }

    /// The shared file is only readable inside the callback: copy it to our
    /// temporary folder, keeping its name and extension.
    private static func copy(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { cont in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { return cont.resume(returning: nil) }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var name = url.lastPathComponent
                if URL(fileURLWithPath: name).pathExtension.isEmpty, let ext = type.preferredFilenameExtension { name += ".\(ext)" }
                let dst = dir.appendingPathComponent(name)
                do {
                    try FileManager.default.copyItem(at: url, to: dst)
                    cont.resume(returning: dst)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private static func isVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
    }

    /// TikTok downloads carry the post's number in the name (19 digits).
    private static func namesItsPost(_ url: URL) -> Bool {
        url.lastPathComponent.range(of: #"\d{18,20}"#, options: .regularExpression) != nil
    }

    private static func firstLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url).first { $0.scheme?.hasPrefix("http") == true }
    }
}

/// A post to choose: its picture, who, and the start of its text.
private struct CandidateRow: View {
    let item: Item

    var body: some View {
        HStack(spacing: 12) {
            Thumb(file: item.cover?.file)
                .frame(width: 56, height: 56)
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.author ?? Platform(rawValue: item.platform)?.label ?? item.platform)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(item.headline)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }
}

/// A small picture from the media store, decoded at the size it is shown.
private struct Thumb: View {
    let file: String?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
        }
        .task(id: file) {
            guard let file else { return }
            let url = Core.shared.mediaURL(file)
            image = await Task.detached(priority: .userInitiated) {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as UIImage? }
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 168,
                ]
                return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary).map { UIImage(cgImage: $0) }
            }.value
        }
    }
}
