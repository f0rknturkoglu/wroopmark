import SwiftUI

/// A small, consistent sheet for naming or renaming library objects.
struct NameSheet: View {
    let title: String
    let message: String
    let placeholder: String
    let actionTitle: String
    let symbol: String
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(
        title: String,
        message: String = "",
        placeholder: String,
        actionTitle: String,
        symbol: String,
        initialName: String = "",
        onSubmit: @escaping (String) -> Void
    ) {
        self.title = title
        self.message = message
        self.placeholder = placeholder
        self.actionTitle = actionTitle
        self.symbol = symbol
        self.onSubmit = onSubmit
        _name = State(initialValue: initialName)
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Label(title, systemImage: symbol)
                .font(.headline)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                TextField(placeholder, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .onSubmit(submit)
                if !message.isEmpty {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Stroke.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(Theme.Stroke.surfaceBorder, lineWidth: Theme.Stroke.hairlineWidth)
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sheetActions
        }
        .frame(minWidth: 420, idealWidth: 440, minHeight: 240, idealHeight: message.isEmpty ? 240 : 280)
    }

    private var sheetActions: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Spacer()
            Button { dismiss() } label: {
                Label("Vazgeç", systemImage: "xmark")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)

            Button(action: submit) {
                Label(actionTitle, systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(trimmed.isEmpty)
        }
        .controlSize(.regular)
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
        .background(.background)
        .overlay(alignment: .top) { Divider() }
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
        dismiss()
    }
}

struct AddURLSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case link, note
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .link
    @State private var url = ""
    @State private var noteTitle = ""
    @State private var tags = ""
    @State private var note = ""
    @State private var folderID: Int64? = nil

    private var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedTitle: String {
        noteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        switch mode {
        case .link: URL(string: trimmedURL)?.scheme?.hasPrefix("http") == true
        case .note: !trimmedNote.isEmpty || !trimmedTitle.isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack {
                Label(mode == .link ? "Bağlantı kaydet" : "Not kartı ekle", systemImage: mode == .link ? "bookmark.badge.plus" : "note.text.badge.plus")
                    .font(.headline)
                Spacer()
                Picker("Tür", selection: $mode) {
                    Text("Bağlantı").tag(Mode.link)
                    Text("Not Kartı").tag(Mode.note)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if mode == .link {
                    SheetField(
                        title: String(localized: "Bağlantı"),
                        text: $url,
                        prompt: "https://…",
                        hint: String(localized: "X, TikTok, Pinterest ya da herhangi bir sayfa")
                    )
                    SheetField(title: String(localized: "Not"), text: $note, prompt: String(localized: "isteğe bağlı"))
                } else {
                    SheetField(title: String(localized: "Başlık"), text: $noteTitle, prompt: String(localized: "isteğe bağlı"))
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Not")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $note)
                            .font(.body)
                            .frame(minHeight: 88, maxHeight: 140)
                            .padding(Theme.Spacing.xs)
                            .background(.background, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                    .strokeBorder(Theme.Stroke.surfaceBorder, lineWidth: Theme.Stroke.hairlineWidth)
                            }
                    }
                }

                SheetField(title: String(localized: "Etiketler"), text: $tags, prompt: String(localized: "dev/rust, okunacak"))
                if !model.tags.isEmpty {
                    TagSuggestions(current: parseTags(tags), all: model.tags) { name in
                        let current = parseTags(tags)
                        if !current.contains(name) {
                            tags = (current + [name]).joined(separator: ", ")
                        }
                    }
                }

                if !model.folders.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Klasör")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Picker("Klasör", selection: $folderID) {
                            Text("Klasörsüz").tag(Int64?.none)
                            ForEach(FolderNode.flattened(model.folderTree).filter { $0.folder != nil }) { node in
                                if let f = node.folder {
                                    Text(node.displayPath).tag(Int64?.some(f.id))
                                }
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Stroke.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(Theme.Stroke.surfaceBorder, lineWidth: Theme.Stroke.hairlineWidth)
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: Theme.Spacing.md) {
                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                    Text(mode == .link ? "İndiriliyor…" : "Kaydediliyor…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Label("Vazgeç", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button {
                    Task {
                        let ok: Bool
                        switch mode {
                        case .link:
                            ok = await model.addURL(trimmedURL, tags: parseTags(tags), note: trimmedNote, folderID: folderID)
                        case .note:
                            ok = await model.addNote(title: trimmedTitle.isEmpty ? nil : trimmedTitle, text: trimmedNote, tags: parseTags(tags), folderID: folderID)
                        }
                        if ok { dismiss() }
                    }
                } label: {
                    Label("Kaydet", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || model.isBusy)
            }
            .controlSize(.regular)
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)
            .background(.background)
            .overlay(alignment: .top) { Divider() }
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 420)
        .onAppear {
            if case .folder(let fid, _) = model.scope {
                folderID = fid
            }
            // Pre-fill from the clipboard when it holds a link.
            if let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               s.hasPrefix("http"), !s.contains(" ") {
                url = s
            }
        }
    }
}

struct BulkTagSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ids: [String]
    @State private var add = ""
    @State private var remove = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Label(
                ids.count == 1 ? "Etiketle" : "\(ids.count) kaydı etiketle",
                systemImage: "tag"
            )
            .font(.headline)
            .monospacedDigit()

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SheetField(title: String(localized: "Ekle"), text: $add, prompt: String(localized: "virgülle ayır"))
                SheetField(title: String(localized: "Kaldır"), text: $remove, prompt: String(localized: "virgülle ayır"))
                if !model.tags.isEmpty {
                    TagSuggestions(current: parseTags(add), all: model.tags) { name in
                        add = (parseTags(add) + [name]).joined(separator: ", ")
                    }
                }
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Stroke.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(Theme.Stroke.surfaceBorder, lineWidth: Theme.Stroke.hairlineWidth)
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                Spacer()
                Button { dismiss() } label: {
                    Label("Vazgeç", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button {
                    let (a, r) = (parseTags(add), parseTags(remove))
                    dismiss()
                    Task { await model.editTags(ids, add: a, remove: r) }
                } label: {
                    Label("Uygula", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(parseTags(add).isEmpty && parseTags(remove).isEmpty)
            }
            .controlSize(.regular)
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)
            .background(.background)
            .overlay(alignment: .top) { Divider() }
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 320)
    }
}

/// Label above field: a macOS 26 Form row would otherwise hide the title and
/// right-align the prompt.
private struct SheetField: View {
    let title: String
    @Binding var text: String
    let prompt: String
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(.callout.weight(.medium))
            TextField("", text: $text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
