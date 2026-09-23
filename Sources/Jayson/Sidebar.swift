import SwiftUI
import JaysonCore

struct Sidebar: View {
    @Environment(Workspace.self) private var workspace
    @FocusState private var searchFocused: Bool
    @State private var renamingSchema: SchemaItem?
    @State private var renamingPipeline: Pipeline?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let doc = workspace.selectedDocument {
                searchSection(doc)
                    .id(doc.id)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    documentsSection
                    schemasSection
                    pipelinesSection
                }
                .padding(.bottom, 12)
            }
            Spacer(minLength: 0)
            footer
        }
        .frame(width: Chrome.sidebarWidth)
        .background(Chrome.sidebarBackground)
        .overlay(alignment: .trailing) { Hairline(vertical: true) }
        .onChange(of: workspace.sidebarFocusSearchRequest) { _, _ in searchFocused = true }
        .sheet(item: $renamingSchema) { item in
            renameSheet(item)
        }
        .sheet(item: $renamingPipeline) { item in
            renamePipelineSheet(item)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: Chrome.trafficLightInset - 12)
            Text("Jayson").font(Chrome.titleFont)
            Spacer()
            IconButton(systemImage: "sidebar.left", help: "Hide Sidebar (⌃⌘S)") { workspace.toggleSidebar() }
        }
        .padding(.horizontal, 12)
        .frame(height: Chrome.headerHeight)
    }

    // MARK: Search

    @ViewBuilder
    private func searchSection(_ doc: DocumentModel) -> some View {
        @Bindable var doc = doc
        VStack(alignment: .leading, spacing: 8) {
            SearchPill(
                placeholder: doc.searchMode == .text ? "Search" : "$.path[?(@.filter)]",
                text: $doc.searchQuery,
                systemImage: doc.searchMode == .text ? "magnifyingglass" : "chevron.left.forwardslash.chevron.right",
                monospaced: doc.searchMode == .jsonPath,
                hasError: doc.searchError != nil,
                focus: $searchFocused,
                onSubmit: { doc.nextHit() }
            )
            PillSegmented(
                segments: [
                    .init(value: SearchMode.text, title: "Text", systemImage: "textformat"),
                    .init(value: SearchMode.jsonPath, title: "Path", systemImage: "chevron.left.forwardslash.chevron.right"),
                ],
                selection: $doc.searchMode
            )
            if !doc.searchQuery.isEmpty {
                HStack(spacing: 6) {
                    if let error = doc.searchError {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 11))
                        Text(error).font(Chrome.captionFont).foregroundStyle(.secondary).lineLimit(2)
                    } else {
                        Text(matchSummary(doc)).font(Chrome.captionFont.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        IconButton(systemImage: "chevron.up", help: "Previous (⇧⌘G)", size: 22) { doc.previousHit() }
                            .disabled(doc.hits.isEmpty)
                        IconButton(systemImage: "chevron.down", help: "Next (⌘G)", size: 22) { doc.nextHit() }
                            .disabled(doc.hits.isEmpty)
                        IconButton(systemImage: "list.bullet.rectangle", help: "Show results list", size: 22, isActive: doc.showResults) {
                            doc.showResults.toggle()
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func matchSummary(_ doc: DocumentModel) -> String {
        let n = doc.hits.count
        if n == 0 { return "No matches" }
        let noun = doc.searchMode == .jsonPath ? "result" : "match"
        return "\((doc.currentHitIndex ?? 0) + 1) of \(n) \(noun)\(n == 1 ? "" : (noun == "match" ? "es" : "s"))"
    }

    // MARK: Documents

    private var documentsSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionHeader(title: "Documents") {
                Menu {
                    Button("New Empty Document") { workspace.newDocument(select: true) }
                    Button("New from Clipboard") { workspace.newDocumentFromPasteboard() }
                    Divider()
                    Button("Open Files…") { workspace.openDocumentFromFile() }
                    Button("Open from URL…") {
                        let doc = workspace.newDocument(select: true)
                        doc.urlPrompt = .json
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New document")
            }
            ForEach(workspace.documents) { doc in
                SidebarRow(
                    title: doc.title,
                    subtitle: documentSubtitle(doc),
                    isSelected: workspace.selectedDocument?.id == doc.id,
                    action: { workspace.select(doc) }
                ) {
                    StatusDot(color: documentColor(doc))
                } trailing: {
                    if let run = doc.pipelineRun, doc.pipeline != nil {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10.5))
                            .foregroundStyle(run.isSuccess ? Color.green : (run.isDeferred ? Color.orange : Color.red))
                    }
                    if doc.schemaItemID != nil {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 10.5))
                            .foregroundStyle(schemaColor(doc))
                    }
                }
                .contextMenu {
                    Button("Rename…") { workspace.documentToRename = doc }
                    Button("Close") { workspace.close(doc) }
                    Button("Duplicate") {
                        let copy = workspace.newDocument(text: doc.sourceText, select: true)
                        copy.customTitle = doc.title + " copy"
                    }
                    if let url = doc.sourceURL, url.isFileURL {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    if doc.schemaItemID != nil {
                        Divider()
                        Button("Detach Schema") { workspace.detachSchema(from: doc) }
                    }
                }
            }
        }
    }

    private func documentSubtitle(_ doc: DocumentModel) -> String {
        if let error = doc.parseError {
            return "Line \(error.line): \(error.message)"
        }
        if doc.document == nil { return "Empty" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: Int64(doc.stats.bytes))) · \(doc.stats.nodes.formatted()) nodes"
    }

    private func documentColor(_ doc: DocumentModel) -> Color {
        if doc.parseError != nil { return .red }
        if doc.document == nil { return .secondary.opacity(0.5) }
        return .green
    }

    private func schemaColor(_ doc: DocumentModel) -> Color {
        switch doc.validationState {
        case .valid: return .green
        case .invalid: return .red
        case .schemaError: return .orange
        default: return .secondary
        }
    }

    // MARK: Schemas

    private var schemasSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionHeader(title: "Schemas") {
                Menu {
                    Button("Infer from Current JSON") { workspace.selectedDocument?.inferSchema() }
                        .disabled(workspace.selectedDocument?.document == nil)
                    Button("New Blank Schema") { workspace.selectedDocument?.newBlankSchema() }
                    Divider()
                    Button("Open Schema File…") { workspace.selectedDocument?.openSchemaFile() }
                    Button("Load Schema from URL…") { workspace.selectedDocument?.urlPrompt = .schema }
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add schema")
            }
            if workspace.schemas.isEmpty {
                Text("Infer one from your JSON, or load a schema from a file or URL. Schemas stay here between launches.")
                    .font(Chrome.captionFont)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            }
            ForEach(workspace.schemas) { item in
                let applied = workspace.selectedDocument?.schemaItemID == item.id
                SidebarRow(
                    title: item.name,
                    subtitle: item.source == item.name ? nil : item.source,
                    isSelected: applied,
                    action: {
                        guard let doc = workspace.selectedDocument else { return }
                        if applied {
                            workspace.isSchemaPanelVisible = true
                            doc.showSchemaPanel = true
                        } else {
                            workspace.apply(item, to: doc)
                        }
                    }
                ) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 12))
                        .foregroundStyle(applied ? Color.accentColor : .secondary)
                } trailing: {
                    if applied, let doc = workspace.selectedDocument {
                        switch doc.validationState {
                        case .valid: StatusDot(color: .green)
                        case .invalid(let n):
                            Text("\(n)")
                                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.red))
                        case .schemaError: StatusDot(color: .orange)
                        default: EmptyView()
                        }
                    }
                }
                .contextMenu {
                    Button("Apply to Current Document") { if let doc = workspace.selectedDocument { workspace.apply(item, to: doc) } }
                    Button("Rename…") {
                        renameText = item.name
                        renamingSchema = item
                    }
                    Button("Copy Schema") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.text, forType: .string)
                    }
                    Button("Save As…") { saveSchema(item) }
                    Divider()
                    Button("Remove from Library", role: .destructive) { workspace.remove(item) }
                }
            }
        }
    }

    // MARK: Pipelines

    private var pipelinesSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionHeader(title: "Pipelines") {
                Menu {
                    Button("New Pipeline") { workspace.newPipeline() }
                    Button("Import Pipeline…") { workspace.importPipeline() }
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New pipeline")
            }
            if workspace.pipelines.isEmpty {
                Text("Chain scripts, JSONPath selections and flattening to transform JSON. Pipelines stay here and work on any document.")
                    .font(Chrome.captionFont)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            }
            ForEach(workspace.pipelines) { item in
                let doc = workspace.selectedDocument
                let applied = doc?.pipeline?.id == item.id
                SidebarRow(
                    title: item.name,
                    subtitle: pipelineSubtitle(item),
                    isSelected: applied,
                    action: {
                        guard let doc else { return }
                        if applied {
                            workspace.showPipelinePanel()
                        } else {
                            workspace.attach(item, to: doc)
                        }
                    }
                ) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 12))
                        .foregroundStyle(applied ? Color.accentColor : .secondary)
                } trailing: {
                    if applied, let doc {
                        if doc.isPipelineRunning {
                            ProgressView().controlSize(.mini)
                        } else if let run = doc.pipelineRun {
                            StatusDot(color: run.isSuccess ? .green : (run.isDeferred ? .orange : .red))
                        }
                    }
                }
                .contextMenu {
                    Button("Run on Current Document") { if let doc { workspace.attach(item, to: doc) } }
                    Button("Rename…") {
                        renameText = item.name
                        renamingPipeline = item
                    }
                    Button("Duplicate") { workspace.duplicate(item) }
                    Button("Export…") { workspace.exportPipeline(item) }
                    Divider()
                    if applied {
                        Button("Detach from Document") { if let doc { workspace.detachPipeline(from: doc) } }
                    }
                    Button("Remove from Library", role: .destructive) { workspace.remove(item) }
                }
            }
        }
    }

    private func pipelineSubtitle(_ item: Pipeline) -> String {
        let count = item.steps.count
        let kinds = item.steps.map { $0.kind.title }
        let summary = Array(NSOrderedSet(array: kinds)).compactMap { $0 as? String }.joined(separator: ", ")
        return "\(count) step\(count == 1 ? "" : "s")\(summary.isEmpty ? "" : " · " + summary)"
    }

    private func renamePipelineSheet(_ item: Pipeline) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Pipeline").font(.headline)
            TextField("Name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { workspace.rename(item, to: renameText); renamingPipeline = nil }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { renamingPipeline = nil }.keyboardShortcut(.cancelAction)
                Button("Rename") { workspace.rename(item, to: renameText); renamingPipeline = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func saveSchema(_ item: SchemaItem) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = item.name.hasSuffix(".json") ? item.name : item.name + ".schema.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? item.text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func renameSheet(_ item: SchemaItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Schema").font(.headline)
            TextField("Name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { workspace.rename(item, to: renameText); renamingSchema = nil }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { renamingSchema = nil }.keyboardShortcut(.cancelAction)
                Button("Rename") { workspace.rename(item, to: renameText); renamingSchema = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 4) {
            if let doc = workspace.selectedDocument {
                Menu {
                    Picker("Indentation", selection: Bindable(doc).indent) {
                        ForEach(IndentStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Sort Keys When Formatting", isOn: Bindable(doc).sortKeys)
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Formatting preferences")
            }
            IconButton(systemImage: "questionmark.circle", help: "Keyboard shortcuts and help") {
                workspace.selectedDocument?.note("⇧⌘F Format · ⇧⌘M Minify · ⇧⌘K Clean · ⌘F Search · ⇧⌘P Path query · ⇧⌘I Infer schema · ⌥⌘I Schema panel")
            }
            Spacer()
            IconButton(systemImage: "arrow.triangle.branch", help: "Toggle Pipeline Panel (⌥⌘P)", isActive: workspace.isPipelinePanelVisible) {
                workspace.togglePipelinePanel()
            }
            IconButton(systemImage: "sidebar.right", help: "Toggle Schema Panel (⌥⌘I)", isActive: workspace.isSchemaPanelVisible) {
                workspace.toggleSchemaPanel()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }
}
