import AppKit
import Observation
import SwiftUI
import JaysonCore

/// A schema kept in the sidebar library. Persisted across launches.
struct SchemaItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var text: String
    var source: String?
}

enum ViewMode: String, CaseIterable, Identifiable {
    case source, split, tree
    var id: String { rawValue }

    var title: String {
        switch self {
        case .source: return "Source"
        case .split: return "Split"
        case .tree: return "Tree"
        }
    }

    var systemImage: String {
        switch self {
        case .source: return "text.alignleft"
        case .split: return "rectangle.split.2x1"
        case .tree: return "list.bullet.indent"
        }
    }
}

/// Which inspector is open on the right. Only one fits next to the document area.
enum RightPanel: Equatable {
    case schema, pipeline
}

/// Per-window state: open documents (tabs), the schema and pipeline libraries, and chrome visibility.
@Observable
@MainActor
final class Workspace {
    private(set) var documents: [DocumentModel] = []
    var selectedDocumentID: UUID?
    var schemas: [SchemaItem] = [] {
        didSet { persistSchemas() }
    }
    /// Reusable pipelines. Persisted across launches; any document can run any of them.
    var pipelines: [Pipeline] = [] {
        didSet { if pipelines != oldValue { persistPipelines(); rerunPipelines() } }
    }

    var isSidebarVisible = true
    var rightPanel: RightPanel?
    var viewMode: ViewMode = .split
    var sidebarFocusSearchRequest = 0

    var isSchemaPanelVisible: Bool {
        get { rightPanel == .schema }
        set { if newValue { rightPanel = .schema } else if rightPanel == .schema { rightPanel = nil } }
    }

    var isPipelinePanelVisible: Bool {
        get { rightPanel == .pipeline }
        set { if newValue { rightPanel = .pipeline } else if rightPanel == .pipeline { rightPanel = nil } }
    }

    private static let libraryKey = "schemaLibrary"
    private static let pipelineLibraryKey = "pipelineLibrary"
    private var untitledCounter = 0

    init(openSample: Bool = true) {
        loadSchemas()
        loadPipelines()
        if openSample {
            let doc = newDocument(text: SampleData.json, select: true)
            doc.customTitle = "Sample"
        } else {
            newDocument(select: true)
        }
    }

    var selectedDocument: DocumentModel? {
        documents.first { $0.id == selectedDocumentID } ?? documents.first
    }

    // MARK: - Documents

    @discardableResult
    func newDocument(text: String = "", select: Bool = true) -> DocumentModel {
        let doc = DocumentModel(text: text)
        untitledCounter += 1
        if untitledCounter > 1 { doc.customTitle = "Untitled \(untitledCounter)" }
        doc.onSchemaInstalled = { [weak self, weak doc] text, source in
            guard let self, let doc else { return }
            self.registerSchema(text: text, source: source, for: doc)
        }
        doc.showSchemaPanel = isSchemaPanelVisible
        doc.pipelineLibraryProvider = { [weak self] in self?.pipelines ?? [] }
        doc.onPipelineEdited = { [weak self] pipeline in self?.update(pipeline) }
        documents.append(doc)
        if select { selectedDocumentID = doc.id }
        return doc
    }

    func select(_ doc: DocumentModel) {
        selectedDocumentID = doc.id
    }

    func close(_ doc: DocumentModel) {
        guard let index = documents.firstIndex(where: { $0.id == doc.id }) else { return }
        documents.remove(at: index)
        if selectedDocumentID == doc.id {
            let fallback = documents.indices.contains(index) ? documents[index] : documents.last
            selectedDocumentID = fallback?.id
        }
        if documents.isEmpty { newDocument(select: true) }
    }

    func closeSelectedDocument() {
        if let selectedDocument { close(selectedDocument) }
    }

    func selectNextDocument(offset: Int) {
        guard let current = selectedDocument, let index = documents.firstIndex(where: { $0.id == current.id }), documents.count > 1 else { return }
        let next = (index + offset + documents.count) % documents.count
        selectedDocumentID = documents[next].id
    }

    func openDocumentFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText, .data]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose JSON files"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let doc = newDocument(select: true)
            doc.load(from: url, into: .json)
        }
    }

    func newDocumentFromPasteboard() {
        let doc = newDocument(select: true)
        doc.pasteAndFormat()
    }

    // MARK: - Schema library

    /// Adds a schema produced by a document (inferred, loaded) to the library and links it.
    func registerSchema(text: String, source: String, for doc: DocumentModel) {
        var name = source
        if let item = schemas.first(where: { $0.text == text }) {
            doc.schemaItemID = item.id
            isSchemaPanelVisible = true
            doc.showSchemaPanel = true
            return
        }
        let existingNames = Set(schemas.map(\.name))
        if existingNames.contains(name) {
            var n = 2
            while existingNames.contains("\(source) \(n)") { n += 1 }
            name = "\(source) \(n)"
        }
        let item = SchemaItem(name: name, text: text, source: source)
        schemas.append(item)
        doc.schemaItemID = item.id
        isSchemaPanelVisible = true
        doc.showSchemaPanel = true
    }

    func apply(_ item: SchemaItem, to doc: DocumentModel) {
        doc.useSchema(text: item.text, source: item.name, itemID: item.id)
        isSchemaPanelVisible = true
        doc.showSchemaPanel = true
    }

    /// Keeps the library copy in sync while the user edits the schema in the panel.
    func updateSchemaText(_ text: String, for id: UUID?) {
        guard let id, let index = schemas.firstIndex(where: { $0.id == id }) else { return }
        if schemas[index].text != text { schemas[index].text = text }
    }

    func rename(_ item: SchemaItem, to name: String) {
        guard let index = schemas.firstIndex(where: { $0.id == item.id }), !name.isEmpty else { return }
        schemas[index].name = name
        for doc in documents where doc.schemaItemID == item.id {
            doc.useSchema(text: schemas[index].text, source: name, itemID: item.id)
        }
    }

    func remove(_ item: SchemaItem) {
        schemas.removeAll { $0.id == item.id }
        for doc in documents where doc.schemaItemID == item.id {
            doc.clearSchema()
        }
    }

    func detachSchema(from doc: DocumentModel) {
        doc.clearSchema()
    }

    private func loadSchemas() {
        guard let data = UserDefaults.standard.data(forKey: Self.libraryKey),
              let items = try? JSONDecoder().decode([SchemaItem].self, from: data) else { return }
        schemas = items
    }

    private func persistSchemas() {
        if let data = try? JSONEncoder().encode(schemas) {
            UserDefaults.standard.set(data, forKey: Self.libraryKey)
        }
    }

    // MARK: - Pipeline library

    /// Creates an empty pipeline, adds it to the library and opens it on `doc`. Steps are
    /// added from the panel, where the block type (script, HTTP, …) is chosen.
    @discardableResult
    func newPipeline(for doc: DocumentModel? = nil) -> Pipeline {
        let existing = Set(pipelines.map(\.name))
        var name = "Pipeline"
        var n = 2
        while existing.contains(name) { name = "Pipeline \(n)"; n += 1 }
        let pipeline = Pipeline(name: name, steps: [])
        pipelines.append(pipeline)
        if let doc = doc ?? selectedDocument { attach(pipeline, to: doc) }
        return pipeline
    }

    func attach(_ pipeline: Pipeline, to doc: DocumentModel) {
        doc.pipeline = pipeline
        doc.selectedStepID = pipeline.steps.last?.id
        showPipelinePanel()
    }

    func detachPipeline(from doc: DocumentModel) {
        doc.pipeline = nil
        doc.selectedStepID = nil
    }

    /// Stores an edited pipeline and pushes it to every document running it.
    func update(_ pipeline: Pipeline) {
        if let index = pipelines.firstIndex(where: { $0.id == pipeline.id }) {
            if pipelines[index] != pipeline { pipelines[index] = pipeline }
        } else {
            pipelines.append(pipeline)
        }
        for doc in documents where doc.pipeline?.id == pipeline.id && doc.pipeline != pipeline {
            doc.pipeline = pipeline
        }
    }

    func rename(_ pipeline: Pipeline, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, var updated = pipelines.first(where: { $0.id == pipeline.id }) else { return }
        updated.name = trimmed
        update(updated)
    }

    func duplicate(_ pipeline: Pipeline) {
        var copy = pipeline
        copy.id = UUID()
        copy.name = pipeline.name + " copy"
        copy.steps = pipeline.steps.map { step in
            var step = step
            step.id = UUID()
            return step
        }
        pipelines.append(copy)
    }

    func remove(_ pipeline: Pipeline) {
        pipelines.removeAll { $0.id == pipeline.id }
        for doc in documents where doc.pipeline?.id == pipeline.id {
            detachPipeline(from: doc)
        }
    }

    func exportPipeline(_ pipeline: Pipeline) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = pipeline.name + "." + Pipeline.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try pipeline.exportJSON().write(to: url, options: .atomic)
            selectedDocument?.note("Exported \(url.lastPathComponent)")
        } catch {
            selectedDocument?.alertMessage = error.localizedDescription
        }
    }

    func importPipeline() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose an exported pipeline"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var pipeline = try Pipeline.importJSON(Data(contentsOf: url))
            if pipelines.contains(where: { $0.id == pipeline.id }) { pipeline.id = UUID() }
            pipelines.append(pipeline)
            if let doc = selectedDocument { attach(pipeline, to: doc) }
        } catch {
            selectedDocument?.alertMessage = "Could not import \(url.lastPathComponent)\n\(error.localizedDescription)"
        }
    }

    private func rerunPipelines() {
        for doc in documents where doc.pipeline != nil {
            doc.schedulePipelineRun(immediate: true)
        }
    }

    private func loadPipelines() {
        guard let data = UserDefaults.standard.data(forKey: Self.pipelineLibraryKey),
              let items = try? JSONDecoder().decode([Pipeline].self, from: data) else { return }
        pipelines = items
    }

    private func persistPipelines() {
        if let data = try? JSONEncoder().encode(pipelines) {
            UserDefaults.standard.set(data, forKey: Self.pipelineLibraryKey)
        }
    }

    // MARK: - Chrome

    func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.18)) { isSidebarVisible.toggle() }
    }

    func toggleSchemaPanel() {
        withAnimation(.easeInOut(duration: 0.18)) { isSchemaPanelVisible.toggle() }
        selectedDocument?.showSchemaPanel = isSchemaPanelVisible
    }

    func togglePipelinePanel() {
        withAnimation(.easeInOut(duration: 0.18)) { isPipelinePanelVisible.toggle() }
        if isPipelinePanelVisible { selectedDocument?.showSchemaPanel = false }
    }

    func showPipelinePanel() {
        guard !isPipelinePanelVisible else { return }
        withAnimation(.easeInOut(duration: 0.18)) { rightPanel = .pipeline }
        selectedDocument?.showSchemaPanel = false
    }

    func focusSidebarSearch(mode: SearchMode? = nil) {
        if !isSidebarVisible { isSidebarVisible = true }
        if let mode { selectedDocument?.searchMode = mode }
        sidebarFocusSearchRequest += 1
    }
}
