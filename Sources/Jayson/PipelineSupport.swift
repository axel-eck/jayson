import AppKit
import Foundation
@preconcurrency import JaysonCore

/// Pipeline behaviour of a document: running the attached pipeline against the parsed JSON,
/// editing its steps, previewing step outputs and type-checking TypeScript steps.
extension DocumentModel {
    /// Largest output preview rendered in the panel; bigger outputs are cut and flagged.
    nonisolated static let previewLimit = 300_000

    // MARK: - Running

    /// Live runs (typing, document edits) never send HTTP requests; `allowNetwork` runs do.
    func schedulePipelineRun(immediate: Bool = false, allowNetwork: Bool = false) {
        pipelineTask?.cancel()
        guard let pipeline else {
            pipelineRun = nil
            isPipelineRunning = false
            stepPreview = ""
            stepDiagnostics = [:]
            return
        }
        guard let document else {
            pipelineRun = nil
            isPipelineRunning = false
            refreshStepPreview()
            return
        }
        let schema = schemaDocument
        let library = pipelineLibraryProvider?() ?? []
        let variables = variablesProvider?() ?? [:]
        let cache = httpCache
        isPipelineRunning = true
        pipelineTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            var runner = PipelineRunner(resolvePipeline: { id in library.first { $0.id == id } })
            runner.httpCache = cache
            runner.networkPolicy = allowNetwork ? .allow : .cachedOnly
            let result = await Task.detached(priority: .userInitiated) { await runner.run(pipeline, input: document, schema: schema, variables: variables) }.value
            guard !Task.isCancelled, let self else { return }
            self.pipelineRun = result
            self.isPipelineRunning = false
            self.refreshStepPreview()
            self.scheduleTypeCheck()
            if !result.savedVariables.isEmpty { self.onVariablesSaved?(result.savedVariables) }
        }
    }

    /// Explicit run: sends HTTP requests again (dropping cached responses).
    func runPipelineNow() {
        httpCache.removeAll()
        schedulePipelineRun(immediate: true, allowNetwork: true)
    }

    /// Result of the selected step (nil for the input row or before the first run). For a
    /// step inside a For Each this is its result for the selected item.
    var selectedStepResult: PipelineStepResult? {
        guard let selectedStepID, let pipelineRun else { return nil }
        return pipelineRun.result(for: selectedStepID, iteration: selectedIteration)
    }

    /// The For Each result whose iterations ran the selected step, if it is inside a loop.
    var selectedLoopResult: PipelineStepResult? {
        guard let selectedStepID, let pipelineRun else { return nil }
        return pipelineRun.loopResult(containing: selectedStepID)
    }

    var selectedStep: PipelineStep? {
        guard let selectedStepID else { return nil }
        return pipeline?.step(withID: selectedStepID)
    }

    /// The JSON shown in the output pane: the selected step's output, or the document.
    var selectedStepValue: JSONValue? {
        if selectedStepID == nil { return document }
        return selectedStepResult?.output
    }

    // MARK: - Editing

    /// Applies an edit to the attached pipeline and reports it to the workspace.
    func updatePipeline(_ body: (inout Pipeline) -> Void) {
        guard var edited = pipeline else { return }
        body(&edited)
        guard edited != pipeline else { return }
        pipeline = edited
        onPipelineEdited?(edited)
    }

    func updateStep(_ id: UUID, _ body: (inout PipelineStep) -> Void) {
        updatePipeline { pipeline in
            pipeline.updateStep(id, body)
        }
    }

    /// Adds a step after `after`, or inside the For Each `inside`, or at the end.
    @discardableResult
    func addStep(_ kind: PipelineStepKind, after id: UUID? = nil, inside parentID: UUID? = nil) -> PipelineStep {
        let step = PipelineStep(kind: kind)
        updatePipeline { pipeline in
            pipeline.insert(step, after: id, inside: parentID)
        }
        selectedStepID = step.id
        return step
    }

    func removeStep(_ id: UUID) {
        guard let pipeline, pipeline.step(withID: id) != nil else { return }
        let parentID = pipeline.entry(for: id)?.parentID
        let wasSelectedInside = selectedStepID.map { selected in
            selected == id || pipeline.allSteps.contains { $0.step.id == selected && $0.parentID == id }
        } ?? false
        var replacement: PipelineStep?
        updatePipeline { replacement = $0.remove(id) }
        if wasSelectedInside {
            selectedStepID = replacement?.id ?? parentID
        }
    }

    func moveStep(_ id: UUID, by offset: Int) {
        updatePipeline { $0.move(id, by: offset) }
    }

    func duplicateStep(_ id: UUID) {
        guard let pipeline, let original = pipeline.step(withID: id) else { return }
        let copy = original.withFreshIDs()
        updatePipeline { $0.insert(copy, after: id) }
        selectedStepID = copy.id
    }

    func setScriptCode(_ code: String, for id: UUID) {
        updateStep(id) { step in
            guard case .script(let language, let old) = step.kind, old != code else { return }
            step.kind = .script(language: language, code: code)
        }
    }

    func setScriptLanguage(_ language: ScriptLanguage, for id: UUID) {
        updateStep(id) { step in
            guard case .script(let old, let code) = step.kind, old != language else { return }
            let isStarter = code == Pipeline.starterCode(for: old)
            step.kind = .script(language: language, code: isStarter ? Pipeline.starterCode(for: language) : code)
        }
    }

    // MARK: - Output actions

    func copySelectedStepOutput() {
        guard let value = selectedStepValue else { return }
        copyToPasteboard(formatted(value))
        note("Copied step output")
    }

    func replaceDocumentWithPipelineOutput() {
        guard let output = pipelineRun?.output else {
            note(pipelineRun == nil ? "Run the pipeline first" : "The pipeline has errors; fix them first")
            return
        }
        replaceSource(with: formatted(output), actionName: "Apply Pipeline")
        note("Replaced the document with the pipeline output")
    }

    func savePipelineOutput() {
        guard let output = pipelineRun?.output else { note("The pipeline has no output yet"); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "output.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try formatted(output).write(to: url, atomically: true, encoding: .utf8)
            note("Saved \(url.lastPathComponent)")
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: - Preview

    /// Formats the selected step's value off the main thread for the read-only output editor.
    func refreshStepPreview() {
        previewTask?.cancel()
        guard let value = selectedStepValue else {
            stepPreview = ""
            stepPreviewTruncated = false
            return
        }
        let options = formatOptions
        previewTask = Task { [weak self] in
            let (text, truncated) = await Task.detached(priority: .userInitiated) { () -> (String, Bool) in
                let text = JSONFormatter.format(value, options: options)
                if text.count > DocumentModel.previewLimit {
                    return (String(text.prefix(DocumentModel.previewLimit)), true)
                }
                return (text, false)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.stepPreview = text
            self.stepPreviewTruncated = truncated
        }
    }

    // MARK: - Types

    /// Input type for a step: the loaded schema while the step still reads the document,
    /// otherwise a type inferred from the step's actual input after the last run.
    func typeDeclarations(for stepID: UUID) -> String {
        let input = pipelineRun?.result(for: stepID, iteration: selectedIteration)?.input ?? (pipeline?.steps.first?.id == stepID ? document : nil)
        let insideLoop = pipeline?.entry(for: stepID)?.parentID != nil
        let usesSchema = input != nil && input == document && schemaDocument != nil && !insideLoop
        return PipelineRunner.declarations(input: input, schema: usesSchema ? schemaDocument : nil)
    }

    var isTypeScriptAvailable: Bool { TypeScriptService.shared.isAvailable }

    /// Type-checks the selected TypeScript step against its input type (debounced).
    func scheduleTypeCheck() {
        typeCheckTask?.cancel()
        guard let step = selectedStep, case .script(.typescript, let code) = step.kind, isTypeScriptAvailable else {
            isTypeCheckPending = false
            return
        }
        let declarations = typeDeclarations(for: step.id)
        let stepID = step.id
        isTypeCheckPending = true
        typeCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let service = TypeScriptService.shared
            let diagnostics: [TypeScriptDiagnostic]
            do {
                let asExpression = try await service.isExpression(code)
                diagnostics = try await service.check(code, declarations: declarations, asExpression: asExpression)
            } catch TypeScriptError.syntax(let syntaxErrors) {
                diagnostics = syntaxErrors
            } catch {
                diagnostics = []
            }
            guard !Task.isCancelled, let self else { return }
            self.stepDiagnostics[stepID] = diagnostics.filter { $0.category == .error || $0.category == .warning }
            self.isTypeCheckPending = false
        }
    }

    /// Selects `line` (1-based) of the selected script step in its editor.
    func highlightScriptLine(_ line: Int) {
        guard let step = selectedStep, case .script(_, let code) = step.kind else { return }
        let lines = code.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return }
        let location = lines.prefix(line - 1).reduce(0) { $0 + ($1 as NSString).length + 1 }
        scriptEditorHighlight = NSRange(location: location, length: max((lines[line - 1] as NSString).length, 1))
        scriptEditorHighlightTick += 1
    }
}

// MARK: - Presentation helpers

extension PipelineStepKind {
    var systemImage: String {
        switch self {
        case .script(let language, _): return language == .typescript ? "t.square" : "curlybraces"
        case .jsonPath: return "chevron.left.forwardslash.chevron.right"
        case .flatten: return "arrow.down.right.and.arrow.up.left"
        case .pipeline: return "arrow.triangle.branch"
        case .httpRequest: return "globe"
        case .forEach: return "repeat"
        case .setVariable: return "tag"
        }
    }

    /// One-line description shown under the step name.
    func summary(library: [Pipeline]) -> String {
        switch self {
        case .script(_, let code):
            let lines = code.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            return lines.first { !$0.isEmpty && !$0.hasPrefix("//") } ?? "Empty script"
        case .jsonPath(let expression, let firstMatchOnly):
            return firstMatchOnly ? "\(expression) · first match" : expression
        case .flatten(let depth):
            return depth.map { "Depth \($0)" } ?? "All levels"
        case .pipeline(let id):
            return library.first { $0.id == id }?.name ?? "Missing pipeline"
        case .httpRequest(let request):
            return request.url.isEmpty ? "\(request.method.rawValue) · no URL yet" : "\(request.method.rawValue) \(request.url)"
        case .forEach(let loop):
            let count = loop.steps.count
            var text = count == 0 ? "Empty body" : "\(count) step\(count == 1 ? "" : "s") per item"
            if loop.outputMode == .merged { text += " · merged" }
            return text
        case .setVariable(let variable):
            let name = variable.name.isEmpty ? "?" : variable.name
            let source = variable.source.text.isEmpty ? (variable.source.isTemplate ? "\"\"" : "input") : variable.source.text
            return "\(name) = \(source)\(variable.saveToLibrary ? " · saved" : "")"
        }
    }
}

extension JSONValue {
    /// "object · 3 keys", "array · 12 items", "string", …
    var shapeDescription: String {
        switch self {
        case .object(let o): return "object · \(o.count) key\(o.count == 1 ? "" : "s")"
        case .array(let a): return "array · \(a.count) item\(a.count == 1 ? "" : "s")"
        default: return typeName
        }
    }
}

extension TimeInterval {
    var briefDuration: String {
        if self < 0.001 { return "<1 ms" }
        if self < 1 { return "\(Int((self * 1000).rounded())) ms" }
        return String(format: "%.2f s", self)
    }
}

extension DocumentModel {
    /// The result shown on a step row. For a step inside a For Each, the first iteration
    /// that failed at it wins over the first iteration, so the row's dot reflects any failure.
    func aggregateResult(for stepID: UUID) -> PipelineStepResult? {
        guard let pipelineRun else { return nil }
        guard let loop = pipelineRun.loopResult(containing: stepID) else { return pipelineRun.result(for: stepID) }
        var first: PipelineStepResult?
        for iteration in loop.iterations {
            guard let result = iteration.result(for: stepID) else { continue }
            if result.error != nil { return result }
            if first == nil { first = result }
        }
        return first
    }
}
