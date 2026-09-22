import SwiftUI
import JaysonCore

/// Sheet for editing a value as JSON, renaming a key, or adding a property.
struct EditSheet: View {
    @Environment(DocumentModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var edit: PendingEdit
    @State private var errorMessage: String?
    @FocusState private var keyFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(edit.path.jsonPathString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            switch edit.kind {
            case .editValue:
                SourceEditor(text: $edit.text)
                    .frame(minHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                Text("Any JSON value is accepted, including objects and arrays. Press ⌘↩ to save.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .renameKey:
                TextField("Key", text: $edit.text)
                    .textFieldStyle(.roundedBorder)
                    .focused($keyFieldFocused)
                    .onSubmit(save)
            case .addProperty:
                TextField("Key", text: $edit.text)
                    .textFieldStyle(.roundedBorder)
                    .focused($keyFieldFocused)
                Text("Value").font(.subheadline)
                SourceEditor(text: $edit.secondaryText)
                    .frame(minHeight: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(saveTitle, action: save)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { keyFieldFocused = true }
    }

    private var title: String {
        switch edit.kind {
        case .editValue: return "Edit Value"
        case .renameKey: return "Rename Key"
        case .addProperty: return "Add Property"
        }
    }

    private var saveTitle: String {
        switch edit.kind {
        case .editValue: return "Save"
        case .renameKey: return "Rename"
        case .addProperty: return "Add"
        }
    }

    private func save() {
        if let message = model.apply(edit) {
            errorMessage = message
        } else {
            dismiss()
        }
    }
}

/// Sheet asking for a URL to load JSON or a schema from.
struct URLPromptSheet: View {
    let target: URLPromptTarget
    @Environment(DocumentModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lastURL") private var urlText = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target == .json ? "Load JSON from URL" : "Load Schema from URL").font(.headline)
            TextField("https://example.com/data.json", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(load)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Load", action: load).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func load() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = trimmed
        if !candidate.contains("://") && !candidate.hasPrefix("/") { candidate = "https://" + candidate }
        if candidate.hasPrefix("/") { candidate = "file://" + candidate }
        guard let url = URL(string: candidate), url.scheme != nil else {
            errorMessage = "That doesn't look like a valid URL."
            return
        }
        model.load(from: url, into: target)
        dismiss()
    }
}
