import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import JaysonCore

// MARK: - Supporting types

enum SearchMode: String, CaseIterable, Identifiable {
    case text = "Text"
    case jsonPath = "Path"
    var id: String { rawValue }

    var placeholder: String {
        switch self {
        case .text: return "Search keys and values"
        case .jsonPath: return "$.store.book[?(@.price < 10)].title"
        }
    }
}

enum IndentStyle: String, CaseIterable, Identifiable {
    case two = "2 Spaces"
    case four = "4 Spaces"
    case tab = "Tabs"
    var id: String { rawValue }

    var indent: JSONFormatOptions.Indent {
        switch self {
        case .two: return .spaces(2)
        case .four: return .spaces(4)
        case .tab: return .tab
        }
    }
}

struct SearchHit: Identifiable, Hashable, Sendable {
    let path: ValuePath
    let value: JSONValue
    /// "key" / "value" for text search, "" for path queries.
    let detail: String
    var id: String { path.jsonPointer + "|" + detail }
}

struct RevealRequest: Equatable {
    let path: ValuePath
    let tick: Int
}

struct PendingEdit: Identifiable {
    enum Kind { case editValue, renameKey, addProperty }
    let id = UUID()
    let kind: Kind
    let path: ValuePath
    var text: String
    var secondaryText: String = ""
}

enum URLPromptTarget: String, Identifiable {
    case json, schema
    var id: String { rawValue }
}

enum ValidationState: Equatable {
    case noSchema
    case schemaError
    case noDocument
    case valid
    case invalid(Int)
}

struct DocumentStats: Equatable, Sendable {
    var nodes = 0
    var bytes = 0
    var depth = 0
}

private struct ValidationOutcome: Sendable {
    var schema: JSONValue?
    var schemaError: String?
    var errors: [SchemaValidationError]
}

// MARK: - Model

@Observable
@MainActor
final class DocumentModel: Identifiable {
    let id = UUID()
    /// File or remote URL this document was loaded from, if any.
    var sourceURL: URL?
    var customTitle: String?
    /// Called when a schema is inferred/loaded so the workspace can add it to its library.
    var onSchemaInstalled: ((String, String) -> Void)?

    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if let sourceURL { return sourceURL.isFileURL ? sourceURL.lastPathComponent : (sourceURL.host ?? sourceURL.absoluteString) }
        return "Untitled"
    }

    /// Which library schema (if any) this document is validated against.
    var schemaItemID: UUID?

    init(text: String = "") {
        if !text.isEmpty { replaceSource(with: text, parseNow: true) }
    }

    // MARK: Document

    var sourceText: String = "" {
        didSet {
            guard sourceText != oldValue, !suppressParse else { return }
            scheduleParse()
        }
    }
    private(set) var document: JSONValue?
    private(set) var parseError: JSONParseError?
    private(set) var stats = DocumentStats()
    /// UTF-16 range in the editor to select (set when jumping to a parse error).
    var editorHighlight: NSRange?
    var editorHighlightTick = 0

    var indent: IndentStyle = IndentStyle(rawValue: UserDefaults.standard.string(forKey: "indent") ?? "") ?? .two {
        didSet { UserDefaults.standard.set(indent.rawValue, forKey: "indent") }
    }
    var sortKeys = UserDefaults.standard.bool(forKey: "sortKeys") {
        didSet { UserDefaults.standard.set(sortKeys, forKey: "sortKeys") }
    }

    // MARK: Search

    var searchQuery = "" {
        didSet { if searchQuery != oldValue { scheduleSearch() } }
    }
    var searchMode: SearchMode = .text {
        didSet { if searchMode != oldValue { scheduleSearch(immediate: true) } }
    }
    private(set) var hits: [SearchHit] = []
    private(set) var matchedPaths: Set<ValuePath> = []
    private(set) var searchError: String?
    private(set) var currentHitIndex: Int?
    var showResults = false
    var searchFieldFocusRequest = 0

    // MARK: Tree

    var expanded: Set<ValuePath> = [.root]
    var uncappedPaths: Set<ValuePath> = []
    var selectedPath: ValuePath?
    var revealRequest: RevealRequest?
    var pendingEdit: PendingEdit?

    // MARK: Schema

    var showSchemaPanel = false
    var schemaText = "" {
        didSet { if schemaText != oldValue { scheduleValidation() } }
    }
    private(set) var schemaDocument: JSONValue?
    private(set) var schemaError: String?
    private(set) var validationErrors: [SchemaValidationError] = []
    private(set) var errorsByPath: [ValuePath: [SchemaValidationError]] = [:]
    private(set) var validationState: ValidationState = .noSchema
    private(set) var schemaSourceDescription: String?

    // MARK: Misc

    var alertMessage: String?
    private(set) var statusNote: String?
    var urlPrompt: URLPromptTarget?
    weak var undoManager: UndoManager?

    private var suppressParse = false
    private var parseTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var validationTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var revealTick = 0

    // MARK: - Formatting helpers

    var formatOptions: JSONFormatOptions {
        var options = JSONFormatOptions(indent: indent.indent, sortKeys: sortKeys)
        options.sortKeys = sortKeys
        return options
    }

    func formatted(_ value: JSONValue) -> String {
        JSONFormatter.format(value, options: formatOptions)
    }

    // MARK: - Loading

    /// Replaces the editor text and re-parses. Registers an undo step.
    func replaceSource(with text: String, parseNow: Bool = true, actionName: String? = nil) {
        let old = sourceText
        if let actionName, old != text { registerUndo(actionName, from: old, to: text) }
        suppressParse = true
        sourceText = text
        suppressParse = false
        if parseNow {
            parseNowSynchronously()
        } else {
            scheduleParse()
        }
    }

    private func registerUndo(_ actionName: String, from oldText: String, to newText: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.replaceSource(with: oldText, parseNow: true)
                target.registerUndo(actionName, from: newText, to: oldText)
            }
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - Parsing

    private func scheduleParse(delay: Duration = .milliseconds(180)) {
        parseTask?.cancel()
        let text = sourceText
        parseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let outcome = await Task.detached(priority: .userInitiated) { Self.parse(text) }.value
            guard !Task.isCancelled, let self else { return }
            self.apply(parseOutcome: outcome)
        }
    }

    private func parseNowSynchronously() {
        parseTask?.cancel()
        apply(parseOutcome: Self.parse(sourceText))
    }

    private nonisolated static func parse(_ text: String) -> Result<(JSONValue, DocumentStats), JSONParseError> {
        do {
            let value = try JSONParser.parse(text)
            var stats = DocumentStats(nodes: 0, bytes: text.utf8.count, depth: 0)
            value.walk { path, _ in
                stats.nodes += 1
                stats.depth = max(stats.depth, path.count)
            }
            return .success((value, stats))
        } catch let error as JSONParseError {
            return .failure(error)
        } catch {
            return .failure(JSONParseError(message: error.localizedDescription, line: 1, column: 1, offset: 0))
        }
    }

    private func apply(parseOutcome: Result<(JSONValue, DocumentStats), JSONParseError>) {
        switch parseOutcome {
        case .success(let (value, newStats)):
            let isNewShape = document == nil || document?.typeName != value.typeName
            document = value
            stats = newStats
            parseError = nil
            if isNewShape { autoExpand(value) }
        case .failure(let error):
            parseError = error
            if sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                document = nil
                parseError = nil
                stats = DocumentStats()
            }
        }
        scheduleSearch(immediate: true)
        scheduleValidation(immediate: true)
    }

    private func autoExpand(_ value: JSONValue) {
        var set: Set<ValuePath> = [.root]
        // Expand the first two levels when the document is small enough to stay readable.
        if stats.nodes < 2_000 {
            value.walk { path, node in
                if path.count <= 1, node.isContainer { set.insert(path) }
            }
        }
        expanded = set
        uncappedPaths = []
    }

    /// Converts the parser's byte offset into a UTF-16 location for NSTextView.
    func jumpToParseError() {
        guard let error = parseError else { return }
        let utf8 = Array(sourceText.utf8.prefix(error.offset))
        let location = String(decoding: utf8, as: UTF8.self).utf16.count
        editorHighlight = NSRange(location: location, length: 1)
        editorHighlightTick += 1
    }

    // MARK: - Actions on the whole document

    func format() {
        guard let document else { reportParseProblem(); return }
        replaceSource(with: formatted(document), actionName: "Format")
        note("Formatted")
    }

    func minify() {
        guard let document else { reportParseProblem(); return }
        replaceSource(with: JSONFormatter.minify(document, sortKeys: sortKeys), actionName: "Minify")
        note("Minified")
    }

    func clean() {
        do {
            let result = try JSONCleaner.clean(sourceText)
            replaceSource(with: formatted(result.value), actionName: "Clean")
            note(result.notes.isEmpty ? "Already clean" : result.notes.joined(separator: " · "))
        } catch let error as JSONParseError {
            alertMessage = "Could not repair this text.\n\(error.localizedDescription)"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func sortKeysNow() {
        guard let document else { reportParseProblem(); return }
        replaceSource(with: JSONFormatter.format(document.sortingKeys(), options: formatOptions), actionName: "Sort Keys")
        note("Keys sorted")
    }

    func pasteAndFormat() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            note("Clipboard has no text")
            return
        }
        if let value = try? JSONParser.parse(text) {
            replaceSource(with: formatted(value), actionName: "Paste")
            note("Pasted and formatted")
        } else if let cleaned = try? JSONCleaner.clean(text) {
            replaceSource(with: formatted(cleaned.value), actionName: "Paste")
            note("Pasted and repaired")
        } else {
            replaceSource(with: text, actionName: "Paste")
        }
    }

    func copyFormatted() {
        guard let document else { copyToPasteboard(sourceText); return }
        copyToPasteboard(formatted(document))
        note("Copied formatted JSON")
    }

    func copyMinified() {
        guard let document else { reportParseProblem(); return }
        copyToPasteboard(JSONFormatter.minify(document, sortKeys: sortKeys))
        note("Copied minified JSON")
    }

    func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    private func reportParseProblem() {
        if let parseError {
            note("Fix the JSON first: \(parseError.localizedDescription)")
        } else {
            note("Nothing to format")
        }
    }

    // MARK: - Files & URLs

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText, .data]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a JSON file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(from: url, into: .json)
    }

    func openSchemaFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText, .data]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a JSON Schema file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(from: url, into: .schema)
    }

    func saveAs(schema: Bool = false) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = schema ? "schema.json" : "document.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (schema ? schemaText : sourceText).write(to: url, atomically: true, encoding: .utf8)
            note("Saved \(url.lastPathComponent)")
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func load(from url: URL, into target: URLPromptTarget) {
        Task { [weak self] in
            do {
                let data: Data
                if url.isFileURL {
                    data = try Data(contentsOf: url)
                } else {
                    var request = URLRequest(url: url)
                    request.setValue("application/json, application/schema+json;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")
                    let (body, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Server returned HTTP \(http.statusCode)"])
                    }
                    data = body
                }
                guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                guard let self else { return }
                switch target {
                case .json:
                    if let value = try? JSONParser.parse(text) {
                        self.replaceSource(with: self.formatted(value), actionName: "Open")
                    } else {
                        self.replaceSource(with: text, actionName: "Open")
                    }
                    self.sourceURL = url
                    self.note("Loaded \(url.isFileURL ? url.lastPathComponent : url.absoluteString)")
                case .schema:
                    let name = url.isFileURL ? url.lastPathComponent : (url.host.map { $0 + url.path } ?? url.absoluteString)
                    self.installSchema(text: text, source: name)
                    self.note("Loaded schema from \(name)")
                }
            } catch {
                self?.alertMessage = "Could not load \(url.absoluteString)\n\(error.localizedDescription)"
            }
        }
    }

    // MARK: - Search

    private func scheduleSearch(immediate: Bool = false) {
        searchTask?.cancel()
        let query = searchQuery
        let mode = searchMode
        guard let document, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            hits = []
            matchedPaths = []
            searchError = nil
            currentHitIndex = nil
            return
        }
        searchTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            let outcome = await Task.detached(priority: .userInitiated) { Self.search(query, mode: mode, in: document) }.value
            guard !Task.isCancelled, let self else { return }
            let previousFirst = self.hits.first?.path
            self.hits = outcome.hits
            self.searchError = outcome.error
            self.matchedPaths = Set(outcome.hits.map(\.path))
            if outcome.hits.isEmpty {
                self.currentHitIndex = nil
            } else {
                self.currentHitIndex = 0
                if outcome.hits.first?.path != previousFirst {
                    self.reveal(outcome.hits[0].path, select: false)
                }
            }
        }
    }

    private nonisolated static func search(_ query: String, mode: SearchMode, in document: JSONValue) -> (hits: [SearchHit], error: String?) {
        switch mode {
        case .text:
            let matches = TextSearch.search(query, in: document)
            let hits = matches.map { match -> SearchHit in
                let value = document.value(at: match.path) ?? .null
                return SearchHit(path: match.path, value: value, detail: match.kind == .key ? "key" : "value")
            }
            return (hits, nil)
        case .jsonPath:
            do {
                let matches = try JSONPathQuery.evaluate(query, on: document)
                return (matches.map { SearchHit(path: $0.path, value: $0.value, detail: "") }, nil)
            } catch let error as JSONPathError {
                return ([], error.message)
            } catch {
                return ([], error.localizedDescription)
            }
        }
    }

    func nextHit() {
        guard !hits.isEmpty else { return }
        let next = ((currentHitIndex ?? -1) + 1) % hits.count
        currentHitIndex = next
        reveal(hits[next].path)
    }

    func previousHit() {
        guard !hits.isEmpty else { return }
        let prev = ((currentHitIndex ?? 0) - 1 + hits.count) % hits.count
        currentHitIndex = prev
        reveal(hits[prev].path)
    }

    func jump(to hit: SearchHit) {
        if let index = hits.firstIndex(of: hit) { currentHitIndex = index }
        reveal(hit.path)
    }

    var currentHitPath: ValuePath? {
        guard let currentHitIndex, hits.indices.contains(currentHitIndex) else { return nil }
        return hits[currentHitIndex].path
    }

    func copySearchResults() {
        let values = JSONValue.array(hits.map(\.value))
        copyToPasteboard(formatted(values))
        note("Copied \(hits.count) result\(hits.count == 1 ? "" : "s") as a JSON array")
    }

    func focusSearch(mode: SearchMode? = nil) {
        if let mode { searchMode = mode }
        searchFieldFocusRequest += 1
    }

    // MARK: - Tree navigation

    func reveal(_ path: ValuePath, select: Bool = true) {
        var ancestors = ValuePath.root
        expanded.insert(.root)
        for component in path.components.dropLast() {
            ancestors = ancestors.appending(component)
            expanded.insert(ancestors)
        }
        if let parent = path.parent, let index = path.last?.index, index >= TreeLimits.childCap {
            uncappedPaths.insert(parent)
        }
        if select { selectedPath = path }
        revealTick += 1
        revealRequest = RevealRequest(path: path, tick: revealTick)
    }

    func expandAll(below root: ValuePath = .root) {
        guard let document else { return }
        guard let subtree = document.value(at: root) else { return }
        var budget = 20_000
        subtree.walk(from: root) { path, value in
            guard budget > 0, value.isContainer else { return }
            expanded.insert(path)
            budget -= 1
        }
        if budget <= 0 { note("Expanded the first 20,000 containers") }
    }

    func collapseAll(below root: ValuePath = .root) {
        if root.isRoot {
            expanded = [.root]
        } else {
            expanded = expanded.filter { !$0.hasPrefix(root) || $0 == root }
            expanded.remove(root)
        }
    }

    // MARK: - Tree editing

    private func mutateDocument(_ actionName: String, _ body: (inout JSONValue) throws -> Void) -> String? {
        guard var doc = document else { return "The JSON has errors; fix them before editing the tree." }
        do {
            try body(&doc)
        } catch {
            return error.localizedDescription
        }
        replaceSource(with: formatted(doc), parseNow: true, actionName: actionName)
        return nil
    }

    func remove(at path: ValuePath) {
        if let message = mutateDocument("Delete", { try $0.remove(at: path) }) {
            alertMessage = message
        } else {
            if selectedPath == path { selectedPath = nil }
            note("Deleted \(path.jsonPathString)")
        }
    }

    func duplicate(at path: ValuePath) {
        guard let document, let value = document.value(at: path), let parent = path.parent, let last = path.last else { return }
        let message: String?
        switch last {
        case .index(let i):
            message = mutateDocument("Duplicate") { try $0.insert(value, intoArrayAt: parent, at: i + 1) }
            if message == nil { reveal(parent.appending(index: i + 1)) }
        case .key(let key):
            let siblings = document.value(at: parent)?.objectValue?.keys ?? []
            var candidate = key + " copy"
            var n = 2
            while siblings.contains(candidate) { candidate = "\(key) copy \(n)"; n += 1 }
            let position = (siblings.firstIndex(of: key) ?? siblings.count) + 1
            message = mutateDocument("Duplicate") { try $0.insert(value, forKey: candidate, intoObjectAt: parent, at: position) }
            if message == nil { reveal(parent.appending(key: candidate)) }
        }
        if let message { alertMessage = message }
    }

    /// Appends (or inserts after `index`) a new element whose shape is derived from the
    /// loaded schema when it describes this array, otherwise from the existing elements.
    func addArrayItem(to arrayPath: ValuePath, after index: Int? = nil) {
        guard let document, let elements = document.value(at: arrayPath)?.arrayValue else { return }
        let (template, source) = newItemTemplate(for: arrayPath, elements: elements)
        let insertAt = index.map { $0 + 1 } ?? elements.count
        if let message = mutateDocument("Add Item", { try $0.insert(template, intoArrayAt: arrayPath, at: insertAt) }) {
            alertMessage = message
            return
        }
        let newPath = arrayPath.appending(index: insertAt)
        expanded.insert(newPath)
        reveal(newPath)
        note("Added item \(source)")
    }

    private func newItemTemplate(for arrayPath: ValuePath, elements: [JSONValue]) -> (JSONValue, String) {
        let result = ArrayItemTemplate.make(forArrayAt: arrayPath, elements: elements, schema: schemaDocument)
        switch result.source {
        case .schema: return (result.value, "from the loaded schema")
        case .empty: return (result.value, "(empty object)")
        case .inferredFromSiblings(let count): return (result.value, "matching the shape of the other \(count) item\(count == 1 ? "" : "s")")
        }
    }

    /// Schema inferred from an array's existing elements, shown to the user on request.
    func inferredItemSchema(forArrayAt arrayPath: ValuePath) -> JSONValue? {
        guard let elements = document?.value(at: arrayPath)?.arrayValue, !elements.isEmpty else { return nil }
        var options = SchemaInferenceOptions()
        options.addSchemaKeyword = true
        return SchemaInferrer.infer(fromSamples: elements, options: options)
    }

    func beginEditValue(at path: ValuePath) {
        guard let value = document?.value(at: path) else { return }
        pendingEdit = PendingEdit(kind: .editValue, path: path, text: formatted(value))
    }

    func beginRenameKey(at path: ValuePath) {
        guard case .key(let key)? = path.last else { return }
        pendingEdit = PendingEdit(kind: .renameKey, path: path, text: key)
    }

    func beginAddProperty(to objectPath: ValuePath) {
        pendingEdit = PendingEdit(kind: .addProperty, path: objectPath, text: "", secondaryText: "null")
    }

    /// Applies a sheet edit. Returns an error message to show inline, or nil on success.
    func apply(_ edit: PendingEdit) -> String? {
        switch edit.kind {
        case .editValue:
            let newValue: JSONValue
            do { newValue = try JSONParser.parse(edit.text, options: .lenient) } catch { return error.localizedDescription }
            let message = mutateDocument("Edit Value") { try $0.set(newValue, at: edit.path) }
            if message == nil { reveal(edit.path) }
            return message
        case .renameKey:
            let newKey = edit.text
            guard !newKey.isEmpty else { return "Key cannot be empty" }
            guard let parent = edit.path.parent, let siblings = document?.value(at: parent)?.objectValue else { return "Not an object member" }
            if newKey != edit.path.last?.key, siblings.contains(newKey) { return "A property named \"\(newKey)\" already exists" }
            let message = mutateDocument("Rename Key") { try $0.renameKey(at: edit.path, to: newKey) }
            if message == nil { reveal(parent.appending(key: newKey)) }
            return message
        case .addProperty:
            let key = edit.text
            guard !key.isEmpty else { return "Key cannot be empty" }
            guard let object = document?.value(at: edit.path)?.objectValue else { return "Not an object" }
            if object.contains(key) { return "A property named \"\(key)\" already exists" }
            let newValue: JSONValue
            do { newValue = try JSONParser.parse(edit.secondaryText, options: .lenient) } catch { return error.localizedDescription }
            let message = mutateDocument("Add Property") { try $0.insert(newValue, forKey: key, intoObjectAt: edit.path) }
            if message == nil { reveal(edit.path.appending(key: key)) }
            return message
        }
    }

    func copyValue(at path: ValuePath) {
        guard let value = document?.value(at: path) else { return }
        copyToPasteboard(formatted(value))
        note("Copied value")
    }

    func copyPath(_ path: ValuePath) {
        copyToPasteboard(path.jsonPathString)
        note("Copied \(path.jsonPathString)")
    }

    func copyPointer(_ path: ValuePath) {
        copyToPasteboard(path.jsonPointer.isEmpty ? "/" : path.jsonPointer)
        note("Copied JSON Pointer")
    }

    func queryFromTree(_ path: ValuePath) {
        searchMode = .jsonPath
        searchQuery = path.jsonPathString
        focusSearch()
    }

    // MARK: - Schema

    /// Sets the active schema text and tells the workspace about it (library + panel).
    func installSchema(text: String, source: String) {
        schemaText = text
        schemaSourceDescription = source
        showSchemaPanel = true
        onSchemaInstalled?(text, source)
    }

    /// Applies a schema without reporting it back (used when picking from the library).
    func useSchema(text: String, source: String?, itemID: UUID?) {
        schemaItemID = itemID
        schemaText = text
        schemaSourceDescription = source
    }

    func inferSchema() {
        guard let document else { reportParseProblem(); return }
        var options = SchemaInferenceOptions()
        options.detectFormats = true
        let schema = SchemaInferrer.infer(from: document, options: options)
        installSchema(text: JSONFormatter.format(schema, options: JSONFormatOptions(indent: indent.indent)), source: "Inferred from \(title)")
        note("Inferred a schema from the current JSON")
    }

    func inferSchemaFromArray(at path: ValuePath) {
        guard let schema = inferredItemSchema(forArrayAt: path) else { return }
        installSchema(text: JSONFormatter.format(schema, options: JSONFormatOptions(indent: indent.indent)), source: "Items of \(path.jsonPathString)")
    }

    func newBlankSchema() {
        installSchema(text: SampleData.schemaTemplate, source: "New schema")
    }

    func clearSchema() {
        schemaItemID = nil
        schemaText = ""
        schemaSourceDescription = nil
    }

    func formatSchema() {
        guard let schemaDocument else { return }
        schemaText = JSONFormatter.format(schemaDocument, options: JSONFormatOptions(indent: indent.indent))
    }

    func copySchema() {
        copyToPasteboard(schemaText)
        note("Copied schema")
    }

    func validateNow() {
        scheduleValidation(immediate: true)
    }

    private func scheduleValidation(immediate: Bool = false) {
        validationTask?.cancel()
        let schemaText = schemaText
        let document = document
        guard !schemaText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            schemaDocument = nil
            schemaError = nil
            validationErrors = []
            errorsByPath = [:]
            validationState = .noSchema
            return
        }
        validationTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled else { return }
            let outcome = await Task.detached(priority: .userInitiated) { Self.validate(schemaText: schemaText, document: document) }.value
            guard !Task.isCancelled, let self else { return }
            self.schemaDocument = outcome.schema
            self.schemaError = outcome.schemaError
            self.validationErrors = outcome.errors
            self.errorsByPath = Dictionary(grouping: outcome.errors, by: \.instancePath)
            if outcome.schemaError != nil {
                self.validationState = .schemaError
            } else if document == nil {
                self.validationState = .noDocument
            } else if outcome.errors.isEmpty {
                self.validationState = .valid
            } else {
                self.validationState = .invalid(outcome.errors.count)
            }
        }
    }

    private nonisolated static func validate(schemaText: String, document: JSONValue?) -> ValidationOutcome {
        let schema: JSONValue
        do {
            schema = try JSONParser.parse(schemaText)
        } catch {
            do {
                schema = try JSONParser.parse(schemaText, options: .lenient)
            } catch let lenientError as JSONParseError {
                return ValidationOutcome(schema: nil, schemaError: lenientError.localizedDescription, errors: [])
            } catch {
                return ValidationOutcome(schema: nil, schemaError: error.localizedDescription, errors: [])
            }
        }
        guard let document else { return ValidationOutcome(schema: schema, schemaError: nil, errors: []) }
        let result = SchemaValidator.validate(document, against: schema)
        return ValidationOutcome(schema: schema, schemaError: nil, errors: result.errors)
    }

    func errors(at path: ValuePath) -> [SchemaValidationError] {
        errorsByPath[path] ?? []
    }

    // MARK: - Status

    func note(_ message: String) {
        statusNote = message
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.statusNote = nil
        }
    }
}

enum TreeLimits {
    /// Arrays/objects longer than this show a "Show all" row instead of every child.
    static let childCap = 500
}
