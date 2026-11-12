import AppKit
import SwiftUI

struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum FilterTab: String, CaseIterable, Identifiable {
        case all = "Tümü"
        case active = "İnenler"
        case completed = "Tamamlananlar"
        case failed = "Başarısız"

        var id: String { rawValue }
    }

    @State private var selectedTab: FilterTab = .all
    @State private var searchText = ""

    private var activeDownloads: [DownloadItem] {
        (model.downloads?.active ?? []) + (model.downloads?.queued ?? [])
    }

    private var completedDownloads: [DownloadItem] {
        model.downloads?.completed ?? []
    }

    private var failedDownloads: [DownloadItem] {
        model.downloads?.failed ?? []
    }

    private var filteredItems: [DownloadItem] {
        let base: [DownloadItem]
        switch selectedTab {
        case .all:
            base = (model.downloads?.active ?? [])
                + (model.downloads?.queued ?? [])
                + (model.downloads?.failed ?? [])
                + (model.downloads?.completed ?? [])
        case .active:
            base = activeDownloads
        case .completed:
            base = completedDownloads
        case .failed:
            base = failedDownloads
        }

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.headline.lowercased().contains(q) ||
            ($0.authorHandle?.lowercased().contains(q) ?? false) ||
            ($0.authorName?.lowercased().contains(q) ?? false) ||
            $0.platform.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Theme.Spacing.md) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text("İndirmeler")
                            .font(.title3.bold())
                        if model.activeOrQueuedDownloadsCount > 0 {
                            Text("\(model.activeOrQueuedDownloadsCount)")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, Theme.Spacing.sm)
                                .padding(.vertical, Theme.Spacing.xs)
                                .background(Theme.accent, in: Capsule())
                                .monospacedDigit()
                                .accessibilityLabel("\(model.activeOrQueuedDownloadsCount) etkin indirme")
                        }
                    }
                    Text(statusSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: Theme.Spacing.md)

                if !failedDownloads.isEmpty || (model.stats?.videosMissing ?? 0) > 0 {
                    Button {
                        Task { await model.retryAllDownloads() }
                    } label: {
                        Label("Tümünü Yeniden Dene", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }

                Button { dismiss() } label: {
                    Label("Kapat", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            }
            .controlSize(.regular)
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.lg)
            .background(.background)

            Divider()

            VStack(spacing: Theme.Spacing.md) {
                Picker("Filtre", selection: $selectedTab) {
                    Text("Tümü (\(allCount))").tag(FilterTab.all)
                    Text("İnenler (\(activeDownloads.count))").tag(FilterTab.active)
                    Text("Tamamlananlar (\(completedDownloads.count))").tag(FilterTab.completed)
                    Text("Başarısız (\(failedDownloads.count))").tag(FilterTab.failed)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .monospacedDigit()
                .frame(maxWidth: .infinity)

                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("İndirmelerde ara…", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Label("Aramayı temizle", systemImage: "xmark.circle.fill")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(Theme.Stroke.subtleFill, in: .rect(cornerRadius: Theme.Radius.sm))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                        .strokeBorder(Theme.Stroke.surfaceBorder, lineWidth: Theme.Stroke.hairlineWidth)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)

            Divider()

            if let err = model.downloadsError {
                HStack(spacing: Theme.Spacing.sm) {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                    Spacer(minLength: Theme.Spacing.sm)
                    Button {
                        Task { await model.refreshDownloads() }
                    } label: {
                        Label("Tekrar Dene", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.sm)
                .background(Color.orange.opacity(0.12))
                Divider()
            }

            if filteredItems.isEmpty {
                emptyStateView
                    .padding(Theme.Spacing.xl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.Spacing.md) {
                        ForEach(filteredItems) { item in
                            DownloadRow(item: item)
                        }
                    }
                    .padding(Theme.Spacing.xl)
                }
            }
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 480, idealHeight: 580)
        .task {
            await model.refreshDownloads()
            while !Task.isCancelled {
                let busy = model.activeOrQueuedDownloadsCount > 0 || model.isFetchingVideos
                do {
                    try await Task.sleep(for: busy ? .milliseconds(800) : .seconds(5))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await model.refreshDownloads()
            }
        }
    }

    private var allCount: Int {
        activeDownloads.count + completedDownloads.count + failedDownloads.count
    }

    private var statusSummary: String {
        var parts: [String] = []
        let active = model.downloads?.active.count ?? 0
        let queued = model.downloads?.queued.count ?? 0
        let completed = model.downloads?.completed.count ?? 0
        let failed = model.downloads?.failed.count ?? 0

        if active > 0 { parts.append("\(active) video iniyor") }
        if queued > 0 { parts.append("\(queued) sırada") }
        if completed > 0 { parts.append("\(completed) tamamlandı") }
        if failed > 0 { parts.append("\(failed) başarısız") }

        return parts.isEmpty ? "İndirme kuyruğu boş" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var emptyStateView: some View {
        ContentUnavailableView {
            Label(
                selectedTab == .all ? "İndirme yok" : "\(selectedTab.rawValue) bulunamadı",
                systemImage: "arrow.down.circle"
            )
        } description: {
            Text("Kaydettiğiniz TikTok veya web videolarının indirme ilerlemeleri burada görünür.")
        } actions: {
            if (model.stats?.videosMissing ?? 0) > 0 {
                Button {
                    Task { await model.retryAllDownloads() }
                } label: {
                    Label("Eksik videoları şimdi indir", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.glassProminent)
            }
        }
    }
}

private struct DownloadRow: View {
    @Environment(AppModel.self) private var model
    let item: DownloadItem
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(Theme.Stroke.subtleFill)
                    .frame(width: 48, height: 48)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                            .strokeBorder(Theme.Stroke.surfaceBorder, lineWidth: Theme.Stroke.hairlineWidth)
                    }

                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundStyle(iconColor)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    if let author = item.author {
                        Text(author)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                    }

                    Label(item.platform.uppercased(), systemImage: Platform(rawValue: item.platform.lowercased())?.symbol ?? "globe")
                        .font(.caption.bold())
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                        .overlay {
                            Capsule()
                                .strokeBorder(Theme.accent.opacity(0.18), lineWidth: Theme.Stroke.hairlineWidth)
                        }

                    Spacer(minLength: Theme.Spacing.sm)

                    if let bytes = item.fileSize, bytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: 64, alignment: .trailing)
                    }
                }

                Text(item.headline)
                    .font(.callout)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if item.isDownloading {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        let pct = item.progress ?? 0
                        ProgressView(value: pct > 0 ? pct : 0, total: 100)
                            .tint(Theme.accent)

                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                            Group {
                                if pct > 0 {
                                    Text("%\(Int(pct))")
                                        .font(.caption.bold())
                                        .foregroundStyle(Theme.accent)
                                } else {
                                    Text("İndiriliyor…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .monospacedDigit()
                            .frame(minWidth: 44, alignment: .leading)

                            if let spd = item.speed {
                                Text("· \(spd)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }

                            if let eta = item.eta {
                                Text("· \(eta) kaldı")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                } else if item.isQueued {
                    Label("Sırada bekliyor", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if item.isCompleted {
                    Label("Tamamlandı", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if item.isFailed {
                    Label(
                        "İndirilemedi (\(item.tries ?? 1)/3 deneme yapıldı)",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                    .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: Theme.Spacing.sm) {
                if item.isCompleted, let file = item.videoFile {
                    Button {
                        model.openInFinder(fileName: file)
                    } label: {
                        Label("Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Finder'da göster")

                    if let rawURL = URL(string: item.url) {
                        Button {
                            NSWorkspace.shared.open(rawURL)
                        } label: {
                            Label("Kaynağında aç", systemImage: "arrow.up.right.square")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Kaynağında aç")
                    }
                } else if item.isFailed || item.isQueued {
                    Button {
                        Task { await model.retryDownload(id: item.id) }
                    } label: {
                        Label("Şimdi indir", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .frame(minWidth: 136, alignment: .trailing)
        }
        .padding(Theme.Spacing.lg)
        .background(.background.secondary, in: .rect(cornerRadius: Theme.Radius.lg))
        .containerShape(.rect(cornerRadius: Theme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(
                    hovering ? Theme.Stroke.surfaceHoverBorder : Theme.Stroke.surfaceBorder,
                    lineWidth: Theme.Stroke.hairlineWidth
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            if let file = item.videoFile {
                Button { model.openInFinder(fileName: file) } label: {
                    Label("Finder'da göster", systemImage: "folder")
                }
            }
            if let rawURL = URL(string: item.url) {
                Button { NSWorkspace.shared.open(rawURL) } label: {
                    Label("Kaynağında aç", systemImage: "arrow.up.right.square")
                }
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url, forType: .string)
            } label: {
                Label("Bağlantıyı kopyala", systemImage: "doc.on.doc")
            }
            if item.isFailed || item.isQueued {
                Divider()
                Button { Task { await model.retryDownload(id: item.id) } } label: {
                    Label("Yeniden dene", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var iconName: String {
        if item.isDownloading { return "arrow.down.circle.fill" }
        if item.isQueued { return "clock" }
        if item.isCompleted { return "play.rectangle.fill" }
        return "exclamationmark.circle.fill"
    }

    private var iconColor: Color {
        if item.isDownloading { return Theme.accent }
        if item.isQueued { return .orange }
        if item.isCompleted { return .green }
        return .red
    }
}
