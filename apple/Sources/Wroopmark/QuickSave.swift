import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Saving a link without opening the window: ⌃⌥⌘S anywhere saves the link
/// on the clipboard, the menu bar icon takes one by hand. A small banner
/// says how it went.
@MainActor
final class QuickSave {
    static let shared = QuickSave()

    private weak var model: AppModel?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var banner: NSPanel?
    private var hideTask: Task<Void, Never>?

    static let hotKeyLabel = "⌃⌥⌘S"
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    var hotKeyEnabled: Bool { UserDefaults.standard.object(forKey: "quickSaveHotKey") as? Bool ?? true }

    func attach(_ model: AppModel) {
        self.model = model
        setHotKey(hotKeyEnabled)
    }

    /// A Carbon hot key: global, and needs no accessibility permission.
    func setHotKey(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "quickSaveHotKey")
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        guard on else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in await QuickSave.shared.saveClipboard() }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x776D_726B), id: 1) // "wmrk"
        RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(cmdKey | optionKey | controlKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    /// The first web link on the clipboard, if any.
    static func clipboardURL() -> String? {
        let pb = NSPasteboard.general
        let text = pb.string(forType: .URL) ?? pb.string(forType: .string) ?? ""
        return firstURL(in: text)
    }

    static func firstURL(in text: String) -> String? {
        guard !text.isEmpty, let detector = linkDetector else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range)
            .compactMap(\.url)
            .first { $0.scheme == "http" || $0.scheme == "https" }?
            .absoluteString
    }

    func saveClipboard() async {
        guard let link = Self.clipboardURL() else {
            show(symbol: "doc.on.clipboard", title: "Panoda link yok", detail: "Bir bağlantı kopyala, sonra \(Self.hotKeyLabel)")
            return
        }
        let folder = UserDefaults.standard.integer(forKey: "quickAddFolder")
        await save(link, folderID: folder == 0 ? nil : Int64(folder))
    }

    /// Saves a link with its media, as "add link" in the app does.
    @discardableResult
    func save(_ link: String, tags: [String] = [], folderID: Int64? = nil) async -> Bool {
        show(symbol: "arrow.down.circle", title: "Kaydediliyor…", detail: link, stay: true)
        let client: any CoreClient = model?.core ?? Core.shared
        do {
            let item: Item = try await client.call(.addURL(url: link, tags: tags, note: nil, folderID: folderID), network: true)
            let title = item.title ?? item.text.split(separator: "\n").first.map(String.init) ?? item.url
            show(symbol: "checkmark.circle.fill", title: "Kaydedildi", detail: String(title.prefix(90)))
            if let model {
                await model.refreshLoaded()
                await model.loadRecent()
            }
            if model?.enableSystemIntegrations ?? true {
                Spotlight.indexRecent(core: client)
            }
            return true
        } catch {
            show(symbol: "exclamationmark.triangle.fill", title: "Kaydedilemedi", detail: error.localizedDescription)
            return false
        }
    }

    // MARK: Banner

    private func show(symbol: String, title: String, detail: String, stay: Bool = false) {
        let panel = banner ?? makeBanner()
        banner = panel
        panel.contentView = NSHostingView(rootView: Banner(symbol: symbol, title: title, detail: detail))
        if let screen = NSScreen.main {
            let size = NSSize(width: 380, height: 64)
            let f = screen.visibleFrame
            panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height - 24, width: size.width, height: size.height), display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideTask?.cancel()
        guard !stay else { return }
        hideTask = Task { [weak panel] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled, let panel else { return }
            await NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 0 }
            panel.orderOut(nil)
        }
    }

    private func makeBanner() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return p
    }
}

private struct Banner: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.md))
    }
}

/// The menu bar icon's panel: save a link, see the newest saves.
struct QuickAddMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("quickAddFolder") private var folderID = 0
    @State private var link = ""
    @State private var tags = ""
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Hızlı kaydet").font(.headline)
            TextField("https://…", text: $link)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            TextField("etiketler (virgülle)", text: $tags)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Picker("Klasör", selection: $folderID) {
                Text("Klasörsüz").tag(0)
                ForEach(FolderNode.flattened(model.folderTree).filter { $0.folder != nil }) { node in
                    Text(node.displayPath).tag(Int(node.folder?.id ?? 0))
                }
            }
            HStack(spacing: Theme.Spacing.sm) {
                Text("\(QuickSave.hotKeyLabel): panodaki linki kaydet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Theme.Spacing.sm)
                Button(action: save) {
                    Label("Kaydet", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
                .disabled(QuickSave.firstURL(in: link) == nil || saving)
            }

            if !model.recentItems.isEmpty {
                Divider()
                Label("Son kaydedilenler", systemImage: "clock")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                VStack(spacing: Theme.Spacing.xs) {
                    ForEach(model.recentItems.prefix(5)) { item in
                        RecentSaveRow(item: item) {
                            model.reveal(id: item.id)
                            openMain()
                        }
                    }
                }
            }

            Divider()
            HStack(spacing: Theme.Spacing.sm) {
                Button(action: openMain) {
                    Label("wroopmark'ı aç", systemImage: "macwindow")
                }
                Spacer()
                Button { NSApp.terminate(nil) } label: {
                    Label("Çık", systemImage: "power")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 340)
        .task {
            if link.isEmpty, let c = QuickSave.clipboardURL() { link = c }
            await model.loadRecent()
        }
    }

    private func save() {
        guard let url = QuickSave.firstURL(in: link), !saving else { return }
        saving = true
        let picked = parseTags(tags)
        let folder = folderID == 0 ? nil : Int64(folderID)
        Task {
            if await QuickSave.shared.save(url, tags: picked, folderID: folder) {
                link = ""
                tags = ""
            }
            saving = false
        }
    }

    private func openMain() {
        // The menu bar panel is the key window while it is open.
        NSApp.windows.first { $0.isKeyWindow && $0.className.contains("MenuBarExtra") }?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.windows.contains(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }) {
            openWindow(id: "main")
        }
    }
}

/// A recent save in the menu bar panel; plain until hovered.
private struct RecentSaveRow: View {
    let item: Item
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(nsImage: FolderIcons.image(forPlatform: Platform(rawValue: item.platform) ?? .web))
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.secondary)
                Text(item.title ?? (item.text.isEmpty ? item.url : item.text))
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(Theme.Spacing.sm)
            .background(
                hovering ? Theme.Stroke.subtleFill : .clear,
                in: .rect(cornerRadius: Theme.Radius.sm)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .strokeBorder(hovering ? Theme.Stroke.surfaceBorder : .clear, lineWidth: Theme.Stroke.hairlineWidth)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
