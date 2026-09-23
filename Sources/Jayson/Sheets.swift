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


// MARK: - Variables

/// Edits the pipeline variable library (`{{ vars.name }}`). Values are stored in
/// `variables.json` (owner-only) in Application Support, never in pipelines.
struct VariablesSheet: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var revealed: Set<UUID> = []
    @FocusState private var focusedName: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Variables").font(.headline)
                    Text("Available to every pipeline as `{{ vars.name }}` in HTTP requests and `$.vars.name` in scripts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    let variable = workspace.addVariable()
                    focusedName = variable.id
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }

            if workspace.variables.isEmpty {
                EmptyState(systemImage: "tag", title: "No variables yet", message: "Add a token or base URL here once and reuse it in every request. A Set Variable step with “Save to the variable library” can also fill this list from a response.")
                    .frame(height: 160)
            } else {
                HStack(spacing: 8) {
                    Text("Name").frame(width: 150, alignment: .leading)
                    Text("Value").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Secret").frame(width: 50)
                    Spacer().frame(width: 20)
                }
                .font(Chrome.sectionFont).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(workspace.variables) { variable in
                            row(variable)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            Text("Stored in \(VariableStore.fileURL.path) with owner-only permissions. Secret values are masked here and never included in exported pipelines or the session file.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func row(_ variable: PipelineVariable) -> some View {
        let isRevealed = revealed.contains(variable.id) || !variable.isSecret
        let nameBinding = Binding(get: { variable.name }, set: { value in workspace.updateVariable(variable.id) { $0.name = value } })
        let valueBinding = Binding(get: { variable.value }, set: { value in workspace.updateVariable(variable.id) { $0.value = value } })
        return HStack(spacing: 8) {
            TextField("name", text: nameBinding)
                .focused($focusedName, equals: variable.id)
                .frame(width: 150)
            Group {
                if isRevealed {
                    TextField("value", text: valueBinding)
                } else {
                    SecureField("value", text: valueBinding)
                }
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                if variable.isSecret {
                    Button {
                        if revealed.contains(variable.id) { revealed.remove(variable.id) } else { revealed.insert(variable.id) }
                    } label: {
                        Image(systemName: revealed.contains(variable.id) ? "eye.slash" : "eye").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 6)
                    .help(revealed.contains(variable.id) ? "Hide value" : "Show value")
                }
            }
            Toggle("", isOn: Binding(get: { variable.isSecret }, set: { value in workspace.updateVariable(variable.id) { $0.isSecret = value } }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .frame(width: 50)
            Button {
                workspace.removeVariable(variable.id)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .frame(width: 20)
            .help("Remove variable")
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12, design: .monospaced))
        .overlay(alignment: .bottomLeading) {
            if !variable.name.isEmpty, !SetVariableStep.isValidName(variable.name) {
                Text("Names use letters, digits and underscores, starting with a letter.")
                    .font(.caption2).foregroundStyle(.red).offset(y: 14)
            }
        }
    }
}

// MARK: - Rename document

struct RenameDocumentSheet: View {
    let doc: DocumentModel
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Document").font(.headline)
            TextField(doc.sourceURL == nil ? "Untitled" : doc.title, text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            Text(doc.sourceURL == nil ? "The name is shown on the tab and in the sidebar." : "Leave empty to show the file name again. The file itself is not renamed.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: commit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { name = doc.customTitle ?? "" }
    }

    private func commit() {
        workspace.rename(doc, to: name)
        dismiss()
    }
}
