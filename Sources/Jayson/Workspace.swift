import AppKit
import Observation
import SwiftUI

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

/// Per-window state: open documents (tabs), the schema library, and chrome visibility.
@Observable
@MainActor
final class Workspace {
    private(set) var documents: [DocumentModel] = [] {
        didSet { scheduleSessionSave() }
    }
    var selectedDocumentID: UUID? {
        didSet { scheduleSessionSave() }
    }
    var schemas: [SchemaItem] = [] {
        didSet { scheduleSessionSave() }
    }

    var isSidebarVisible = true {
        didSet { scheduleSessionSave() }
    }
    var isSchemaPanelVisible = false {
        didSet { scheduleSessionSave() }
    }
    var viewMode: ViewMode = .split {
        didSet { scheduleSessionSave() }
    }
    var sidebarFocusSearchRequest = 0

    private var untitledCounter = 0

    /// Session saving is off until `activate()` runs, so a `Workspace` that SwiftUI builds and
    /// discards while evaluating `@State` never overwrites the session of the live one.
    private var isActive = false
    private var saveTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?

    /// Restores the previous session. The sample document appears only on the very first launch;
    /// afterwards the user gets back exactly the documents they had open when they quit.
    init() {
        if let session = SessionStore.load() {
            restore(session)
        } else {
            schemas = SessionStore.loadLegacySchemas()
            if SessionStore.isFirstLaunch {
                let doc = newDocument(text: SampleData.json, select: true)
                doc.customTitle = "Sample"
            }
        }
        if documents.isEmpty { newDocument(select: true) }
    }

    /// Call once the window showing this workspace is on screen.
    func activate() {
        guard !isActive else { return }
        isActive = true
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSessionNow() }
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
        attach(doc)
        documents.append(doc)
        if select { selectedDocumentID = doc.id }
        return doc
    }

    /// Wires the callbacks every document in this workspace needs.
    private func attach(_ doc: DocumentModel) {
        doc.onSchemaInstalled = { [weak self, weak doc] text, source in
            guard let self, let doc else { return }
            self.registerSchema(text: text, source: source, for: doc)
        }
        doc.onStateChanged = { [weak self] in self?.scheduleSessionSave() }
        doc.showSchemaPanel = isSchemaPanelVisible
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

    // MARK: - Session

    private func restore(_ session: SessionSnapshot) {
        schemas = session.schemas
        viewMode = ViewMode(rawValue: session.viewMode) ?? .split
        isSidebarVisible = session.isSidebarVisible
        isSchemaPanelVisible = session.isSchemaPanelVisible
        for snapshot in session.documents {
            let doc = DocumentModel(id: snapshot.id, text: snapshot.sourceText)
            doc.customTitle = snapshot.customTitle
            doc.sourceURL = snapshot.sourceURL
            if let itemID = snapshot.schemaItemID, let item = schemas.first(where: { $0.id == itemID }) {
                doc.useSchema(text: item.text, source: item.name, itemID: item.id)
            } else if !snapshot.schemaText.isEmpty {
                doc.useSchema(text: snapshot.schemaText, source: snapshot.schemaSource, itemID: nil)
            }
            attach(doc)
            documents.append(doc)
        }
        untitledCounter = documents.count
        if let id = session.selectedDocumentID, documents.contains(where: { $0.id == id }) {
            selectedDocumentID = id
        } else {
            selectedDocumentID = documents.first?.id
        }
    }

    private var snapshot: SessionSnapshot {
        SessionSnapshot(
            documents: documents.map { doc in
                DocumentSnapshot(
                    id: doc.id,
                    customTitle: doc.customTitle,
                    sourceURL: doc.sourceURL,
                    sourceText: doc.sourceText,
                    schemaItemID: doc.schemaItemID,
                    schemaText: doc.schemaItemID == nil ? doc.schemaText : "",
                    schemaSource: doc.schemaItemID == nil ? doc.schemaSourceDescription : nil
                )
            },
            selectedDocumentID: selectedDocument?.id,
            schemas: schemas,
            viewMode: viewMode.rawValue,
            isSidebarVisible: isSidebarVisible,
            isSchemaPanelVisible: isSchemaPanelVisible
        )
    }

    /// Coalesces rapid changes (typing) into one write shortly after they stop.
    private func scheduleSessionSave() {
        guard isActive else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveSessionNow()
        }
    }

    func saveSessionNow() {
        guard isActive else { return }
        saveTask?.cancel()
        saveTask = nil
        SessionStore.save(snapshot)
    }

    // MARK: - Chrome

    func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.18)) { isSidebarVisible.toggle() }
    }

    func toggleSchemaPanel() {
        withAnimation(.easeInOut(duration: 0.18)) { isSchemaPanelVisible.toggle() }
        selectedDocument?.showSchemaPanel = isSchemaPanelVisible
    }

    func focusSidebarSearch(mode: SearchMode? = nil) {
        if !isSidebarVisible { isSidebarVisible = true }
        if let mode { selectedDocument?.searchMode = mode }
        sidebarFocusSearchRequest += 1
    }
}
