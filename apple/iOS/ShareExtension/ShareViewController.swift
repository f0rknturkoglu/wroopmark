import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Paylaş → wroopmark: the link is stored at once (no network, so the
/// sheet never waits); the app fetches the text and pictures when it opens.
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
        case failed(String)
    }

    @State private var phase: Phase = .saving
    @State private var savedID: String?
    @State private var link = ""
    @State private var tags = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    switch phase {
                    case .saving:
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
                        Text("Metin ve görseller wroopmark'ı açınca gelir.")
                    }
                }
                if case .saved = phase {
                    Section {
                        TextField("Etiketler (virgülle)", text: $tags)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Not", text: $note, axis: .vertical)
                            .lineLimit(1...4)
                    }
                }
            }
            .navigationTitle("wroopmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bitti") { Task { await finish() } }
                        .disabled(phase == .saving)
                }
            }
        }
        .task { await save() }
    }

    private func save() async {
        guard let (url, title) = await sharedLink() else {
            phase = .failed("Paylaşılan şeyde bağlantı yok")
            return
        }
        link = url.absoluteString
        struct Saved: Decodable, Sendable {
            let id: String
            let new: Bool
        }
        do {
            let r: Saved = try await Core.shared.call(.call("save_link", ["url": .string(url.absoluteString), "title": title.map(CoreArg.string) ?? .null]))
            savedID = r.id
            phase = .saved(new: r.new)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func finish() async {
        if let id = savedID {
            let add = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")) }.filter { !$0.isEmpty }
            if !add.isEmpty { _ = try? await Core.shared.run(.editTags(ids: [id], add: add, remove: [])) }
            let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty { _ = try? await Core.shared.run(.setNote(id: id, note: n)) }
        }
        await Core.shared.checkpointForQuit()
        context?.completeRequest(returningItems: nil)
    }

    /// The URL in what was shared: a web URL, or the first link in text
    /// (X and others share "text … https://…"). With the page title if given.
    private func sharedLink() async -> (URL, String?)? {
        let items = context?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let title = items.first?.attributedContentText?.string
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
               url.scheme?.hasPrefix("http") == true {
                return (url, title)
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
               let url = Self.firstLink(in: text) {
                return (url, nil)
            }
        }
        return nil
    }

    private static func firstLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url).first { $0.scheme?.hasPrefix("http") == true }
    }
}
