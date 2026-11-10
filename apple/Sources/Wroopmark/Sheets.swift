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
        Form {
            Section {
                TextField(placeholder, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                if !message.isEmpty {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Label(title, systemImage: symbol)
                    .font(.headline)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
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
        .frame(minWidth: 420, idealWidth: 440, minHeight: 220, idealHeight: message.isEmpty ? 224 : 264)
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
        dismiss()
    }
}

struct AddURLSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var tags = ""
    @State private var note = ""

    private var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        URL(string: trimmedURL)?.scheme?.hasPrefix("http") == true
    }

    var body: some View {
        Form {
            Section {
                TextField(
                    "Bağlantı",
                    text: $url,
                    prompt: Text("https://…  (X, TikTok, Pinterest ya da herhangi bir sayfa)")
                )
                .textFieldStyle(.roundedBorder)
                TextField("Etiketler", text: $tags, prompt: Text("dev/rust, okunacak"))
                    .textFieldStyle(.roundedBorder)
                TextField("Not", text: $note, prompt: Text("isteğe bağlı"))
                    .textFieldStyle(.roundedBorder)
            } header: {
                Label("Bağlantı kaydet", systemImage: "bookmark.badge.plus")
                    .font(.headline)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: Theme.Spacing.md) {
                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                    Text("İndiriliyor…")
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
                        if await model.addURL(trimmedURL, tags: parseTags(tags), note: note) {
                            dismiss()
                        }
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
        .frame(minWidth: 440, idealWidth: 500, minHeight: 300)
        .onAppear {
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
        Form {
            Section {
                LabeledContent("Ekle") {
                    TextField("Etiketler", text: $add, prompt: Text("virgülle ayır"))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Kaldır") {
                    TextField("Etiketler", text: $remove, prompt: Text("virgülle ayır"))
                        .textFieldStyle(.roundedBorder)
                }
                if !model.tags.isEmpty {
                    TagSuggestions(current: parseTags(add), all: model.tags) { name in
                        add = (parseTags(add) + [name]).joined(separator: ", ")
                    }
                }
            } header: {
                Label(
                    ids.count == 1 ? "Etiketle" : "\(ids.count) kaydı etiketle",
                    systemImage: "tag"
                )
                .font(.headline)
                .monospacedDigit()
            }
        }
        .formStyle(.grouped)
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
        .frame(minWidth: 420, idealWidth: 480, minHeight: 300)
    }
}
