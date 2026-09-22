import SwiftUI
import JaysonCore

struct ContentView: View {
    @State private var model = AppModel()
    @FocusState private var searchFocused: Bool
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var model = model
        HSplitView {
            SourcePane()
                .frame(minWidth: 320, idealWidth: 520)
                .layoutPriority(1)
            TreePane()
                .frame(minWidth: 360, idealWidth: 600)
                .layoutPriority(1)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
        .inspector(isPresented: $model.showSchemaPanel) {
            SchemaPanel()
                .inspectorColumnWidth(min: 320, ideal: 440, max: 800)
        }
        .toolbar { toolbarContent }
        .sheet(item: $model.pendingEdit) { edit in EditSheet(edit: edit) }
        .sheet(item: $model.urlPrompt) { target in URLPromptSheet(target: target) }
        .alert("Jayson", isPresented: alertPresented, presenting: model.alertMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .environment(model)
        .focusedSceneValue(\.appModel, model)
        .onAppear {
            model.undoManager = undoManager
            model.loadSampleIfEmpty()
        }
        .onChange(of: undoManager) { _, newValue in model.undoManager = newValue }
        .onChange(of: model.searchFieldFocusRequest) { _, _ in searchFocused = true }
        .navigationTitle("Jayson")
        .frame(minWidth: 900, minHeight: 520)
    }

    private var alertPresented: Binding<Bool> {
        Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.pasteAndFormat() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                .help("Replace with the clipboard contents and format (⌥⇧⌘V)")
            Button { model.copyFormatted() } label: { Label("Copy", systemImage: "doc.on.doc") }
                .help("Copy formatted JSON (⇧⌘C)")
        }

        ToolbarItemGroup(placement: .principal) {
            Button { model.format() } label: { Label("Format", systemImage: "text.alignleft") }
                .help("Pretty-print (⇧⌘F)")
            Button { model.minify() } label: { Label("Minify", systemImage: "arrow.down.right.and.arrow.up.left") }
                .help("Minify to one line (⇧⌘M)")
            Button { model.clean() } label: { Label("Clean", systemImage: "sparkles") }
                .help("Repair comments, trailing commas, quotes and string-encoded JSON, then format (⇧⌘K)")
            Menu {
                Picker("Indentation", selection: Bindable(model).indent) {
                    ForEach(IndentStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Sort Keys When Formatting", isOn: Bindable(model).sortKeys)
                Divider()
                Button("Sort Keys Now") { model.sortKeysNow() }
                Button("Copy Minified") { model.copyMinified() }
            } label: {
                Label("Formatting Options", systemImage: "slider.horizontal.3")
            }
            .menuIndicator(.hidden)
        }

        ToolbarItem(placement: .primaryAction) {
            SearchBar(searchFocused: $searchFocused)
        }

        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: Bindable(model).showSchemaPanel) {
                Label("Schema", systemImage: "checkmark.shield")
            }
            .help("Show the JSON Schema panel (⌥⌘I)")
        }
    }
}

// MARK: - Search bar

struct SearchBar: View {
    @Environment(AppModel.self) private var model
    @FocusState.Binding var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 6) {
            Picker("Mode", selection: $model.searchMode) {
                ForEach(SearchMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Text: match keys and values. Path: JSONPath query such as $.items[*].id")

            HStack(spacing: 4) {
                Image(systemName: model.searchMode == .text ? "magnifyingglass" : "chevron.left.forwardslash.chevron.right")
                    .foregroundStyle(.secondary)
                TextField(model.searchMode.placeholder, text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .font(model.searchMode == .jsonPath ? .body.monospaced() : .body)
                    .focused($searchFocused)
                    .onSubmit { model.nextHit() }
                    .frame(minWidth: 220, idealWidth: 300)
                if !model.searchQuery.isEmpty {
                    Button { model.searchQuery = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(model.searchError == nil ? Color.clear : Color.red.opacity(0.7)))
            .help(model.searchError ?? "")

            if !model.searchQuery.isEmpty {
                Text(countText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(model.searchError == nil ? .secondary : Color.red)
                    .frame(minWidth: 44)
                Button { model.previousHit() } label: { Image(systemName: "chevron.up") }
                    .disabled(model.hits.isEmpty)
                    .help("Previous match (⇧⌘G)")
                Button { model.nextHit() } label: { Image(systemName: "chevron.down") }
                    .disabled(model.hits.isEmpty)
                    .help("Next match (⌘G)")
                Toggle(isOn: $model.showResults) { Image(systemName: "list.bullet.below.rectangle") }
                    .toggleStyle(.button)
                    .help("Show results list")
            }
        }
    }

    private var countText: String {
        if model.searchError != nil { return "error" }
        guard !model.hits.isEmpty else { return "0" }
        return "\((model.currentHitIndex ?? 0) + 1)/\(model.hits.count)"
    }
}

// MARK: - Panes

struct SourcePane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            SourceEditor(text: $model.sourceText, highlight: model.editorHighlight, highlightTick: model.editorHighlightTick)
            if let error = model.parseError {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error.localizedDescription).lineLimit(2).font(.callout)
                    Spacer()
                    Button("Go to Error") { model.jumpToParseError() }.controlSize(.small)
                    Button("Clean Up") { model.clean() }.controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.orange.opacity(0.12))
            }
        }
    }
}

struct TreePane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.parseError != nil, model.document != nil {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                    Text("Showing the last valid JSON while the source has errors.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.bar)
                Divider()
            }
            JSONTreeView()
            if model.showResults, !model.searchQuery.isEmpty {
                Divider()
                ResultsList()
                    .frame(height: 200)
            }
        }
    }
}

struct ResultsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(headerText).font(.subheadline)
                Spacer()
                Button("Copy Results") { model.copySearchResults() }
                    .controlSize(.small)
                    .disabled(model.hits.isEmpty)
                Button { model.showResults = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()
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
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(JSONFormatter.preview(hit.value, maxLength: 60))
                            .font(Theme.treeFont)
                            .foregroundStyle(Theme.color(for: hit.value))
                            .lineLimit(1)
                        if !hit.detail.isEmpty {
                            Text(hit.detail).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .tag(hit.path)
                    .contentShape(Rectangle())
                    .onTapGesture { model.jump(to: hit) }
                }
                .listStyle(.inset)
            }
        }
    }

    private var headerText: String {
        let n = model.hits.count
        return model.searchMode == .jsonPath ? "\(n) result\(n == 1 ? "" : "s")" : "\(n) match\(n == 1 ? "" : "es")"
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            if let error = model.parseError {
                Label(error.localizedDescription, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else if model.document != nil {
                Label("Valid JSON", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(statsText).foregroundStyle(.secondary)
            } else {
                Text("No document").foregroundStyle(.secondary)
            }

            if let note = model.statusNote {
                Divider().frame(height: 12)
                Text(note).foregroundStyle(.secondary).lineLimit(1)
                    .transition(.opacity)
            }

            Spacer()

            if let path = model.selectedPath {
                Button {
                    model.copyPath(path)
                } label: {
                    Text(path.jsonPathString)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Click to copy this path")
            }

            switch model.validationState {
            case .noSchema, .noDocument:
                EmptyView()
            case .schemaError:
                Label("Schema error", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .valid:
                Label("Schema: valid", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
            case .invalid(let count):
                Button {
                    model.showSchemaPanel = true
                } label: {
                    Label("\(count) schema error\(count == 1 ? "" : "s")", systemImage: "xmark.shield.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .animation(.easeInOut(duration: 0.15), value: model.statusNote)
    }

    private var statsText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let size = formatter.string(fromByteCount: Int64(model.stats.bytes))
        return "\(size) · \(model.stats.nodes.formatted()) nodes · depth \(model.stats.depth)"
    }
}
