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
    private(set) var documents: [DocumentModel] = []
    var selectedDocumentID: UUID?
    var schemas: [SchemaItem] = [] {
        didSet { persistSchemas() }
    }

    var isSidebarVisible = true
    var isSchemaPanelVisible = false
    var viewMode: ViewMode = .split
    var sidebarFocusSearchRequest = 0

    private static let libraryKey = "schemaLibrary"
    private var untitledCounter = 0

    init(openSample: Bool = true) {
        loadSchemas()
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
