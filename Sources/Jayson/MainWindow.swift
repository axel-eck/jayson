import SwiftUI
import UniformTypeIdentifiers
import JaysonCore

/// Root of the window: sidebar | tabbed document area | optional schema panel.
struct MainWindow: View {
    @State private var workspace = Workspace()
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        HStack(spacing: 0) {
            if workspace.isSidebarVisible {
                Sidebar()
                    .transition(.move(edge: .leading))
            }
            VStack(spacing: 0) {
                TabBar()
                Hairline()
                if let doc = workspace.selectedDocument {
                    DocumentArea(doc: doc)
                        .id(doc.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Chrome.contentBackground)
            .frame(minWidth: Chrome.minDocumentWidth)
            .layoutPriority(1)
            if let doc = workspace.selectedDocument {
                switch workspace.rightPanel {
                case .schema:
                    SchemaPanel(doc: doc)
                        .id(doc.id)
                        .transition(.move(edge: .trailing))
                case .pipeline:
                    PipelinePanel(doc: doc)
                        .id(doc.id)
                        .transition(.move(edge: .trailing))
                case nil:
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Chrome.contentBackground)
        .environment(workspace)
        .focusedSceneValue(\.workspace, workspace)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .onAppear { propagateUndoManager() }
        .onChange(of: undoManager) { _, _ in propagateUndoManager() }
        .onChange(of: workspace.selectedDocumentID) { _, _ in propagateUndoManager() }
        .frame(minWidth: minimumWindowWidth, minHeight: 560)
        .ignoresSafeArea()
    }

    /// The window can never be narrower than the panels that are currently shown.
    private var minimumWindowWidth: CGFloat {
        Chrome.minDocumentWidth
            + (workspace.isSidebarVisible ? Chrome.sidebarWidth : 0)
            + (workspace.isSchemaPanelVisible ? Chrome.panelWidth : 0)
            + (workspace.isPipelinePanelVisible ? Chrome.pipelinePanelWidth : 0)
    }

    private func propagateUndoManager() {
        for doc in workspace.documents { doc.undoManager = undoManager }
    }

    /// Dropped files open as documents; a file with "schema" in its name loads as a schema.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    if url.lastPathComponent.lowercased().contains("schema"), let doc = workspace.selectedDocument {
                        doc.load(from: url, into: .schema)
                    } else {
                        let target = (workspace.selectedDocument?.sourceText.isEmpty == true) ? workspace.selectedDocument! : workspace.newDocument(select: true)
                        target.load(from: url, into: .json)
                    }
                }
            }
        }
        return true
    }
}

// MARK: - Tab bar

struct TabBar: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        HStack(spacing: 8) {
            if !workspace.isSidebarVisible {
                Spacer().frame(width: Chrome.trafficLightInset - 12)
                IconButton(systemImage: "sidebar.left", help: "Show Sidebar (⌃⌘S)") { workspace.toggleSidebar() }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(workspace.documents) { doc in
                        TabItem(doc: doc, isSelected: workspace.selectedDocument?.id == doc.id)
                    }
                    IconButton(systemImage: "plus", help: "New Document (⌘N)", size: 26) { workspace.newDocument(select: true) }
                        .padding(.leading, 2)
                }
                .padding(.vertical, 6)
            }
            Spacer(minLength: 8)
            if let doc = workspace.selectedDocument {
                HStack(spacing: 6) {
                    ChromeButton(title: "Format", systemImage: "text.alignleft", help: "Pretty-print (⇧⌘F)") { doc.format() }
                        .fixedSize()
                    ChromeButton(title: "Clean", systemImage: "sparkles", help: "Repair and format messy JSON (⇧⌘K)") { doc.clean() }
                        .fixedSize()
                    Menu {
                        Button("Minify") { doc.minify() }
                        Button("Sort Keys") { doc.sortKeysNow() }
                        Divider()
                        Button("Paste and Format") { doc.pasteAndFormat() }
                        Button("Copy Formatted") { doc.copyFormatted() }
                        Button("Copy Minified") { doc.copyMinified() }
                        Divider()
                        Button("Save As…") { doc.saveAs() }
                        Button("Load Sample JSON") { doc.replaceSource(with: SampleData.json, actionName: "Load Sample") }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Chrome.fill))
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More actions")
                }
                Hairline(vertical: true).frame(height: 18).padding(.horizontal, 4)
                PillSegmented(
                    segments: ViewMode.allCases.map { .init(value: $0, title: $0.title, systemImage: $0.systemImage) },
                    selection: $workspace.viewMode,
                    iconOnly: true
                )
                IconButton(systemImage: "arrow.triangle.branch", help: "Toggle Pipeline Panel (⌥⌘P)", isActive: workspace.isPipelinePanelVisible) {
                    workspace.togglePipelinePanel()
                }
                IconButton(systemImage: "sidebar.right", help: "Toggle Schema Panel (⌥⌘I)", isActive: workspace.isSchemaPanelVisible) {
                    workspace.toggleSchemaPanel()
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .frame(height: Chrome.tabBarHeight)
        .background(Chrome.contentBackground)
    }
}

struct TabItem: View {
    let doc: DocumentModel
    let isSelected: Bool
    @Environment(Workspace.self) private var workspace
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            StatusDot(color: dotColor)
            Text(doc.title)
                .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
            Button {
                workspace.close(doc)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(hovering ? Chrome.fill : .clear))
            }
            .buttonStyle(.plain)
            .opacity(hovering || isSelected ? 1 : 0)
            .help("Close (⌘W)")
        }
        .padding(.leading, 11)
        .padding(.trailing, 6)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Chrome.selection : (hovering ? Chrome.hover : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { workspace.select(doc) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Close") { workspace.close(doc) }
            Button("Close Others") { for other in workspace.documents where other.id != doc.id { workspace.close(other) } }
        }
    }

    private var dotColor: Color {
        if doc.parseError != nil { return .red }
        if doc.document == nil { return .secondary.opacity(0.4) }
        if case .invalid = doc.validationState { return .orange }
        if let run = doc.pipelineRun, !run.isSuccess, !run.isDeferred { return .orange }
        return .green
    }
}

// MARK: - Document area

struct DocumentArea: View {
    @Bindable var doc: DocumentModel
    @Environment(Workspace.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Hairline()
            StatusBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(doc)
        .focusedSceneValue(\.document, doc)
        .sheet(item: $doc.pendingEdit) { edit in EditSheet(edit: edit).environment(doc) }
        .sheet(item: $doc.urlPrompt) { target in URLPromptSheet(target: target).environment(doc) }
        .alert("Jayson", isPresented: alertPresented, presenting: doc.alertMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch workspace.viewMode {
        case .source:
            SourcePane()
        case .tree:
            TreePane()
        case .split:
            HSplitView {
                SourcePane().frame(minWidth: 220, idealWidth: 480)
                TreePane().frame(minWidth: 220)
            }
        }
    }

    private var alertPresented: Binding<Bool> {
        Binding(get: { doc.alertMessage != nil }, set: { if !$0 { doc.alertMessage = nil } })
    }
}

// MARK: - Focused values

struct WorkspaceFocusedKey: FocusedValueKey { typealias Value = Workspace }
struct DocumentFocusedKey: FocusedValueKey { typealias Value = DocumentModel }

extension FocusedValues {
    var workspace: Workspace? {
        get { self[WorkspaceFocusedKey.self] }
        set { self[WorkspaceFocusedKey.self] = newValue }
    }
    var document: DocumentModel? {
        get { self[DocumentFocusedKey.self] }
        set { self[DocumentFocusedKey.self] = newValue }
    }
}
