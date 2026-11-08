import SwiftUI

/// Advanced filters, opened from the toolbar. Every change applies at once;
/// the result is the same as typing the matching terms in the search box.
struct FilterPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Filtreler").font(.headline)
                Spacer()
                Button("Sıfırla") { model.filters = AdvancedFilters() }
                    .disabled(model.filters.isEmpty)
            }
            .padding([.horizontal, .top], 16).padding(.bottom, 8)

            Form {
                Section("Platform") {
                    FlowLayout(spacing: 6) {
                        ForEach(Platform.allCases) { p in
                            let on = model.filters.platforms.contains(p)
                            Button {
                                if on { model.filters.platforms.remove(p) } else { model.filters.platforms.insert(p) }
                            } label: {
                                HStack(spacing: 4) {
                                    if on {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                    }
                                    Label(p.label, systemImage: p.symbol)
                                }
                                .font(.system(size: 12, weight: .medium))
                                .fixedSize()
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .foregroundStyle(on ? Color.white : Color.primary)
                                .background(on ? Theme.accent : Theme.hairline, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? [.isSelected] : [])
                            .accessibilityLabel(p.label)
                        }
                    }
                    Text(model.filters.platforms.isEmpty ? "Hepsi" : "Seçilenlerden herhangi biri")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("İçerik") {
                    Picker("Medya", selection: $model.filters.media) {
                        ForEach(AdvancedFilters.MediaFilter.allCases) { Text($0.label).tag($0) }
                    }
                    tri("Etiket", $model.filters.tagged, yes: "Etiketli", no: "Etiketsiz")
                    tri("Link", $model.filters.link)
                    tri("Not", $model.filters.note)
                    tri("Görselde yazı (OCR)", $model.filters.ocr)
                    tri("Alıntı", $model.filters.quote)
                }

                Section("Klasör") {
                    FolderFilterPicker()
                    if case .folder(_, let name) = model.scope {
                        Text("Kenar çubuğunda \"\(name)\" klasörü açık")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(model.scope.isFolder)

                Section("Etiketler") {
                    TagPick(title: "İçersin", picked: $model.filters.includeTags, all: model.tags)
                    TagPick(title: "İçermesin", picked: $model.filters.excludeTags, all: model.tags)
                }

                Section("Kişi") {
                    TextField("Şu kişiler", text: $model.filters.authors, prompt: Text("@kisi, @diger"))
                    TextField("Şunlar hariç", text: $model.filters.excludeAuthors, prompt: Text("@kisi"))
                }

                Section("Tarih") {
                    Picker("Alan", selection: $model.filters.dateField) {
                        ForEach(AdvancedFilters.DateField.allCases) { Text($0.label).tag($0) }
                    }
                    DateBound(title: "Başlangıç", date: $model.filters.from)
                    DateBound(title: "Bitiş", date: $model.filters.to)
                }
            }
            .formStyle(.grouped)

            if !model.filters.terms.isEmpty {
                Text(model.filters.terms)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .padding(.horizontal, 16).padding(.bottom, 12)
                    .help("Aynı sonucu arama kutusuna bunu yazarak da alırsın")
            }
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 480, idealHeight: 640)
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
            HStack(spacing: 6) {
                ForEach(picked, id: \.self) { key in
                    TagChip(name: key, selected: true, removable: true, remove: { picked.removeAll { $0 == key } })
                }
                Menu {
                    let rest = all.filter { !picked.contains($0.key) }
                    if rest.isEmpty { Text("Etiket yok") }
                    ForEach(rest, id: \.key) { tag in
                        Button("\(tag.name) (\(tag.count))") { picked.append(tag.key) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Etiket ekle")
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
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
            Toggle(title, isOn: isEnabled)
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
                Button("Yeniden karıştır") { model.reshuffle() }
            }
        } label: {
            Label("Sırala", systemImage: "arrow.up.arrow.down")
        }
        .help("Sıralama: \(model.sort.help)")
    }
}
