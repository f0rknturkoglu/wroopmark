import SwiftUI

struct AddURLSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var tags = ""
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bağlantı kaydet").font(.headline)
            TextField("https://…  (X, TikTok, Pinterest ya da herhangi bir sayfa)", text: $url)
                .textFieldStyle(.roundedBorder)
            TextField("etiketler: dev/rust, okunacak", text: $tags)
                .textFieldStyle(.roundedBorder)
            TextField("not (isteğe bağlı)", text: $note)
                .textFieldStyle(.roundedBorder)
            HStack {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Text("indiriliyor…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Kaydet") {
                    Task {
                        if await model.addURL(url.trimmingCharacters(in: .whitespacesAndNewlines), tags: parseTags(tags), note: note) {
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(URL(string: url.trimmingCharacters(in: .whitespaces))?.scheme?.hasPrefix("http") != true || model.isBusy)
            }
        }
        .padding(20)
        .frame(width: 460)
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
        VStack(alignment: .leading, spacing: 12) {
            Text(ids.count == 1 ? "Etiketle" : "\(ids.count) kaydı etiketle").font(.headline)
            TextField("eklenecek etiketler", text: $add).textFieldStyle(.roundedBorder)
            TextField("kaldırılacak etiketler", text: $remove).textFieldStyle(.roundedBorder)
            if !model.tags.isEmpty {
                TagSuggestions(current: parseTags(add), all: model.tags) { name in
                    add = (parseTags(add) + [name]).joined(separator: ", ")
                }
            }
            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Uygula") {
                    let (a, r) = (parseTags(add), parseTags(remove))
                    dismiss()
                    Task { await model.editTags(ids, add: a, remove: r) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parseTags(add).isEmpty && parseTags(remove).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
