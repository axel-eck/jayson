import SwiftUI
import JaysonCore

struct SchemaPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Divider()
            VSplitView {
                SourceEditor(text: $model.schemaText)
                    .frame(minHeight: 160)
                    .overlay(alignment: .center) {
                        if model.schemaText.isEmpty { emptyHint }
                    }
                validationSection
                    .frame(minHeight: 120, idealHeight: 220)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("JSON Schema").font(.headline)
                if let source = model.schemaSourceDescription {
                    Text(source).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Button {
                model.inferSchema()
            } label: {
                Label("Infer", systemImage: "wand.and.stars")
            }
            .help("Infer a schema from the current JSON (⇧⌘I)")
            .disabled(model.document == nil)

            Menu {
                Button("New Blank Schema") { model.newBlankSchema() }
                Divider()
                Button("Open File…") { model.openSchemaFile() }
                Button("Load from URL…") { model.urlPrompt = .schema }
                Divider()
                Button("Format Schema") { model.formatSchema() }.disabled(model.schemaDocument == nil)
                Button("Copy Schema") { model.copySchema() }.disabled(model.schemaText.isEmpty)
                Button("Save Schema As…") { model.saveAs(schema: true) }.disabled(model.schemaText.isEmpty)
                Divider()
                Button("Clear", role: .destructive) { model.clearSchema() }.disabled(model.schemaText.isEmpty)
            } label: {
                Label("Schema Actions", systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.shield").font(.system(size: 30)).foregroundStyle(.tertiary)
            Text("Paste a schema, infer one from the JSON,\nor load one from a file or URL.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)
            HStack {
                Button("Infer from JSON") { model.inferSchema() }.disabled(model.document == nil)
                Button("New Blank") { model.newBlankSchema() }
            }
        }
        .allowsHitTesting(true)
        .padding()
    }

    private var validationSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                statusIcon
                Text(statusText).font(.subheadline)
                Spacer()
                Button {
                    model.validateNow()
                } label: {
                    Label("Validate", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help("Validate now (⌘R)")
                .disabled(model.schemaText.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()

            if let schemaError = model.schemaError {
                ContentUnavailableView {
                    Label("Schema is not valid JSON", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(schemaError)
                }
            } else if model.validationErrors.isEmpty {
                Color.clear
            } else {
                List(model.validationErrors) { error in
                    ValidationErrorRow(error: error)
                        .contentShape(Rectangle())
                        .onTapGesture { model.reveal(error.instancePath) }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch model.validationState {
        case .noSchema, .noDocument: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .schemaError: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .valid: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .invalid: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private var statusText: String {
        switch model.validationState {
        case .noSchema: return "No schema"
        case .noDocument: return "Waiting for valid JSON"
        case .schemaError: return "Schema has errors"
        case .valid: return "JSON is valid against the schema"
        case .invalid(let count): return "\(count) validation error\(count == 1 ? "" : "s")"
        }
    }
}

struct ValidationErrorRow: View {
    let error: SchemaValidationError

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(error.message)
            HStack(spacing: 6) {
                Text(error.instancePath.jsonPathString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(error.keyword)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .help(error.schemaPath)
    }
}
