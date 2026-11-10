import SwiftUI

/// Advanced filters, opened from the toolbar. Every change applies at once;
/// the result is the same as typing the matching terms in the search box.
struct FilterPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.md) {
                Label("Filtreler", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.headline)
                Spacer()
                Button { model.filters = AdvancedFilters() } label: {
                    Label("Sıfırla", systemImage: "arrow.counterclockwise")
                }
                .controlSize(.small)
                .disabled(model.filters.isEmpty)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)

            Divider()

            Form {
                Section {
                    FlowLayout(spacing: Theme.Spacing.sm) {
                        ForEach(Platform.allCases) { p in
                            let on = model.filters.platforms.contains(p)
                            PlatformFilterChip(platform: p, selected: on) {
                                if on { model.filters.platforms.remove(p) } else { model.filters.platforms.insert(p) }
                            }
                        }
                    }
                    Text(model.filters.platforms.isEmpty ? "Hepsi" : "Seçilenlerden herhangi biri")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Label("Platform", systemImage: "square.grid.2x2")
                }

                Section {
                    Picker("Medya", selection: $model.filters.media) {
                        ForEach(AdvancedFilters.MediaFilter.allCases) { Text($0.label).tag($0) }
                    }
                    tri("Etiket", $model.filters.tagged, yes: "Etiketli", no: "Etiketsiz")
                    tri("Link", $model.filters.link)
                    tri("Not", $model.filters.note)
                    tri("Görselde yazı (OCR)", $model.filters.ocr)
                    tri("Alıntı", $model.filters.quote)
                } header: {
                    Label("İçerik", systemImage: "doc.text")
                }

                Section {
                    FolderFilterPicker()
                    if case .folder(_, let name) = model.scope {
                        Text("Kenar çubuğunda \"\(name)\" klasörü açık")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Label("Klasör", systemImage: "folder")
                }
                .disabled(model.scope.isFolder)

                Section {
                    TagPick(title: "İçersin", picked: $model.filters.includeTags, all: model.tags)
                    TagPick(title: "İçermesin", picked: $model.filters.excludeTags, all: model.tags)
                } header: {
                    Label("Etiketler", systemImage: "tag")
                }

                Section {
                    TextField("Şu kişiler", text: $model.filters.authors, prompt: Text("@kisi, @diger"))
                    TextField("Şunlar hariç", text: $model.filters.excludeAuthors, prompt: Text("@kisi"))
                } header: {
                    Label("Kişi", systemImage: "person")
                }

                Section {
                    Picker("Alan", selection: $model.filters.dateField) {
                        ForEach(AdvancedFilters.DateField.allCases) { Text($0.label).tag($0) }
                    }
                    DateBound(title: "Başlangıç", date: $model.filters.from)
                    DateBound(title: "Bitiş", date: $model.filters.to)
                } header: {
                    Label("Tarih", systemImage: "calendar")
                }
            }
            .formStyle(.grouped)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !model.filters.terms.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Arama ifadesi")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(model.filters.terms)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.md)
                    .background(.background)
                    .overlay(alignment: .top) { Divider() }
                    .help("Aynı sonucu arama kutusuna bunu yazarak da alırsın")
                }
            }
        }
        .frame(minWidth: 440, idealWidth: 480, minHeight: 500, idealHeight: 640)
    }

    private func tri(_ title: String, _ value: Binding<AdvancedFilters.Tri>, yes: String = "Var", no: String = "Yok") -> some View {
        Picker(title, selection: value) {
            Text("Fark etmez").tag(AdvancedFilters.Tri.any)
            Text(yes).tag(AdvancedFilters.Tri.yes)
            Text(no).tag(AdvancedFilters.Tri.no)
        }
        .pickerStyle(.segmented)
    }
}

private struct PlatformFilterChip: View {
    let platform: Platform
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                }
                Label(platform.label, systemImage: platform.symbol)
            }
            .font(.caption.weight(.medium))
            .fixedSize()
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(
                selected
                    ? (hovering ? Theme.accent.opacity(0.92) : Theme.accent)
                    : (hovering ? Theme.Stroke.subtleHoverFill : Theme.Stroke.subtleFill),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(
                        selected
                            ? Color.white.opacity(0.16)
                            : (hovering ? Theme.Stroke.surfaceHoverBorder : Theme.Stroke.surfaceBorder),
                        lineWidth: Theme.Stroke.hairlineWidth
                    )
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityLabel(platform.label)
    }
}

/// Folder choice, shared by the filter panel and the gallery bar. A folder
/// includes its subfolders.
struct FolderFilterPicker: View {
    @Environment(AppModel.self) private var model
    var title = "Klasör"

    var body: some View {
        @Bindable var model = model
        Picker(title, selection: $model.filters.folder) {
            Text("Fark etmez").tag(AdvancedFilters.FolderFilter.any)
            Text("Klasörsüz").tag(AdvancedFilters.FolderFilter.unfiled)
            Text("Herhangi bir klasörde").tag(AdvancedFilters.FolderFilter.filed)
            let nodes = FolderNode.flattened(model.folderTree)
            if !nodes.isEmpty { Divider() }
            ForEach(nodes) { node in
                Text("\(node.displayPath)  (\(node.count))")
                    .tag(AdvancedFilters.FolderFilter.folder(path: node.id, id: node.folder?.id))
            }
        }
    }
}

/// Picked tags as chips plus a menu of the rest.
private struct TagPick: View {
    let title: String
    @Binding var picked: [String]
    let all: [TagCount]

    var body: some View {
        LabeledContent(title) {
            FlowLayout(spacing: Theme.Spacing.sm) {
                ForEach(picked, id: \.self) { key in
                    TagChip(name: key, selected: true, removable: true, remove: { picked.removeAll { $0 == key } })
                }
                Menu {
                    let rest = all.filter { !picked.contains($0.key) }
                    if rest.isEmpty {
                        Button {} label: {
                            Label("Etiket yok", systemImage: "tag.slash")
                        }
                        .disabled(true)
                    }
                    ForEach(rest, id: \.key) { tag in
                        Button("\(tag.name) (\(tag.count))") { picked.append(tag.key) }
                    }
                } label: {
                    Label("Etiket ekle", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("Etiket ekle")
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// An optional date: off, or a day.
private struct DateBound: View {
    let title: String
    @Binding var date: Date?

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { date != nil },
            set: { enabled in
                if enabled {
                    if date == nil { date = .now }
                } else {
                    date = nil
                }
            }
        )
    }

    private var selectedDate: Binding<Date> {
        Binding(
            get: { date ?? .now },
            set: { date = $0 }
        )
    }

    var body: some View {
        HStack {
            Toggle(isOn: isEnabled) {
                Label(title, systemImage: "calendar")
            }
            Spacer()
            if date != nil {
                DatePicker("", selection: selectedDate, displayedComponents: .date)
                    .labelsHidden()
                    .environment(\.locale, Theme.locale)
            }
        }
    }
}

/// Sort menu for the toolbar.
struct SortMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Menu {
            Picker("Sırala", selection: $model.sort) {
                ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            if model.sort == .random {
                Divider()
                Button { model.reshuffle() } label: {
                    Label("Yeniden karıştır", systemImage: "shuffle")
                }
            }
        } label: {
            Label("Sırala", systemImage: "arrow.up.arrow.down")
                .labelStyle(.iconOnly)
        }
        .help("Sıralama: \(model.sort.help)")
    }
}
