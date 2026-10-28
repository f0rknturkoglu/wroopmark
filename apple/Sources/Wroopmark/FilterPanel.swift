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
                                Label(p.label, systemImage: p.symbol)
                                    .font(.system(size: 12, weight: .medium))
                                    .fixedSize()
                                    .padding(.horizontal, 9).padding(.vertical, 5)
                                    .foregroundStyle(on ? Color.white : Color.primary)
                                    .background(on ? Theme.accent : Theme.hairline, in: Capsule())
                            }
                            .buttonStyle(.plain)
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
        .frame(width: 460, height: 640)
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

    var body: some View {
        HStack {
            Toggle(title, isOn: Binding(get: { date != nil }, set: { date = $0 ? (date ?? .now) : nil }))
            Spacer()
            if let d = date {
                DatePicker("", selection: Binding(get: { d }, set: { date = $0 }), displayedComponents: .date)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "tr_TR"))
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
