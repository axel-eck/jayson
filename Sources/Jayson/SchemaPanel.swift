import SwiftUI
import JaysonCore

/// Right-hand panel: schema editor and validation results, like regex101's match list.
struct SchemaPanel: View {
    @Bindable var doc: DocumentModel
    @Environment(Workspace.self) private var workspace
    @State private var tab: Tab = .schema

    enum Tab: Hashable { case schema, results }

    var body: some View {
        VStack(spacing: 0) {
            header
            PillSegmented(
                segments: [
                    .init(value: Tab.schema, title: "Schema", systemImage: "curlybraces"),
                    .init(value: Tab.results, title: "Results", systemImage: "checklist", badge: doc.validationErrors.count),
                ],
                selection: $tab
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            Hairline()
            Group {
                switch tab {
                case .schema: schemaEditor
                case .results: results
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Hairline()
            footer
        }
        .frame(width: Chrome.panelWidth)
        .frame(maxHeight: .infinity)
        .background(Chrome.contentBackground)
        .overlay(alignment: .leading) { Hairline(vertical: true) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(doc.schemaSourceDescription ?? "Schema").font(Chrome.titleFont).lineLimit(1).truncationMode(.middle)
                Text(doc.schemaItemID == nil ? "Not saved in library" : "In library · applied to \(doc.title)")
                    .font(Chrome.captionFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            IconButton(systemImage: "wand.and.stars", help: "Infer from current JSON (⇧⌘I)") { doc.inferSchema() }
                .disabled(doc.document == nil)
            Menu {
                Button("New Blank Schema") { doc.newBlankSchema() }
                Button("Infer from Current JSON") { doc.inferSchema() }.disabled(doc.document == nil)
                Divider()
                Button("Open Schema File…") { doc.openSchemaFile() }
                Button("Load Schema from URL…") { doc.urlPrompt = .schema }
                if !workspace.schemas.isEmpty {
                    Menu("Apply from Library") {
                        ForEach(workspace.schemas) { item in
                            Button(item.name) { workspace.apply(item, to: doc) }
                        }
                    }
                }
                Divider()
                Button("Format Schema") { doc.formatSchema() }.disabled(doc.schemaDocument == nil)
                Button("Copy Schema") { doc.copySchema() }.disabled(doc.schemaText.isEmpty)
                Button("Save Schema As…") { doc.saveAs(schema: true) }.disabled(doc.schemaText.isEmpty)
                Divider()
                Button("Detach from Document") { workspace.detachSchema(from: doc) }.disabled(doc.schemaText.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            IconButton(systemImage: "xmark", help: "Close panel (⌥⌘I)") { workspace.toggleSchemaPanel() }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: Chrome.headerHeight)
    }

    // MARK: Schema editor

    private var schemaEditor: some View {
        SourceEditor(text: schemaTextBinding)
            .overlay {
                if doc.schemaText.isEmpty { emptyHint }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var schemaTextBinding: Binding<String> {
        Binding(
            get: { doc.schemaText },
            set: { newValue in
                doc.schemaText = newValue
                workspace.updateSchemaText(newValue, for: doc.schemaItemID)
            }
        )
    }

    private var emptyHint: some View {
        EmptyState(systemImage: "checkmark.shield", title: "No schema yet", message: "Infer one from the JSON, start from a blank template, or load a schema from a file or URL. You can also paste one here.") {
            ChromeButton(title: "Infer", systemImage: "wand.and.stars") { doc.inferSchema() }
                .disabled(doc.document == nil)
            ChromeButton(title: "Blank", systemImage: "doc") { doc.newBlankSchema() }
            ChromeButton(title: "Open…", systemImage: "folder") { doc.openSchemaFile() }
        }
        .allowsHitTesting(true)
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        if let schemaError = doc.schemaError {
            EmptyState(systemImage: "exclamationmark.triangle", title: "Schema is not valid JSON", message: schemaError, tint: .orange) {
                ChromeButton(title: "Edit Schema", systemImage: "pencil") { tab = .schema }
            }
        } else if doc.schemaText.isEmpty {
            EmptyState(systemImage: "checklist", title: "No schema", message: "Add a schema to see validation results here.") {
                ChromeButton(title: "Infer from JSON", systemImage: "wand.and.stars") { doc.inferSchema() }
                    .disabled(doc.document == nil)
                ChromeButton(title: "Edit Schema", systemImage: "pencil") { tab = .schema }
            }
        } else if doc.document == nil {
            EmptyState(systemImage: "clock", title: doc.parseError == nil ? "Waiting for JSON" : "Waiting for valid JSON", message: doc.parseError == nil ? "Paste or type a document to validate it." : "Fix the document's syntax errors to validate it.")
        } else if doc.validationErrors.isEmpty {
            EmptyState(systemImage: "checkmark.circle.fill", title: "Valid", message: "\(doc.title) satisfies this schema.", tint: .green)
        } else {
            List(doc.validationErrors) { error in
                ValidationErrorRow(error: error)
                    .contentShape(Rectangle())
                    .onTapGesture { doc.reveal(error.instancePath) }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            statusIcon
            Text(statusText).font(Chrome.captionFont).foregroundStyle(.secondary)
            Spacer()
            if case .invalid = doc.validationState, tab == .schema {
                Button("Show") { tab = .results }.buttonStyle(.link).font(Chrome.captionFont)
            }
            IconButton(systemImage: "arrow.clockwise", help: "Validate now (⌘R)", size: 22) { doc.validateNow() }
                .disabled(doc.schemaText.isEmpty)
        }
        .padding(.horizontal, 12)
        .frame(height: Chrome.statusBarHeight + 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch doc.validationState {
        case .noSchema, .noDocument: StatusDot(color: .secondary.opacity(0.4))
        case .schemaError: StatusDot(color: .orange)
        case .valid: StatusDot(color: .green)
        case .invalid: StatusDot(color: .red)
        }
    }

    private var statusText: String {
        switch doc.validationState {
        case .noSchema: return "No schema"
        case .noDocument: return "Waiting for valid JSON"
        case .schemaError: return "Schema has syntax errors"
        case .valid: return "Document is valid"
        case .invalid(let count): return "\(count) validation error\(count == 1 ? "" : "s")"
        }
    }
}

struct ValidationErrorRow: View {
    let error: SchemaValidationError
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 12))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(error.message).font(.system(size: 12.5))
                HStack(spacing: 6) {
                    Text(error.instancePath.jsonPathString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(error.keyword)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Chrome.fill))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Chrome.hover : .clear))
        .onHover { hovering = $0 }
        .help(error.schemaPath)
    }
}
