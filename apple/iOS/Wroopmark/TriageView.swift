import AVFoundation
import SwiftUI

// Clean-up on the phone, like the Mac's "Ayıkla": one post at a time,
// swipe left to delete, right to keep, or send it to a folder. Kept posts
// do not come back; the last ten decisions can be taken back, and
// deletions wait until they fall out of that window or the screen closes.

fileprivate struct Decision {
    let item: Item
    let delete: Bool
    var folder: Folder?
}

@MainActor
@Observable
final class TriageQueue {
    private(set) var items: [Item] = []
    private(set) var loading = false
    private(set) var reachedEnd = false
    private var history: [Decision] = []
    private(set) var deleted = 0
    private(set) var kept = 0
    private(set) var remaining = 0
    var suggestions: [FolderSuggestion] = []
    /// Everything decided here, so a refill does not bring it back while
    /// its deletion still waits.
    private var decided: Set<String> = []
    private var summarizing = Set<String>()
    private let filter: String
    private let undoDepth = 10
    private let core = Core.shared

    init(filter: String) { self.filter = filter }

    var current: Item? { items.first }
    var canUndo: Bool { !history.isEmpty }

    private var query: String { ["-is:reviewed", filter].filter { !$0.isEmpty }.joined(separator: " ") }

    func refill() async {
        guard !loading, !reachedEnd, items.count < 10 else { return }
        loading = true
        defer { loading = false }
        guard let r: SearchResult = try? await core.call(.search(q: query, sort: "", limit: 60, offset: 0)) else { return }
        remaining = max(0, r.total - history.filter(\.delete).count)
        let have = Set(items.map(\.id))
        let fresh = r.items.filter { !decided.contains($0.id) && !have.contains($0.id) }
        items += fresh
        // Fewer than a page: every post still to decide is here.
        reachedEnd = r.items.count < 60
    }

    func loadSuggestions(hasFolders: Bool) async {
        guard hasFolders, let id = current?.id else {
            suggestions = []
            return
        }
        let found: [FolderSuggestion] = (try? await core.call(.suggestFolders(id: id, limit: 3))) ?? []
        if current?.id == id { suggestions = found }
    }

    /// Decides on the post on top and moves on. Returns a deletion that
    /// left the undo window and must be carried out now.
    func decide(delete: Bool, folder: Folder? = nil) async {
        guard let item = items.first else { return }
        items.removeFirst()
        decided.insert(item.id)
        remaining = max(0, remaining - 1)
        history.append(Decision(item: item, delete: delete, folder: folder))
        if delete { deleted += 1 } else { kept += 1 }
        suggestions = []
        let expired = history.count > undoDepth ? history.removeFirst() : nil
        if let folder { try? await core.run(.moveToFolder(id: item.id, folderID: folder.id)) }
        if !delete { try? await core.run(.setReviewed(ids: [item.id], reviewed: true)) }
        if let expired, expired.delete { try? await core.run(.delete(id: expired.item.id)) }
        await refill()
    }

    func undo() async {
        guard let last = history.popLast() else { return }
        if last.delete { deleted -= 1 } else { kept -= 1 }
        decided.remove(last.item.id)
        items.insert(last.item, at: 0)
        remaining += 1
        if !last.delete {
            try? await core.run(.setReviewed(ids: [last.item.id], reviewed: false))
            if last.folder != nil { try? await core.run(.moveToFolder(id: last.item.id, folderID: last.item.folderId)) }
        }
    }

    /// Carries out the deletions still waiting for an undo.
    func commit() async {
        let pending = history.filter(\.delete)
        history = []
        for d in pending { try? await core.run(.delete(id: d.item.id)) }
    }

    func resetReviewed() async {
        try? await core.run(.resetReviewed)
        kept = 0
        deleted = 0
        decided = []
        items = []
        reachedEnd = false
        await refill()
    }

    func addTag(_ tag: String) async {
        guard let item = items.first, !item.tags.contains(tag) else { return }
        try? await core.run(.setTags(id: item.id, tags: item.tags + [tag]))
        if let updated: Item = try? await core.call(.get(id: item.id)),
           let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx] = updated
        }
    }

    func prefetchSummaries(llmReady: Bool) async {
        guard llmReady else { return }
        let targets = items.prefix(2).filter { $0.summary == nil && !summarizing.contains($0.id) }.map(\.id)
        for id in targets {
            guard !Task.isCancelled else { return }
            summarizing.insert(id)
            defer { summarizing.remove(id) }
            if let updated: Item = try? await core.call(.call("summarize", ["id": .string(id)]), network: true),
               let idx = items.firstIndex(where: { $0.id == id }) {
                items[idx] = updated
            }
        }
    }
}

struct PhoneTriageView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let scope: PhoneScope
    let query: String
    @State private var queue: TriageQueue?
    @State private var drag: CGSize = .zero
    @State private var details: Item?
    @State private var player = FeedPlayer()
    @State private var feedback = 0
    @State private var showBatchSuggest = false

    private var filter: String {
        [scope.filter, query.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }.joined(separator: " ")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let queue {
                    if let item = queue.current {
                        card(item, queue: queue)
                            .id(item.id)
                            .padding(.horizontal)
                            .padding(.top, 8)
                            .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
                        controls(queue)
                    } else if queue.loading {
                        ProgressView().frame(maxHeight: .infinity)
                    } else {
                        done(queue)
                    }
                }
            }
            .navigationTitle("Ayıkla")
            .navigationSubtitle(subtitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Bitti") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showBatchSuggest = true } label: { Image(systemName: "sparkles") }
                        .accessibilityLabel("Toplu Öneriler")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await undo() } } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(queue?.canUndo != true)
                        .accessibilityLabel("Son kararı geri al")
                }
            }
            .sheet(isPresented: $showBatchSuggest) {
                PhoneBatchSuggestSheet(query: filter) {
                    await queue?.refill()
                }
                .environment(model)
            }
            .sheet(item: $details) { item in
                NavigationStack {
                    ItemView(id: item.id)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Kapat") { details = nil } } }
                }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: feedback)
        .task {
            let q = TriageQueue(filter: filter)
            queue = q
            await q.refill()
        }
        .task(id: queue?.current?.id) {
            guard let queue else { return }
            if let v = queue.current.flatMap(Self.video)?.videoFile { player.play(v) } else { player.stop() }
            async let sug: Void = queue.loadSuggestions(hasFolders: !model.folders.isEmpty)
            async let sum: Void = queue.prefetchSummaries(llmReady: model.aiStatus?.llmReady == true)
            _ = await (sug, sum)
        }
        .onDisappear {
            player.stop()
            let q = queue
            Task {
                await q?.commit()
                await model.reload()
                await model.refreshMeta()
            }
        }
    }

    private var subtitle: String {
        guard let q = queue else { return "" }
        var parts: [String] = []
        if q.remaining > 0 { parts.append(String(localized: "\(q.remaining) kaldı")) }
        if q.deleted + q.kept > 0 { parts.append(String(localized: "\(q.deleted) silindi, \(q.kept) saklandı")) }
        return parts.joined(separator: " · ")
    }

    private static func video(_ item: Item) -> Media? {
        item.allMedia.first { $0.isVideo && $0.videoFile != nil }
    }

    // MARK: Card

    private func card(_ item: Item, queue: TriageQueue) -> some View {
        let progress = max(-1, min(1, drag.width / 120))
        return TriageCard(item: item, player: player, video: Self.video(item), open: { details = item })
            .overlay(alignment: .top) {
                HStack {
                    stamp("SAKLA", color: .green).opacity(Double(max(0, progress)))
                    Spacer()
                    stamp(String(localized: "SİL"), color: .red).opacity(Double(max(0, -progress)))
                }
                .padding(20)
                .allowsHitTesting(false)
            }
            .offset(x: drag.width, y: drag.height * 0.15)
            .rotationEffect(.degrees(Double(drag.width) / 22), anchor: .bottom)
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { drag = $0.translation }
                    .onEnded { v in
                        let x = v.predictedEndTranslation.width
                        if x < -160 || v.translation.width < -120 {
                            Task { await decide(delete: true) }
                        } else if x > 160 || v.translation.width > 120 {
                            Task { await decide(delete: false) }
                        } else {
                            withAnimation(.spring(duration: 0.3)) { drag = .zero }
                        }
                    }
            )
    }

    private func stamp(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.title2.weight(.heavy))
            .foregroundStyle(color)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(color, lineWidth: 3) }
            .rotationEffect(.degrees(text == String(localized: "SİL") ? 12 : -12))
    }

    // MARK: Controls

    private func controls(_ queue: TriageQueue) -> some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(queue.suggestions) { s in
                        if let folder = model.folders.first(where: { $0.id == s.id }) {
                            Button { Task { await decide(delete: false, folder: folder) } } label: {
                                // One line, as tall as "Klasöre taşı" next to it.
                                HStack(spacing: 4) {
                                    Image(systemName: "sparkles")
                                    Text(s.name.replacingOccurrences(of: "/", with: " › ")).fontWeight(.semibold)
                                    Text("· \(s.reasonLabel)").foregroundStyle(.secondary)
                                }
                                .font(.subheadline)
                                .lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .tint(PhoneTheme.accent)
                        }
                    }
                    if !model.folders.isEmpty {
                        Menu {
                            ForEach(model.folders) { f in
                                Button(f.name.replacingOccurrences(of: "/", with: " › ")) { Task { await decide(delete: false, folder: f) } }
                            }
                        } label: {
                            Label("Klasöre taşı", systemImage: "folder").font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                    }
                    if let current = queue.current {
                        ForEach(current.aiTags.filter { !current.tags.contains($0) }, id: \.self) { t in
                            Button("+ #\(t)") { Task { await queue.addTag(t) } }
                                .buttonStyle(.bordered)
                                .font(.subheadline)
                        }
                    }
                }
                .padding(.horizontal)
            }
            HStack(spacing: 40) {
                roundButton("xmark", color: .red, label: String(localized: "Sil")) { Task { await decide(delete: true) } }
                roundButton("info", color: .secondary, label: String(localized: "Ayrıntılar"), small: true) { details = queue.current }
                roundButton("checkmark", color: .green, label: String(localized: "Sakla")) { Task { await decide(delete: false) } }
            }
            .padding(.bottom, 8)
        }
        .padding(.top, 12)
    }

    private func roundButton(_ symbol: String, color: Color, label: String, small: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(small ? .title3.weight(.bold) : .title.weight(.bold))
                .foregroundStyle(color)
                .frame(width: small ? 52 : 68, height: small ? 52 : 68)
                .background(.regularMaterial, in: .circle)
                .overlay { Circle().strokeBorder(color.opacity(0.35), lineWidth: 1.5) }
        }
        .accessibilityLabel(label)
    }

    private func done(_ queue: TriageQueue) -> some View {
        ContentUnavailableView {
            Label("Gözden geçirilecek kayıt kalmadı", systemImage: "checkmark.circle")
        } description: {
            Text("Sakladıkların buraya bir daha gelmez. Bu oturumda \(queue.deleted) silindi, \(queue.kept) saklandı.")
        } actions: {
            Button { Task { await queue.resetReviewed() } } label: {
                Label("Saklananları yeniden göster", systemImage: "arrow.counterclockwise")
            }
        }
    }

    // MARK: Decisions

    private func decide(delete: Bool, folder: Folder? = nil) async {
        guard let queue else { return }
        feedback += 1
        withAnimation(.easeOut(duration: 0.2)) { drag = CGSize(width: delete ? -600 : 600, height: drag.height) }
        try? await Task.sleep(for: .milliseconds(180))
        drag = .zero
        await queue.decide(delete: delete, folder: folder)
    }

    private func undo() async {
        feedback += 1
        await queue?.undo()
    }
}

private struct PhoneBatchSuggestSheet: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let query: String
    let onApplied: @MainActor () async -> Void
    @State private var suggestions: [BatchSuggestion] = []
    @State private var selected: Set<String> = []
    @State private var loading = true
    @State private var applying = false

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Öneriler hazırlanıyor…")
                } else if suggestions.isEmpty {
                    ContentUnavailableView(
                        "Öneri bulunamadı",
                        systemImage: "sparkles",
                        description: Text("Etiketsiz kayıtlar için klasör geçmişi veya yapay zekâ önerisi henüz oluşmadı.")
                    )
                } else {
                    List(suggestions) { row in
                        let isOn = selected.contains(row.id)
                        Button {
                            if isOn { selected.remove(row.id) } else { selected.insert(row.id) }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isOn ? PhoneTheme.accent : .secondary)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.item.title ?? (row.item.text.isEmpty ? row.item.url : row.item.text))
                                        .foregroundStyle(.primary)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(2)
                                    HStack(spacing: 6) {
                                        if let f = row.folderName {
                                            Label(f, systemImage: "folder")
                                                .font(.caption)
                                                .foregroundStyle(PhoneTheme.accent)
                                        }
                                        ForEach(row.tags, id: \.self) { t in
                                            Text("#\(t)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Toplu Öneriler")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Kapat") { dismiss() } }
                if !suggestions.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button(applying ? "Uygulanıyor…" : "Tümünü Uygula") {
                            applying = true
                            Task {
                                let picked = suggestions.filter { selected.contains($0.id) }
                                _ = await model.applyBatch(picked)
                                await onApplied()
                                applying = false
                                dismiss()
                            }
                        }
                        .disabled(selected.isEmpty || applying)
                    }
                }
            }
        }
        .task {
            let loaded = await model.suggestBatch(q: query, limit: 30)
            suggestions = loaded
            selected = Set(loaded.map(\.id))
            loading = false
        }
    }
}

/// The post being decided on: its picture or video, then the text.
private struct TriageCard: View {
    let item: Item
    let player: FeedPlayer
    let video: Media?
    let open: () -> Void

    private var pictures: [Media] { item.allMedia.filter { $0.file != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: (Platform(rawValue: item.platform) ?? .web).symbol).foregroundStyle(PhoneTheme.accent)
                Text(item.author ?? URL(string: item.url)?.host() ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(item.saved.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
            }
            if video != nil || !pictures.isEmpty {
                media.frame(maxWidth: .infinity).frame(maxHeight: .infinity).clipShape(.rect(cornerRadius: 14))
            }
            let text = item.headline
            if !text.isEmpty {
                Text(text)
                    .font(video == nil && pictures.isEmpty ? .title3 : .callout)
                    .lineLimit(video == nil && pictures.isEmpty ? 16 : 4)
            }
            if let q = item.quote?.item, !q.text.isEmpty {
                Text([q.author, q.text].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote)
                    .lineLimit(3)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 10))
            }
            if let s = item.summary, !s.isEmpty {
                Label { Text(s) } icon: { Image(systemName: "sparkles") }
                    .font(.footnote)
                    .lineLimit(3)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PhoneTheme.accent.opacity(0.08), in: .rect(cornerRadius: 10))
            }
            if !item.tags.isEmpty {
                Text(item.tags.map { "#\($0)" }.joined(separator: " ")).font(.caption.weight(.semibold)).foregroundStyle(PhoneTheme.accent).lineLimit(1)
            }
            if video == nil && pictures.isEmpty { Spacer(minLength: 0) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: .rect(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(Color.secondary.opacity(0.2)) }
        .contentShape(.rect(cornerRadius: 22))
        .onTapGesture(perform: open)
    }

    @ViewBuilder
    private var media: some View {
        if let video {
            Color.black
                .overlay {
                    if let poster = video.file { LocalImage(file: poster, maxPixel: 1000, fill: false) }
                }
                .overlay { TriagePlayer(player: player) }
                .overlay(alignment: .bottomTrailing) {
                    Button { player.muted.toggle() } label: {
                        Image(systemName: player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.subheadline).padding(8).background(.ultraThinMaterial, in: .circle)
                    }
                    .padding(8)
                    .accessibilityLabel(player.muted ? "Sesi aç" : "Sesi kapat")
                }
        } else {
            TabView {
                ForEach(pictures) { m in
                    if let f = m.file { LocalImage(file: f, maxPixel: 1400, fill: false) }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: pictures.count > 1 ? .always : .never))
            .background(Color.black)
        }
    }
}

/// The feed's player shown fitted in the card.
private struct TriagePlayer: UIViewRepresentable {
    let player: FeedPlayer

    final class View: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
    }

    func makeUIView(context: Context) -> View {
        let v = View()
        (v.layer as? AVPlayerLayer)?.player = player.player
        (v.layer as? AVPlayerLayer)?.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ v: View, context: Context) {}
}
