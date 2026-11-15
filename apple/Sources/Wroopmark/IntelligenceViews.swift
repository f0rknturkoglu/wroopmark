import SwiftUI

// Views for v0.2 / v0.3: the import/export banner, the on-device summary
// block, related items, and the duplicates sheet.

/// A short status line at the bottom of the window (imports, exports).
struct TransferBanner: View {
    let status: String
    let busy: Bool
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
            }
            Text(status)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: .leading)
            if !busy {
                Button(action: close) {
                    Image(systemName: "xmark").font(.caption.weight(.bold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Kapat")
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.md))
    }
}

/// The on-device summary of an item and the tags the model suggested
/// (one click adds one). Offers to summarize when the model is there.
struct SummaryBlock: View {
    @Environment(AppModel.self) private var model
    let item: Item

    private var ideas: [String] {
        let have = Set(item.tags.map { $0.lowercased() })
        return item.aiTags.filter { !have.contains($0.lowercased()) }
    }

    var body: some View {
        let busy = model.summarizing.contains(item.id)
        if let summary = item.summary, !summary.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Label("Özet", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(summary)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !ideas.isEmpty {
                    FlowChips(ideas) { tag in
                        Button {
                            Task { await model.acceptAITag(tag, on: item.id) }
                        } label: {
                            Label(tag, systemImage: "plus")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("#\(tag) etiketini ekle")
                    }
                }
            }
            .padding(Theme.Spacing.md)
            .background(Theme.accent.opacity(0.06), in: .rect(cornerRadius: Theme.Radius.sm))
        } else if model.aiStatus?.llmReady == true {
            HStack(spacing: Theme.Spacing.sm) {
                Button {
                    Task { await model.summarize(item.id) }
                } label: {
                    Label(busy ? "Özetleniyor…" : "Özetle ve etiket öner", systemImage: "sparkles")
                }
                .controlSize(.small)
                .disabled(busy)
                if busy { ProgressView().controlSize(.small) }
                if let e = model.summaryError, !busy {
                    Text(e).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }
}

/// Wrapping row of small views.
struct FlowChips<Content: View>: View {
    let items: [String]
    let content: (String) -> Content

    init(_ items: [String], @ViewBuilder content: @escaping (String) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        FlowLayout(spacing: Theme.Spacing.xs) {
            ForEach(items, id: \.self) { content($0) }
        }
    }
}

/// Items closest in meaning (needs vectors; hidden when there are none).
struct RelatedSection: View {
    @Environment(AppModel.self) private var model
    let item: Item

    var body: some View {
        // A VStack, not a Group: an empty Group has no view for `.task` to run on.
        VStack(alignment: .leading, spacing: 0) {
            if model.relatedFor == item.id, !model.related.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Label("Benzerleri", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(model.related) { r in
                        Button {
                            if model.items.contains(where: { $0.id == r.id }) {
                                model.selection = [r.id]
                            } else {
                                model.reveal(id: r.id)
                            }
                        } label: {
                            ItemRow(item: r, selected: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task(id: item.id) { await model.loadRelated(for: item.id) }
    }
}

/// Groups of items that look like the same thing saved twice.
struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kopyalar").font(.title3.weight(.semibold))
                    Text("Aynı görsel/video, aynı metin ya da çok benzer içerik. Birini tut, diğerleri silinir.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isLoadingDuplicates { ProgressView().controlSize(.small) }
                Button("Yenile") { Task { await model.loadDuplicates() } }
                    .disabled(model.isLoadingDuplicates)
                Button("Kapat") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Theme.Spacing.lg)
            Divider()
            if model.duplicates.isEmpty && !model.isLoadingDuplicates {
                ContentUnavailableView("Kopya bulunamadı", systemImage: "square.on.square", description: Text("Arşivde aynı şeyin iki kaydı yok."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        ForEach(model.duplicates) { group in
                            DuplicateGroupCard(group: group)
                        }
                    }
                    .padding(Theme.Spacing.lg)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .task { await model.loadDuplicates() }
    }
}

private struct DuplicateGroupCard: View {
    @Environment(AppModel.self) private var model
    let group: DuplicateGroup

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Label(group.reasonLabel, systemImage: group.reason == "media" ? "photo.on.rectangle" : group.reason == "text" ? "text.quote" : "sparkles")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Kopya değil") { Task { await model.ignoreDuplicates(group) } }
                    .controlSize(.small)
                    .help("Bu grubu bir daha gösterme")
            }
            ForEach(group.items) { item in
                HStack(alignment: .center, spacing: Theme.Spacing.sm) {
                    ItemRow(item: item, selected: false)
                    VStack(spacing: Theme.Spacing.xs) {
                        Button("Bunu tut") { Task { await model.keepOnly(item, in: group) } }
                            .controlSize(.small)
                        Text(item.savedAt > 0 ? Date(timeIntervalSince1970: TimeInterval(item.savedAt)).formatted(date: .abbreviated, time: .omitted) : "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Stroke.subtleFill, in: .rect(cornerRadius: Theme.Radius.sm))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .strokeBorder(Theme.Stroke.surfaceBorder, lineWidth: Theme.Stroke.hairlineWidth)
        }
    }
}

/// The rest of an X thread, each post with its own pictures.
struct ThreadSection: View {
    @Environment(AppModel.self) private var model
    let item: Item

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Label("Zincir · \(item.thread.count + 1) gönderi", systemImage: "text.line.first.and.arrowtriangle.forward")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(item.thread.enumerated()), id: \.element.id) { n, part in
                HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                    Text("\(n + 2)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .trailing)
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        if !part.text.isEmpty {
                            Text(part.text)
                                .font(.body)
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        let urls = Set(part.media.map(\.url))
                        let mine = item.media.filter { urls.contains($0.url) }
                        if !mine.isEmpty {
                            MediaGallery(media: mine, stacked: false) { i in
                                let target = mine.indices.contains(i) ? mine[i].url : nil
                                let global = item.media.firstIndex { $0.url == target } ?? 0
                                model.openViewer(owner: item, fromQuote: false, index: global)
                            }
                        }
                    }
                }
            }
        }
        .padding(.leading, Theme.Spacing.xs)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.accent.opacity(0.35)).frame(width: 2).padding(.vertical, 28)
        }
    }
}
