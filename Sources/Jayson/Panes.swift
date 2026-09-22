import SwiftUI
import JaysonCore

struct SourcePane: View {
    @Environment(DocumentModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            SourceEditor(text: $model.sourceText, highlight: model.editorHighlight, highlightTick: model.editorHighlightTick)
            if let error = model.parseError {
                Hairline()
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error.localizedDescription).lineLimit(2).font(.system(size: 12))
                    Spacer()
                    ChromeButton(title: "Go to Error", systemImage: "arrow.right.circle") { model.jumpToParseError() }
                    ChromeButton(title: "Clean Up", systemImage: "sparkles") { model.clean() }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.10))
            }
        }
    }
}

struct TreePane: View {
    @Environment(DocumentModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.parseError != nil, model.document != nil {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                    Text("Showing the last valid JSON while the source has errors.")
                        .font(Chrome.captionFont)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Chrome.fill)
                Hairline()
            }
            JSONTreeView()
            if model.showResults, !model.searchQuery.isEmpty {
                Hairline()
                ResultsList()
                    .frame(height: 220)
            }
        }
        .background(Chrome.contentBackground)
    }
}

struct ResultsList: View {
    @Environment(DocumentModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(headerText).font(.system(size: 12, weight: .medium))
                Spacer()
                ChromeButton(title: "Copy Results", systemImage: "doc.on.doc") { model.copySearchResults() }
                    .disabled(model.hits.isEmpty)
                IconButton(systemImage: "xmark", help: "Hide results", size: 24) { model.showResults = false }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Hairline()
            if let error = model.searchError {
                ContentUnavailableView {
                    Label("Invalid query", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else {
                List(model.hits, selection: Binding(get: { model.currentHitPath }, set: { _ in })) { hit in
                    HStack(spacing: 8) {
                        Text(hit.path.jsonPathString)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(JSONFormatter.preview(hit.value, maxLength: 60))
                            .font(Theme.treeFont)
                            .foregroundStyle(Theme.color(for: hit.value))
                            .lineLimit(1)
                        if !hit.detail.isEmpty {
                            Text(hit.detail).font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                    .tag(hit.path)
                    .contentShape(Rectangle())
                    .onTapGesture { model.jump(to: hit) }
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Chrome.contentBackground)
    }

    private var headerText: String {
        let n = model.hits.count
        return model.searchMode == .jsonPath ? "\(n) result\(n == 1 ? "" : "s")" : "\(n) match\(n == 1 ? "" : "es")"
    }
}

struct StatusBar: View {
    @Environment(DocumentModel.self) private var model
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: 10) {
            if let error = model.parseError {
                HStack(spacing: 5) {
                    StatusDot(color: .red)
                    Text(error.localizedDescription).lineLimit(1)
                }
            } else if model.document != nil {
                HStack(spacing: 5) {
                    StatusDot(color: .green)
                    Text("Valid JSON")
                }
                Text(statsText)
            } else {
                Text("Empty document")
            }

            if let note = model.statusNote {
                Text("·").foregroundStyle(.tertiary)
                Text(note).lineLimit(1).transition(.opacity)
            }

            Spacer()

            if let path = model.selectedPath {
                Button {
                    model.copyPath(path)
                } label: {
                    Text(path.jsonPathString)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help("Click to copy this path")
            }

            switch model.validationState {
            case .noSchema, .noDocument:
                EmptyView()
            case .schemaError:
                HStack(spacing: 5) { StatusDot(color: .orange); Text("Schema error") }
            case .valid:
                HStack(spacing: 5) { StatusDot(color: .green); Text("Schema valid") }
            case .invalid(let count):
                Button {
                    workspace.isSchemaPanelVisible = true
                    model.showSchemaPanel = true
                } label: {
                    HStack(spacing: 5) { StatusDot(color: .red); Text("\(count) schema error\(count == 1 ? "" : "s")") }
                }
                .buttonStyle(.plain)
            }
        }
        .font(Chrome.captionFont)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: Chrome.statusBarHeight)
        .background(Chrome.contentBackground)
        .animation(.easeInOut(duration: 0.15), value: model.statusNote)
    }

    private var statsText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let size = formatter.string(fromByteCount: Int64(model.stats.bytes))
        return "\(size) · \(model.stats.nodes.formatted()) nodes · depth \(model.stats.depth)"
    }
}
