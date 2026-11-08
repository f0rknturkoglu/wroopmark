import AppKit
import SwiftUI

/// Clean-up: one post at a time, ← delete, → keep, ⌘Z takes it back.
/// Kept posts do not come back here; deletions wait (undoable) until they
/// are ten decisions old, the view is left or the app quits. Filters, sort
/// and the search box narrow what is shown.
struct TriageView: View {
    @Environment(AppModel.self) private var model
    /// Which way the last card left, for its animation.
    @State private var leaving: Edge = .leading
    /// Keys are read for the whole window: opened from the sidebar, the
    /// focus stays in the sidebar list, which would take the arrows.
    @State private var keyMonitor: Any?
    @State private var showNewFolderSheet = false
    @State private var newFolderName = ""

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let item = model.items.first {
                    TriageCard(item: item)
                        .id(item.id)
                        .transition(.asymmetric(insertion: .opacity, removal: .move(edge: leaving).combined(with: .opacity)))
                } else if !model.isLoading {
                    done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
            controls
        }
        .background(Theme.canvas)
        .sheet(isPresented: $showNewFolderSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Yeni klasör").font(.headline)
                Text("Kayıtları tek tıkla bu klasöre taşıyabilirsin.").font(.caption).foregroundStyle(.secondary)
                TextField("Klasör adı", text: $newFolderName)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 260, idealWidth: 320)
                HStack {
                    Spacer()
                    Button("Vazgeç") { showNewFolderSheet = false }.keyboardShortcut(.cancelAction)
                    Button("Oluştur") {
                        let name = newFolderName
                        showNewFolderSheet = false
                        Task { _ = await model.addFolder(name: name) }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                MainActor.assumeIsolated { handle(event) } ? nil : event
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .navigationTitle("")
    }

    /// ← → and ⌘Z, unless the user is typing (search, tags, note) or the
    /// media viewer / filter panel is open.
    private func handle(_ event: NSEvent) -> Bool {
        guard model.scope == .triage, model.viewer == nil, !model.showFilters, !model.showBulkTags,
              !(event.window?.firstResponder is NSText) else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, mods) {
        case (123, []): decide(delete: true)
        case (124, []): decide(delete: false)
        case (_, [.command]) where event.charactersIgnoringModifiers == "z" && model.canUndoTriage: undo()
        default: return false
        }
        return true
    }

    private func decide(delete: Bool) {
        guard !model.items.isEmpty else { return }
        leaving = delete ? .leading : .trailing
        withAnimation(.easeOut(duration: 0.18)) { model.triage(delete: delete) }
    }

    private func moveToFolder(_ folder: Folder) {
        guard !model.items.isEmpty else { return }
        leaving = .trailing
        withAnimation(.easeOut(duration: 0.18)) {
            model.triageMoveToFolder(folder)
        }
    }

    private func undo() {
        leaving = .leading
        withAnimation(.easeOut(duration: 0.18)) { model.undoTriage() }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if !model.folders.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text("Klasöre taşı:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(model.folders) { folder in
                            Button {
                                moveToFolder(folder)
                            } label: {
                                Label {
                                    Text(folder.name)
                                } icon: {
                                    Image(nsImage: FolderIcons.image(forFolder: folder.name))
                                        .renderingMode(.template)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 12, height: 12)
                                }
                                .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .help("\"\(folder.name)\" klasörüne taşı ve sakla")
                        }
                        Button {
                            newFolderName = ""
                            showNewFolderSheet = true
                        } label: {
                            Label("Yeni klasör…", systemImage: "plus")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 16)
                }
            }

            HStack(spacing: 14) {
                Button { decide(delete: true) } label: {
                    Label("Sil", systemImage: "arrow.left").frame(minWidth: 110)
                }
                .tint(.red)
                .help("Sil (←)")
                Button(action: undo) {
                    Label("Geri al", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.canUndoTriage)
                .help("Son kararı geri al (⌘Z)")
                Button { decide(delete: false) } label: {
                    Label("Sakla", systemImage: "arrow.right").labelStyle(TrailingIcon()).frame(minWidth: 110)
                }
                .tint(.green)
                .help("Sakla (→)")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.items.isEmpty)

            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var summary: String {
        var parts = ["← sil", "→ sakla", "⌘Z geri al"]
        if !model.folders.isEmpty { parts.append("tek tıkla klasöre taşı") }
        if model.triageDeleted + model.triageKept > 0 {
            parts.append("bu oturumda \(model.triageDeleted) silindi, \(model.triageKept) saklandı")
        }
        if model.hasPendingTriage { parts.append("son 10 karar geri alınabilir") }
        return parts.joined(separator: " · ")
    }

    private var done: some View {
        ContentUnavailableView {
            Label("Gözden geçirilecek kayıt kalmadı", systemImage: "checkmark.circle")
        } description: {
            Text("Sakladıkların buraya bir daha gelmez. Filtreleri değiştirebilir ya da saklananları yeniden gözden geçirebilirsin.")
        } actions: {
            Button("Saklananları yeniden göster") { Task { await model.resetReviewed() } }
        }
    }
}

private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon
        }
    }
}

/// The post being decided on: big media, then the full text.
private struct TriageCard: View {
    @Environment(AppModel.self) private var model
    let item: Item

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                AuthorLine(item: item, showHandle: true)
                if let vm = (item.media.first(where: { $0.isVideo }) ?? item.quote?.item.media.first(where: { $0.isVideo })), let vf = vm.videoFile {
                    // Reviewing is quicker when the clip starts by itself.
                    InlineVideoPlayer(file: vf, alt: vm.alt, aspect: vm.aspect, maxHeight: 420, autoplay: true)
                } else if !item.allMedia.isEmpty {
                    let own = !item.media.isEmpty
                    MediaGallery(media: own ? item.media : item.quote?.item.media ?? [], stacked: own && item.isPhotoCarousel) {
                        model.openViewer(owner: item, fromQuote: !own, index: $0)
                    }
                    .frame(maxHeight: 460)
                }
                if let title = item.title, !title.isEmpty {
                    Text(title).font(.system(size: 17, weight: .semibold))
                }
                if !item.text.isEmpty {
                    Text(item.text).font(.system(size: 15)).lineSpacing(4).textSelection(.enabled)
                }
                if let quote = item.quote?.item, !item.media.isEmpty || !quote.text.isEmpty {
                    QuoteSnippet(item: quote)
                }
                if !item.tags.isEmpty { CardTags(tags: item.tags) }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 640)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}
