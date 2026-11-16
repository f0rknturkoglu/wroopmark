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
    @State private var showBatchSuggest = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let item = model.items.first {
                    TriageCard(item: item)
                        .id(item.id)
                        .contextMenu { menu(for: item) }
                        .transition(.asymmetric(insertion: .opacity, removal: .move(edge: leaving).combined(with: .opacity)))
                } else if !model.isLoading {
                    if let err = model.gridError {
                        ContentUnavailableView {
                            Label("Kayıtlar yüklenemedi", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(err)
                        } actions: {
                            Button {
                                Task { await model.reload() }
                            } label: {
                                Label("Tekrar Dene", systemImage: "arrow.clockwise")
                            }
                        }
                    } else {
                        done
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Theme.Spacing.xl)
            controls
        }
        .sheet(isPresented: $showNewFolderSheet) {
            NameSheet(
                title: String(localized: "Yeni klasör"),
                message: String(localized: "Kayıtları tek tıkla bu klasöre taşıyabilirsin."),
                placeholder: String(localized: "Klasör adı"),
                actionTitle: String(localized: "Oluştur"),
                symbol: "folder.badge.plus"
            ) { name in
                Task { _ = await model.addFolder(name: name) }
            }
        }
        .sheet(isPresented: $showBatchSuggest) {
            MacBatchSuggestSheet()
                .environment(model)
        }
        .task(id: model.items.first?.id) {
            await model.loadTriageSuggestions()
            // The card on screen and the next two get their summary and tag
            // ideas while you decide (on-device, when available).
            if let id = model.items.first?.id { model.prefetchSummaries(after: id) }
        }
        .onAppear {
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    MainActor.assumeIsolated { handle(event) } ? nil : event
                }
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    /// ← → and ⌘Z, unless the user is typing (search, tags, note) or the
    /// media viewer / filter panel is open.
    private func handle(_ event: NSEvent) -> Bool {
        guard model.scope == .triage, model.viewer == nil, !model.showFilters, !model.showBulkTags, !showBatchSuggest,
              !(event.window?.firstResponder is NSText) else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, mods) {
        case (123, []): decide(delete: true)
        case (124, []): decide(delete: false)
        case (_, [.command]) where event.charactersIgnoringModifiers == "z" && model.canUndoTriage: undo()
        // 1–3: the suggested folders.
        case (_, []) where suggestionIndex(event) != nil:
            guard let i = suggestionIndex(event), let folder = suggestedFolder(at: i) else { return false }
            moveToFolder(folder)
        default: return false
        }
        return true
    }

    private func suggestionIndex(_ event: NSEvent) -> Int? {
        guard let c = event.charactersIgnoringModifiers, let n = Int(c), n >= 1, n <= model.triageSuggestions.count else { return nil }
        return n - 1
    }

    private func suggestedFolder(at i: Int) -> Folder? {
        guard model.triageSuggestions.indices.contains(i) else { return nil }
        let id = model.triageSuggestions[i].id
        return model.folders.first { $0.id == id }
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

    @ViewBuilder
    private func menu(for item: Item) -> some View {
        Button {
            if let url = URL(string: item.url) { NSWorkspace.shared.open(url) }
        } label: {
            Label("Kaynağında aç", systemImage: "arrow.up.right.square")
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url, forType: .string)
        } label: {
            Label("Bağlantıyı kopyala", systemImage: "doc.on.doc")
        }
        Divider()
        Button { decide(delete: false) } label: {
            Label("Sakla", systemImage: "arrow.right")
        }
        Button(role: .destructive) { decide(delete: true) } label: {
            Label("Sil", systemImage: "arrow.left")
        }
        if !model.folders.isEmpty {
            Divider()
            Menu("Klasöre taşı") {
                ForEach(model.folders) { folder in
                    Button {
                        moveToFolder(folder)
                    } label: {
                        Label {
                            Text(folder.name)
                        } icon: {
                            Image(nsImage: FolderIcons.image(forFolder: folder.name))
                        }
                    }
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: Theme.Spacing.md) {
            if !model.triageSuggestions.isEmpty, !model.items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Label("Önerilen", systemImage: "sparkles")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                        GlassEffectContainer(spacing: Theme.Spacing.sm) {
                            HStack(spacing: Theme.Spacing.sm) {
                                ForEach(Array(model.triageSuggestions.enumerated()), id: \.element.id) { i, s in
                                    if let folder = suggestedFolder(at: i) {
                                        Button { moveToFolder(folder) } label: {
                                            HStack(spacing: Theme.Spacing.sm) {
                                                Text("\(i + 1)")
                                                    .font(.caption.bold())
                                                    .monospacedDigit()
                                                    .foregroundStyle(.white)
                                                    .frame(width: 20, height: 20)
                                                    .background(Theme.accent, in: .rect(cornerRadius: Theme.Radius.xs))
                                                Text(s.name.replacingOccurrences(of: "/", with: " › "))
                                                    .font(.caption.weight(.semibold))
                                                Text(s.reasonLabel)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .buttonStyle(.glass)
                                        .controlSize(.small)
                                        .tint(Theme.accent)
                                        .help("\"\(s.name)\" klasörüne taşı ve sakla (\(i + 1))")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                }
            }
            if !model.folders.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.sm) {
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
                                        .frame(width: 16, height: 16)
                                }
                                .font(.caption.weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("\"\(folder.name)\" klasörüne taşı ve sakla")
                        }
                        Button {
                            showNewFolderSheet = true
                        } label: {
                            Label("Yeni klasör…", systemImage: "plus")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                }
            }

            GlassEffectContainer(spacing: Theme.Spacing.md) {
                HStack(spacing: Theme.Spacing.md) {
                    Button { decide(delete: true) } label: {
                        Label("Sil", systemImage: "arrow.left")
                            .frame(minWidth: 112)
                    }
                    .tint(.red)
                    .help("Sil (←)")
                    Button(action: undo) {
                        Label("Geri al", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.glass)
                    .disabled(!model.canUndoTriage)
                    .help("Son kararı geri al (⌘Z)")
                    Button { decide(delete: false) } label: {
                        Label("Sakla", systemImage: "arrow.right")
                            .labelStyle(TrailingIcon())
                            .frame(minWidth: 112)
                    }
                    .tint(.green)
                    .help("Sakla (→)")
                    Button { showBatchSuggest = true } label: {
                        Label("Toplu Öneriler", systemImage: "sparkles")
                    }
                    .buttonStyle(.glass)
                    .help("Etiketsiz kayıtlar için klasör ve yapay zekâ önerilerini toplu uygula")
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(model.items.isEmpty)
            }

            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.horizontal, Theme.Spacing.lg)
        }
        .padding(.vertical, Theme.Spacing.lg)
        .frame(maxWidth: .infinity)
        .background(.background)
        .overlay(alignment: .top) { Divider() }
    }

    private var summary: String {
        var parts = [String(localized: "← sil"), String(localized: "→ sakla"), String(localized: "⌘Z geri al")]
        if !model.triageSuggestions.isEmpty { parts.append(String(localized: "1–\(model.triageSuggestions.count) önerilen klasöre taşı")) }
        else if !model.folders.isEmpty { parts.append(String(localized: "tek tıkla klasöre taşı")) }
        if model.triageDeleted + model.triageKept > 0 {
            parts.append(String(localized: "bu oturumda \(model.triageDeleted) silindi, \(model.triageKept) saklandı"))
        }
        if model.hasPendingTriage { parts.append(String(localized: "son 10 karar geri alınabilir")) }
        return parts.joined(separator: " · ")
    }

    private var done: some View {
        ContentUnavailableView {
            Label("Gözden geçirilecek kayıt kalmadı", systemImage: "checkmark.circle")
        } description: {
            Text("Sakladıkların buraya bir daha gelmez. Filtreleri değiştirebilir ya da saklananları yeniden gözden geçirebilirsin.")
        } actions: {
            Button { showBatchSuggest = true } label: {
                Label("Toplu Öneriler", systemImage: "sparkles")
            }
            Button { Task { await model.resetReviewed() } } label: {
                Label("Saklananları yeniden göster", systemImage: "arrow.counterclockwise")
            }
        }
    }
}

private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            configuration.title
            configuration.icon
        }
    }
}

private struct MacBatchSuggestSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var suggestions: [BatchSuggestion] = []
    @State private var selected: Set<String> = []
    @State private var loading = true
    @State private var applying = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Toplu Öneriler", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Button("Kapat") { dismiss() }
            }
            .padding()
            Divider()
            if loading {
                ProgressView("Öneriler hazırlanıyor…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if suggestions.isEmpty {
                ContentUnavailableView(
                    "Öneri bulunamadı",
                    systemImage: "sparkles",
                    description: Text("Etiketsiz kayıtlar için klasör geçmişi veya yapay zekâ önerisi henüz oluşmadı.")
                )
            } else {
                List(suggestions) { row in
                    let isOn = selected.contains(row.id)
                    HStack(alignment: .top, spacing: 10) {
                        Toggle(isOn: Binding(
                            get: { isOn },
                            set: { v in
                                if v { selected.insert(row.id) } else { selected.remove(row.id) }
                            }
                        )) {
                            EmptyView()
                        }
                        .toggleStyle(.checkbox)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.item.title ?? (row.item.text.isEmpty ? row.item.url : row.item.text))
                                .font(.body.weight(.medium))
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                if let f = row.folderName {
                                    Label(f, systemImage: "folder")
                                        .font(.caption)
                                        .foregroundStyle(Theme.accent)
                                }
                                ForEach(row.tags, id: \.self) { t in
                                    Text("#\(t)")
                                        .font(.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Theme.Stroke.subtleFill, in: .capsule)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Divider()
                HStack {
                    Text("\(selected.count) kayıt seçili")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        applying = true
                        Task {
                            let picked = suggestions.filter { selected.contains($0.id) }
                            _ = await model.applyBatch(picked)
                            applying = false
                            dismiss()
                        }
                    } label: {
                        Text(applying ? "Uygulanıyor…" : "Tümünü Uygula")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || applying)
                }
                .padding()
            }
        }
        .frame(width: 560, height: 460)
        .task {
            let loaded = await model.suggestBatch(q: model.effectiveQuery, limit: 30)
            suggestions = loaded
            selected = Set(loaded.map(\.id))
            loading = false
        }
    }
}

/// The post being decided on: big media, then the full text.
private struct TriageCard: View {
    @Environment(AppModel.self) private var model
    let item: Item

    var body: some View {
        // A short post should produce a short card, not a full-height empty
        // panel; only posts taller than the window get their own scroller.
        ViewThatFits(in: .vertical) {
            card
            ScrollView { card }
        }
        .frame(maxWidth: 640)
        .background(.background.secondary, in: .rect(cornerRadius: Theme.Radius.lg))
        .containerShape(.rect(cornerRadius: Theme.Radius.lg))
        .clipShape(.rect(cornerRadius: Theme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.Stroke.surfaceBorder, lineWidth: Theme.Stroke.hairlineWidth)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
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
                Text(title)
                    .font(.headline)
            }
            if !item.text.isEmpty {
                Text(item.text)
                    .font(.body)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
            if let quote = item.quote?.item, !item.media.isEmpty || !quote.text.isEmpty {
                QuoteSnippet(item: quote)
            }
            if !item.tags.isEmpty { CardTags(tags: item.tags) }
            SummaryBlock(item: item)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 160, alignment: .topLeading)
    }
}
