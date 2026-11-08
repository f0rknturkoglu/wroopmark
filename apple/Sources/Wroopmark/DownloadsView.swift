import SwiftUI
import AppKit

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
            // Header
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("İndirmeler")
                            .font(.title3.bold())
                        if model.activeOrQueuedDownloadsCount > 0 {
                            Text("\(model.activeOrQueuedDownloadsCount)")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.accent, in: Capsule())
                                .monospacedDigit()
                        }
                    }
                    Text(statusSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()

                if !failedDownloads.isEmpty || (model.stats?.videosMissing ?? 0) > 0 {
                    Button {
                        Task { await model.retryAllDownloads() }
                    } label: {
                        Label("Tümünü Yeniden Dene", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }

                Button("Kapat") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(.bar)

            Divider()

            // Filters & Search bar
            HStack(spacing: 12) {
                Picker("Filtre", selection: $selectedTab) {
                    Text("Tümü (\(allCount))").tag(FilterTab.all)
                    Text("İnenler (\(activeDownloads.count))").tag(FilterTab.active)
                    Text("Tamamlananlar (\(completedDownloads.count))").tag(FilterTab.completed)
                    Text("Başarısız (\(failedDownloads.count))").tag(FilterTab.failed)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 380)

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("İndirmelerde ara…", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(maxWidth: 220)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.02))

            Divider()

            // List of download cards
            if filteredItems.isEmpty {
                emptyStateView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredItems) { item in
                            DownloadRow(item: item)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 600, idealWidth: 680, minHeight: 460, idealHeight: 580)
        .task {
            await model.refreshDownloads()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(800))
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
                Button("Eksik videoları şimdi indir") {
                    Task { await model.retryAllDownloads() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct DownloadRow: View {
    @Environment(AppModel.self) private var model
    let item: DownloadItem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Platform & Status indicator
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 44, height: 44)

                Image(systemName: iconName)
                    .font(.system(size: 20))
                    .foregroundStyle(iconColor)
            }

            // Info & Progress
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let author = item.author {
                        Text(author)
                            .font(.system(size: 13, weight: .semibold))
                    }

                    Text(item.platform.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(platformColor)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(platformColor.opacity(0.12), in: Capsule())

                    Spacer()

                    if let bytes = item.fileSize, bytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Text(item.headline)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                // Progress Bar or State Label
                if item.isDownloading {
                    VStack(alignment: .leading, spacing: 4) {
                        let pct = item.progress ?? 0
                        ProgressView(value: pct > 0 ? pct : 0, total: 100)
                            .tint(Theme.accent)

                        HStack(spacing: 8) {
                            if pct > 0 {
                                Text("%\(Int(pct))")
                                    .font(.caption.bold())
                                    .foregroundStyle(Theme.accent)
                                    .monospacedDigit()
                            } else {
                                Text("İndiriliyor…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

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
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.caption)
                        Text("Sırada bekliyor")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                } else if item.isCompleted {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Text("Tamamlandı")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if item.isFailed {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                        let tries = item.tries ?? 1
                        Text("İndirilemedi (\(tries)/3 deneme yapıldı)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            // Action buttons
            VStack(alignment: .trailing, spacing: 6) {
                if item.isCompleted, let file = item.videoFile {
                    HStack(spacing: 6) {
                        Button {
                            model.openInFinder(fileName: file)
                        } label: {
                            Label("Finder", systemImage: "folder")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Finder'da göster")

                        if let rawURL = URL(string: item.url) {
                            Button {
                                NSWorkspace.shared.open(rawURL)
                            } label: {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Kaynağında aç")
                        }
                    }
                } else if item.isFailed || item.isQueued {
                    Button {
                        Task { await model.retryDownload(id: item.id) }
                    } label: {
                        Label("Şimdi indir", systemImage: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
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

    private var platformColor: Color {
        switch item.platform.lowercased() {
        case "tiktok": return .pink
        case "x": return .primary
        case "pinterest": return .red
        case "facebook": return .blue
        default: return .teal
        }
    }
}
