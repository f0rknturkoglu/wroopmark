import SwiftUI

/// Every URL found in saved posts (and added by hand), deduplicated and organized into subfolders.
struct LinkPoolView: View {
    @Environment(AppModel.self) private var model
    @State private var newLink = ""
    @State private var selectedID: Int64?
    @State private var deletingLink: LinkRow?

    private var currentCategory: LinkCategory? {
        if case .links(let cat) = model.scope { return cat }
        return nil
    }

    private var deadCount: Int {
        model.linksDeadTotal
    }

    var body: some View {
        @Bindable var model = model
        List(selection: $selectedID) {
            ForEach(model.links) { link in
                LinkListRow(link: link, selected: selectedID == link.id)
                    .tag(link.id)
                    .listRowInsets(EdgeInsets(top: Theme.Spacing.xs, leading: Theme.Spacing.sm, bottom: Theme.Spacing.xs, trailing: Theme.Spacing.sm))
                    .listRowSeparator(.hidden)
                    .onAppear {
                        if link.id == model.links.last?.id {
                            Task { await model.loadMoreLinks() }
                        }
                    }
                    .contextMenu {
                        Button { open(link) } label: {
                            Label("Tarayıcıda aç", systemImage: "arrow.up.right.square")
                        }
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link.url, forType: .string)
                        } label: {
                            Label("Kopyala", systemImage: "doc.on.doc")
                        }
                        Divider()
                        Button(role: .destructive) { deletingLink = link } label: {
                            Label("Havuzdan sil…", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .contentMargins(.vertical, Theme.Spacing.sm, for: .scrollContent)
        .onChange(of: selectedID) { _, id in
            Task {
                await model.select(link: model.links.first { $0.id == id })
            }
        }
        .onChange(of: model.selectedLink?.id) { _, id in
            if selectedID != id {
                selectedID = id
            }
        }
        .onChange(of: model.onlyDeadLinks) { _, _ in
            Task { await model.loadLinks(reset: true) }
        }
        .confirmationDialog(
            "Bu linki havuzdan silmek istediğine emin misin?",
            isPresented: Binding(
                get: { deletingLink != nil },
                set: { if !$0 { deletingLink = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Sil", role: .destructive) {
                if let link = deletingLink {
                    deletingLink = nil
                    Task { await model.deleteLink(link) }
                }
            }
            Button("Vazgeç", role: .cancel) { deletingLink = nil }
        } message: {
            Text("Bu link kayıt havuzundan kaldırılır.")
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.sm) {
                    titleBlock
                    Divider().frame(height: 18)
                    addBar
                    actionButtons
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    titleBlock
                    addBar
                    HStack(spacing: Theme.Spacing.sm) {
                        actionButtons
                        Spacer(minLength: 0)
                    }
                }
            }
            .controlSize(.regular)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)
            .background(.background)
            .overlay(alignment: .bottom) { Divider() }
        }
        .overlay {
            if model.links.isEmpty && !model.isLoadingLinks {
                if let err = model.linksError {
                    ContentUnavailableView {
                        Label("Link havuzu yüklenemedi", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(err)
                    } actions: {
                        Button {
                            Task { await model.loadLinks(reset: true) }
                        } label: {
                            Label("Tekrar Dene", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.regular)
                    }
                    .padding(Theme.Spacing.lg)
                } else if model.onlyDeadLinks {
                    ContentUnavailableView(
                        "Kırık link yok",
                        systemImage: "checkmark.circle",
                        description: Text("Kontrol edilen linklerin hepsi açılıyor. \"Kırıkları bul\" yeni kontrol başlatır.")
                    )
                    .padding(Theme.Spacing.lg)
                } else if let cat = currentCategory {
                    ContentUnavailableView {
                        Label("\(cat.label) linki yok", systemImage: cat.symbolFallback)
                    } description: {
                        Text("Bu kategoride kayıtlı link bulunmuyor.")
                    }
                    .padding(Theme.Spacing.lg)
                } else {
                    ContentUnavailableView(
                        "Link yok",
                        systemImage: "link",
                        description: Text("Kaydedilen gönderilerdeki linkler burada toplanır.")
                    )
                    .padding(Theme.Spacing.lg)
                }
            }
        }
        .onAppear {
            selectedID = model.selectedLink?.id
        }
    }

    /// The pool needs the same scope header the grid and gallery get from
    /// their top bar; otherwise the only "Link havuzu" cue is in the sidebar.
    private var titleBlock: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text("Link havuzu")
                .font(.subheadline.weight(.semibold))
            let total = model.linksTotal > 0 ? model.linksTotal : model.links.count
            if total > 0 {
                CountPill(value: total.formatted())
            }
        }
        .fixedSize()
    }

    private var addBar: some View {
        HStack(spacing: Theme.Spacing.sm) {
            TextField("Havuza link ekle", text: $newLink)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180)
                .onSubmit(add)
            Button(action: add) {
                Label("Ekle", systemImage: "plus")
            }
            .fixedSize()
            .disabled(newLink.isEmpty)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        @Bindable var model = model
        Button {
            Task { await model.enrichLinks() }
        } label: {
            Label("Başlıkları getir", systemImage: "text.badge.plus")
        }
        .fixedSize()
        .help("Başlığı olmayan linklerin sayfa başlığını indir")
        .disabled(model.isBusy)
        if model.isCheckingLinks {
            Button { model.stopCheckingLinks() } label: {
                Label("Durdur (\(model.linksChecked))", systemImage: "stop.circle")
                    .monospacedDigit()
            }
            .fixedSize()
            .help("Link kontrolünü durdur")
        } else {
            Button {
                Task { await model.checkLinks() }
            } label: {
                Label("Kırıkları bul", systemImage: "stethoscope")
            }
            .fixedSize()
            .help("Bu hafta kontrol edilmemiş linklerin hâlâ açılıp açılmadığına bak")
        }
        Toggle(isOn: $model.onlyDeadLinks) {
            Label(deadCount > 0 ? "Kırık (\(deadCount))" : "Kırık", systemImage: "exclamationmark.triangle")
                .monospacedDigit()
        }
        .fixedSize()
        .toggleStyle(.button)
        .help("Yalnızca kırık linkleri göster")
    }

    private func add() {
        let url = newLink.trimmingCharacters(in: .whitespaces)
        newLink = ""
        Task { await model.addLink(url) }
    }

    private func open(_ link: LinkRow) {
        if let url = URL(string: link.url) { NSWorkspace.shared.open(url) }
    }
}

/// One pool row: icon, title, host and health, highlighted softly on hover inside an inset list.
private struct LinkListRow: View {
    let link: LinkRow
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            let cat = LinkCategory.allCases.first { $0.matches(host: link.host, url: link.url) } ?? .other
            Image(nsImage: cat.iconImage)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .foregroundStyle(selected ? .primary : .secondary)
                .frame(width: 32, height: 32)
                .background(Theme.Stroke.subtleFill, in: .rect(cornerRadius: Theme.Radius.sm))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                        .strokeBorder(Theme.Stroke.surfaceBorder, lineWidth: Theme.Stroke.hairlineWidth)
                }

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(link.title ?? link.url.replacingOccurrences(of: "https://", with: ""))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    Text(link.host)
                        .lineLimit(1)
                    if link.itemCount > 0 {
                        Text("· \(link.itemCount) kayıtta")
                            .monospacedDigit()
                    }
                    if link.manual {
                        Label("Elle eklendi", systemImage: "hand.point.up.left")
                            .labelStyle(.iconOnly)
                            .help("Elle eklendi")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            if link.dead {
                Text(link.status == 0 ? "kırık · sunucu yok" : "kırık · \(link.status ?? 0)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(.red.opacity(0.85), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.2), lineWidth: Theme.Stroke.hairlineWidth)
                    }
                    .fixedSize()
                    .help("Son kontrolde sayfa açılmadı. Gönderinin kendisi arşivde duruyor.")
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .padding(.horizontal, Theme.Spacing.sm)
        .background(hovering && !selected ? Theme.Stroke.subtleFill : .clear, in: .rect(cornerRadius: Theme.Radius.sm))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct LinkDetailView: View {
    @Environment(AppModel.self) private var model
    let link: LinkRow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text(link.title ?? link.host)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                if let d = link.description {
                    Text(d)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let url = URL(string: link.url) {
                    Link(link.url, destination: url)
                        .font(.callout)
                        .lineLimit(2)
                }
                Divider()
                if let err = model.linkItemsError {
                    HStack(spacing: Theme.Spacing.sm) {
                        Label("Kayıtlar yüklenemedi", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            Task { await model.select(link: link) }
                        } label: {
                            Label("Tekrar Dene", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                    }
                    .padding(Theme.Spacing.md)
                    .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: Theme.Radius.sm))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                            .strokeBorder(Color.orange.opacity(0.28), lineWidth: Theme.Stroke.hairlineWidth)
                    }
                } else if model.isLoadingLinkItems {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.xl)
                } else if model.linkItems.isEmpty {
                    ContentUnavailableView(
                        "Hiçbir kayıtta geçmiyor",
                        systemImage: "tray",
                        description: Text("Bu bağlantıya atıf yapan arşivlenmiş bir gönderi bulunmuyor.")
                    )
                    .padding(.vertical, Theme.Spacing.xl)
                } else {
                    Label(
                        "Geçtiği kayıtlar (\(model.linkItems.count)\(model.reachedLinkItemsEnd ? "" : "+"))",
                        systemImage: "link"
                    )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                ForEach(model.linkItems) { item in
                    ItemCard(item: item, selected: false)
                        .accessibilityAddTraits(.isButton)
                        .onTapGesture {
                            model.scope = .all
                            model.query = ""
                            Task {
                                await model.reload()
                                model.selection = [item.id]
                            }
                        }
                        .contextMenu {
                            Button {
                                if let url = URL(string: item.url) { NSWorkspace.shared.open(url) }
                            } label: {
                                Label("Tarayıcıda aç", systemImage: "arrow.up.right.square")
                            }
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.url, forType: .string)
                            } label: {
                                Label("Bağlantıyı kopyala", systemImage: "doc.on.doc")
                            }
                        }
                        .onAppear {
                            if item.id == model.linkItems.last?.id {
                                Task { await model.loadMoreLinkItems() }
                            }
                        }
                }
                if model.isLoadingLinkItems {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.md)
                }
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: Theme.Layout.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}
