import SwiftUI
import JaysonCore

/// Right-hand panel: the pipeline attached to the document as a chain of steps, the
/// selected step's editor, and that step's output. Runs live as the document or steps change.
struct PipelinePanel: View {
    @Bindable var doc: DocumentModel
    @Environment(Workspace.self) private var workspace
    @State private var renaming = false
    @State private var renameText = ""
    @State private var scriptTab: ScriptTab = .code

    enum ScriptTab: Hashable { case code, types }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if let pipeline = doc.pipeline {
                VSplitView {
                    VStack(spacing: 0) {
                        stepsList(pipeline)
                        Hairline()
                        stepEditor(pipeline)
                    }
                    .frame(minHeight: 260)
                    outputPane
                        .frame(minHeight: 160)
                }
                Hairline()
                footer
            } else {
                emptyState
            }
        }
        .frame(width: Chrome.pipelinePanelWidth)
        .frame(maxHeight: .infinity)
        .background(Chrome.contentBackground)
        .overlay(alignment: .leading) { Hairline(vertical: true) }
        .sheet(isPresented: $renaming) { renameSheet }
        .onAppear { doc.scheduleTypeCheck() }
        .onChange(of: doc.selectedStepID) { _, _ in
            scriptTab = .code
            doc.scheduleTypeCheck()
        }
        .onChange(of: doc.pipeline) { _, _ in doc.scheduleTypeCheck() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(doc.pipeline?.name ?? "Pipeline").font(Chrome.titleFont).lineLimit(1).truncationMode(.middle)
                Text(headerSubtitle).font(Chrome.captionFont).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if doc.pipeline != nil {
                IconButton(systemImage: "play.fill", help: "Run now (⌥⌘R)") { doc.runPipelineNow() }
                    .disabled(doc.document == nil)
            }
            Menu {
                Button("New Pipeline") { workspace.newPipeline(for: doc) }
                if !workspace.pipelines.isEmpty {
                    Menu("Use from Library") {
                        ForEach(workspace.pipelines) { item in
                            Button(item.name) { workspace.attach(item, to: doc) }
                        }
                    }
                }
                Button("Import Pipeline…") { workspace.importPipeline() }
                if let pipeline = doc.pipeline {
                    Divider()
                    Button("Rename…") {
                        renameText = pipeline.name
                        renaming = true
                    }
                    Button("Duplicate") { workspace.duplicate(pipeline) }
                    Button("Export…") { workspace.exportPipeline(pipeline) }
                    Divider()
                    Button("Output as New Document") { openOutputAsDocument() }.disabled(doc.pipelineRun?.output == nil)
                    Button("Replace Document with Output") { doc.replaceDocumentWithPipelineOutput() }.disabled(doc.pipelineRun?.output == nil)
                    Button("Save Output As…") { doc.savePipelineOutput() }.disabled(doc.pipelineRun?.output == nil)
                    Divider()
                    Button("Detach from Document") { workspace.detachPipeline(from: doc) }
                    Button("Remove from Library", role: .destructive) { workspace.remove(pipeline) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            IconButton(systemImage: "xmark", help: "Close panel (⌥⌘P)") { workspace.togglePipelinePanel() }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: Chrome.headerHeight)
    }

    private var headerSubtitle: String {
        guard let pipeline = doc.pipeline else { return "Transform the document step by step" }
        let count = pipeline.steps.count
        var text = "\(count) step\(count == 1 ? "" : "s") · in library"
        if let run = doc.pipelineRun, run.pipelineID == pipeline.id, doc.document != nil {
            text += " · runs on \(doc.title)"
        }
        return text
    }

    // MARK: Steps

    private func stepsList(_ pipeline: Pipeline) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                inputRow
                ForEach(Array(pipeline.steps.enumerated()), id: \.element.id) { index, step in
                    connector
                    StepRow(
                        step: step,
                        index: index + 1,
                        result: doc.pipelineRun?.result(for: step.id),
                        isSelected: doc.selectedStepID == step.id,
                        isRunning: doc.isPipelineRunning,
                        library: workspace.pipelines,
                        select: { doc.selectedStepID = step.id },
                        toggle: { doc.updateStep(step.id) { $0.isEnabled.toggle() } }
                    )
                    .contextMenu {
                        Button("Rename…") { beginRenameStep(step) }
                        Button(step.isEnabled ? "Disable" : "Enable") { doc.updateStep(step.id) { $0.isEnabled.toggle() } }
                        Divider()
                        Button("Move Up") { doc.moveStep(step.id, by: -1) }.disabled(index == 0)
                        Button("Move Down") { doc.moveStep(step.id, by: 1) }.disabled(index == pipeline.steps.count - 1)
                        Button("Duplicate") { doc.duplicateStep(step.id) }
                        addStepMenu(title: "Insert Step After", after: step.id)
                        Divider()
                        Button("Delete", role: .destructive) { doc.removeStep(step.id) }
                    }
                }
                connector
                addStepMenu(title: pipeline.steps.isEmpty ? "Add First Step" : "Add Step", after: nil)
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .frame(maxHeight: 250)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var inputRow: some View {
        let selected = doc.selectedStepID == nil
        return Button {
            doc.selectedStepID = nil
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Chrome.fill))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Input · \(doc.title)").font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text(doc.document?.shapeDescription ?? (doc.parseError == nil ? "Empty document" : "Waiting for valid JSON"))
                        .font(Chrome.captionFont).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                StatusDot(color: doc.document == nil ? .secondary.opacity(0.4) : .green)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Chrome.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var connector: some View {
        Rectangle().fill(Chrome.hairline).frame(width: 1, height: 10).padding(.leading, 19).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addStepMenu(title: String, after id: UUID?) -> some View {
        Menu {
            Button("JavaScript") { doc.addStep(.script(language: .javascript, code: Pipeline.starterCode(for: .javascript)), after: id) }
            Button("TypeScript") { doc.addStep(.script(language: .typescript, code: Pipeline.starterCode(for: .typescript)), after: id) }
            Divider()
            Button("HTTP Request") { doc.addStep(.httpRequest(HTTPRequestStep()), after: id) }
            Divider()
            Button("JSONPath") { doc.addStep(.jsonPath(expression: "$..*", firstMatchOnly: false), after: id) }
            Button("Flatten") { doc.addStep(.flatten(depth: nil), after: id) }
            let others = workspace.pipelines.filter { $0.id != doc.pipeline?.id }
            if !others.isEmpty {
                Menu("Run Pipeline") {
                    ForEach(others) { other in
                        Button(other.name) { doc.addStep(.pipeline(id: other.id), after: id) }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Chrome.fill))
            .contentShape(Rectangle())
        }
    }

    // MARK: Step editor

    @ViewBuilder
    private func stepEditor(_ pipeline: Pipeline) -> some View {
        if let step = doc.selectedStep {
            VStack(spacing: 0) {
                switch step.kind {
                case .script(let language, let code):
                    scriptEditor(step: step, language: language, code: code)
                case .jsonPath(let expression, let firstMatchOnly):
                    jsonPathEditor(step: step, expression: expression, firstMatchOnly: firstMatchOnly)
                case .flatten(let depth):
                    flattenEditor(step: step, depth: depth)
                case .pipeline(let id):
                    pipelineEditor(step: step, referenced: id)
                case .httpRequest(let request):
                    HTTPRequestEditor(request: request) { updated in
                        doc.updateStep(step.id) { $0.kind = .httpRequest(updated) }
                    } send: {
                        doc.runPipelineNow()
                    }
                    .id(step.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if pipeline.steps.isEmpty {
            EmptyState(systemImage: "plus.square.dashed", title: "Add the first step", message: "Pick a block: a JavaScript or TypeScript script, an HTTP request, a JSONPath selection, Flatten, or another pipeline. The document is the input of the first step.") {
                addStepMenu(title: "Add Step", after: nil)
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
            }
        } else {
            EmptyState(systemImage: "doc.text", title: "Pipeline input", message: "The document is the input of the first step. Select a step to edit it; its output appears below.")
        }
    }

    private func scriptEditor(step: PipelineStep, language: ScriptLanguage, code: String) -> some View {
        let diagnostics = doc.stepDiagnostics[step.id] ?? []
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                PillSegmented(
                    segments: ScriptLanguage.allCases.map { .init(value: $0, title: $0.shortTitle) },
                    selection: Binding(get: { language }, set: { doc.setScriptLanguage($0, for: step.id) })
                )
                .fixedSize()
                if language == .typescript {
                    PillSegmented(
                        segments: [
                            .init(value: ScriptTab.code, title: "Code", systemImage: "chevron.left.forwardslash.chevron.right"),
                            .init(value: ScriptTab.types, title: "Types", systemImage: "t.square", badge: diagnostics.count),
                        ],
                        selection: $scriptTab
                    )
                    .fixedSize()
                }
                Spacer()
                Text(scriptHint(language: language))
                    .font(Chrome.captionFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Hairline()
            if language == .typescript, scriptTab == .types {
                SourceEditor(text: .constant(doc.typeDeclarations(for: step.id)), isEditable: false, syntax: .javaScript)
                    .overlay(alignment: .bottomLeading) {
                        Text(doc.schemaDocument != nil && doc.selectedStepResult?.input == doc.document ? "Input type from the loaded schema" : "Input type inferred from the step's input")
                            .font(Chrome.captionFont)
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Chrome.panelBackground).shadow(color: .black.opacity(0.08), radius: 2))
                            .padding(8)
                    }
            } else {
                SourceEditor(
                    text: Binding(get: { code }, set: { doc.setScriptCode($0, for: step.id) }),
                    highlight: doc.scriptEditorHighlight,
                    highlightTick: doc.scriptEditorHighlightTick,
                    syntax: .javaScript
                )
                .id(step.id)
            }
            if language == .typescript, !doc.isTypeScriptAvailable {
                Hairline()
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("TypeScript compiler not installed. Run `make typescript` and relaunch, or switch to JavaScript.")
                        .font(Chrome.captionFont)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.10))
            } else if language == .typescript, !diagnostics.isEmpty {
                Hairline()
                diagnosticsList(diagnostics)
            }
        }
    }

    private func scriptHint(language: ScriptLanguage) -> String {
        if language == .typescript {
            if doc.isTypeCheckPending { return "Checking types…" }
            let errors = doc.stepDiagnostics[doc.selectedStepID ?? UUID()]?.count ?? 0
            if errors > 0 { return "\(errors) type error\(errors == 1 ? "" : "s")" }
            return doc.isTypeScriptAvailable ? "Types OK" : ""
        }
        return "input, $ helpers, console"
    }

    private func diagnosticsList(_ diagnostics: [TypeScriptDiagnostic]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(diagnostics) { diagnostic in
                    Button {
                        doc.highlightScriptLine(diagnostic.line)
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: diagnostic.category == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(diagnostic.category == .error ? .red : .orange)
                                .font(.system(size: 11))
                                .padding(.top, 2)
                            Text("\(diagnostic.line):\(diagnostic.column)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.top, 1)
                            Text(diagnostic.message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 110)
        .background(Color.red.opacity(0.05))
    }

    private func jsonPathEditor(step: PipelineStep, expression: String, firstMatchOnly: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("JSONPath expression").font(Chrome.sectionFont).foregroundStyle(.secondary)
                TextField("$.store.book[*].title", text: Binding(get: { expression }, set: { value in
                    doc.updateStep(step.id) { $0.kind = .jsonPath(expression: value, firstMatchOnly: firstMatchOnly) }
                }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
            }
            Toggle("Return only the first match (instead of an array of all matches)", isOn: Binding(get: { firstMatchOnly }, set: { value in
                doc.updateStep(step.id) { $0.kind = .jsonPath(expression: expression, firstMatchOnly: value) }
            }))
            .font(.system(size: 12.5))
            Text("Supports recursive descent (`$..price`), slices, filters with `&& || !` and regex. Matches are collected into the output array in document order.")
                .font(Chrome.captionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(14)
    }

    private func flattenEditor(step: PipelineStep, depth: Int?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Flatten", selection: Binding(get: { depth ?? 0 }, set: { value in
                doc.updateStep(step.id) { $0.kind = .flatten(depth: value == 0 ? nil : value) }
            })) {
                Text("All nested levels").tag(0)
                Text("One level").tag(1)
                Text("Two levels").tag(2)
                Text("Three levels").tag(3)
            }
            .pickerStyle(.radioGroup)
            .font(.system(size: 12.5))
            Text("Turns `[[1, 2], [3, [4]]]` into `[1, 2, 3, 4]` (all levels) or `[1, 2, 3, [4]]` (one level). The input must be an array.")
                .font(Chrome.captionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(14)
    }

    private func pipelineEditor(step: PipelineStep, referenced: UUID) -> some View {
        let others = workspace.pipelines.filter { $0.id != doc.pipeline?.id }
        return VStack(alignment: .leading, spacing: 12) {
            Picker("Pipeline", selection: Binding(get: { referenced }, set: { value in
                doc.updateStep(step.id) { $0.kind = .pipeline(id: value) }
            })) {
                ForEach(others) { other in
                    Text(other.name).tag(other.id)
                }
                if !others.contains(where: { $0.id == referenced }) {
                    Text("Missing pipeline").tag(referenced)
                }
            }
            .font(.system(size: 12.5))
            Text("Runs the chosen library pipeline on this step's input and passes its final output on. Edit the referenced pipeline from the sidebar; changes apply here immediately.")
                .font(Chrome.captionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(14)
    }

    // MARK: Output

    private var outputPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(outputTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let result = doc.selectedStepResult, !result.wasSkipped {
                    Text(result.duration.briefDuration).font(Chrome.captionFont.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let shape = doc.selectedStepValue?.shapeDescription {
                    Text(shape).font(Chrome.captionFont).foregroundStyle(.secondary)
                }
                Spacer()
                IconButton(systemImage: "doc.on.doc", help: "Copy this output", size: 24) { doc.copySelectedStepOutput() }
                    .disabled(doc.selectedStepValue == nil)
                IconButton(systemImage: "plus.rectangle.on.rectangle", help: "Open final output as a new document", size: 24) { openOutputAsDocument() }
                    .disabled(doc.pipelineRun?.output == nil)
                IconButton(systemImage: "arrow.uturn.backward.square", help: "Replace this document with the final output", size: 24) { doc.replaceDocumentWithPipelineOutput() }
                    .disabled(doc.pipelineRun?.output == nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Hairline()
            outputContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var outputTitle: String {
        guard let step = doc.selectedStep, let pipeline = doc.pipeline, let index = pipeline.index(of: step.id) else { return "Input" }
        return "Output of step \(index + 1)"
    }

    @ViewBuilder
    private var outputContent: some View {
        if doc.selectedStepID == nil {
            if doc.document != nil {
                previewEditor
            } else {
                EmptyState(systemImage: "clock", title: doc.parseError == nil ? "Waiting for JSON" : "Waiting for valid JSON", message: "The pipeline runs as soon as the document parses.")
            }
        } else if doc.document == nil {
            EmptyState(systemImage: "clock", title: "Waiting for valid JSON", message: "Fix the document to run the pipeline.")
        } else if let result = doc.selectedStepResult {
            if result.wasDeferred {
                EmptyState(systemImage: "paperplane", title: "Request not sent yet", message: "Requests are not sent while you edit. Run the pipeline to send this request; the response is then reused until the request changes or you run again.", tint: .orange) {
                    ChromeButton(title: "Run and Send", systemImage: "play.fill") { doc.runPipelineNow() }
                }
            } else if let error = result.error {
                VStack(spacing: 0) {
                    EmptyState(systemImage: "xmark.octagon", title: result.errorLine.map { "Error on line \($0)" } ?? "Step failed", message: error, tint: .red) {
                        if let line = result.errorLine {
                            ChromeButton(title: "Go to Line", systemImage: "arrow.right.circle") { doc.highlightScriptLine(line) }
                        }
                    }
                    if !result.logs.isEmpty { Hairline(); logsView(result.logs) }
                }
            } else if result.wasSkipped, result.output == nil {
                EmptyState(systemImage: "forward.end", title: "Skipped", message: doc.pipelineRun?.isDeferred == true ? "An earlier HTTP request has not been sent yet. Run the pipeline to continue." : "An earlier step failed, so this step did not run.")
            } else {
                VStack(spacing: 0) {
                    if result.wasSkipped {
                        HStack(spacing: 6) {
                            Image(systemName: "pause.circle").foregroundStyle(.secondary)
                            Text("Disabled: the input passes through unchanged.").font(Chrome.captionFont).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 5).background(Chrome.fill)
                        Hairline()
                    }
                    previewEditor
                    if !result.logs.isEmpty { Hairline(); logsView(result.logs) }
                }
            }
        } else if doc.isPipelineRunning {
            EmptyState(systemImage: "hourglass", title: "Running…")
        } else {
            EmptyState(systemImage: "play.circle", title: "Not run yet", message: "The pipeline runs automatically when the document or its steps change.") {
                ChromeButton(title: "Run", systemImage: "play.fill") { doc.runPipelineNow() }
            }
        }
    }

    private var previewEditor: some View {
        SourceEditor(text: .constant(doc.stepPreview), isEditable: false)
            .overlay(alignment: .bottom) {
                if doc.stepPreviewTruncated {
                    Text("Preview truncated · open as a document to see everything")
                        .font(Chrome.captionFont)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Chrome.panelBackground).shadow(color: .black.opacity(0.1), radius: 2))
                        .padding(8)
                }
            }
    }

    private func logsView(_ logs: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("Console · \(logs.count)").font(Chrome.sectionFont).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 6)
            }
            .frame(maxHeight: 120)
        }
        .background(Chrome.fill.opacity(0.5))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            footerIcon
            Text(footerText).font(Chrome.captionFont).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if let run = doc.pipelineRun, run.failedStepID != nil, doc.selectedStepID != run.failedStepID {
                Button("Show") { doc.selectedStepID = run.failedStepID }.buttonStyle(.link).font(Chrome.captionFont)
            }
            IconButton(systemImage: "arrow.clockwise", help: "Run again (⌥⌘R)", size: 22) { doc.runPipelineNow() }
                .disabled(doc.document == nil)
        }
        .padding(.horizontal, 12)
        .frame(height: Chrome.statusBarHeight + 4)
    }

    @ViewBuilder
    private var footerIcon: some View {
        if doc.isPipelineRunning {
            ProgressView().controlSize(.mini).frame(width: 7, height: 7)
        } else if let run = doc.pipelineRun {
            StatusDot(color: run.isSuccess ? .green : (run.isDeferred ? .orange : .red))
        } else {
            StatusDot(color: .secondary.opacity(0.4))
        }
    }

    private var footerText: String {
        if doc.isPipelineRunning { return "Running…" }
        guard let run = doc.pipelineRun else { return doc.document == nil ? "Waiting for valid JSON" : "Not run yet" }
        if let failure = run.failure, let pipeline = doc.pipeline {
            let index = pipeline.index(of: failure.id).map { $0 + 1 } ?? 0
            if failure.wasDeferred { return "Step \(index) is an HTTP request · press Run to send it" }
            return "Failed at step \(index) · \(failure.error ?? "")"
        }
        let ran = run.steps.filter { !$0.wasSkipped }.count
        return "Ran \(ran) step\(ran == 1 ? "" : "s") in \(run.duration.briefDuration) · output is \(run.output?.shapeDescription ?? "empty")"
    }

    // MARK: Empty state

    private var emptyState: some View {
        EmptyState(systemImage: "arrow.triangle.branch", title: "No pipeline on this document", message: "A pipeline is a chain of steps that transforms the JSON: scripts in JavaScript or TypeScript, JSONPath selections, flattening, or other pipelines. Pipelines are saved in the sidebar and can be reused on any document.") {
            ChromeButton(title: "New Pipeline", systemImage: "plus") { workspace.newPipeline(for: doc) }
            if !workspace.pipelines.isEmpty {
                Menu {
                    ForEach(workspace.pipelines) { item in
                        Button(item.name) { workspace.attach(item, to: doc) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "books.vertical").font(.system(size: 12, weight: .medium))
                        Text("From Library").font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Chrome.fill))
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    // MARK: Actions

    private func openOutputAsDocument() {
        guard let output = doc.pipelineRun?.output else { return }
        let text = doc.formatted(output)
        let newDoc = workspace.newDocument(text: text, select: true)
        newDoc.customTitle = "\(doc.pipeline?.name ?? "Pipeline") → \(doc.title)"
    }

    private func beginRenameStep(_ step: PipelineStep) {
        renameText = step.name
        renamingStep = step.id
        renaming = true
    }

    @State private var renamingStep: UUID?

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(renamingStep == nil ? "Rename Pipeline" : "Rename Step").font(.headline)
            TextField(renamingStep == nil ? "Name" : "Leave empty to use the step type", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commitRename)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { renaming = false; renamingStep = nil }.keyboardShortcut(.cancelAction)
                Button("Rename", action: commitRename).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func commitRename() {
        if let stepID = renamingStep {
            let name = renameText.trimmingCharacters(in: .whitespaces)
            doc.updateStep(stepID) { $0.name = name }
        } else if let pipeline = doc.pipeline {
            workspace.rename(pipeline, to: renameText)
        }
        renaming = false
        renamingStep = nil
    }
}

// MARK: - Step row

private struct StepRow: View {
    let step: PipelineStep
    let index: Int
    let result: PipelineStepResult?
    let isSelected: Bool
    let isRunning: Bool
    let library: [Pipeline]
    let select: () -> Void
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Chrome.fill)
                    Image(systemName: step.kind.systemImage)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(step.isEnabled ? Color.primary : Color.secondary)
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("\(index)").font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
                        Text(step.displayName)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(step.isEnabled ? .primary : .secondary)
                            .lineLimit(1)
                        if !step.name.isEmpty {
                            Text(step.kind.title).font(Chrome.captionFont).foregroundStyle(.tertiary)
                        }
                    }
                    Text(step.kind.summary(library: library))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                if let result, !result.wasSkipped, result.error == nil {
                    Text(result.duration.briefDuration).font(Chrome.captionFont.monospacedDigit()).foregroundStyle(.tertiary)
                }
                statusDot
                Toggle("", isOn: Binding(get: { step.isEnabled }, set: { _ in toggle() }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help(step.isEnabled ? "Disable step" : "Enable step")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isSelected ? Chrome.selection : (hovering ? Chrome.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .opacity(step.isEnabled ? 1 : 0.75)
    }

    @ViewBuilder
    private var statusDot: some View {
        if !step.isEnabled {
            StatusDot(color: .secondary.opacity(0.3))
        } else if let result {
            if result.wasDeferred { StatusDot(color: .orange) }
            else if result.error != nil { StatusDot(color: .red) }
            else if result.wasSkipped { StatusDot(color: .secondary.opacity(0.3)) }
            else { StatusDot(color: .green) }
        } else {
            StatusDot(color: .secondary.opacity(isRunning ? 0.6 : 0.3))
        }
    }
}

// MARK: - HTTP request editor

private struct HTTPRequestEditor: View {
    let request: HTTPRequestStep
    let update: (HTTPRequestStep) -> Void
    let send: () -> Void

    private func binding<T>(_ keyPath: WritableKeyPath<HTTPRequestStep, T>) -> Binding<T> {
        Binding(get: { request[keyPath: keyPath] }, set: { value in
            var copy = request
            copy[keyPath: keyPath] = value
            update(copy)
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Picker("", selection: binding(\.method)) {
                        ForEach(HTTPRequestStep.Method.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    TextField("https://api.example.com/items/{{ id }}", text: binding(\.url))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5, design: .monospaced))
                        .onSubmit(send)
                    ChromeButton(title: "Send", systemImage: "paperplane.fill", help: "Run the pipeline and send this request (⌥⌘R)", action: send)
                        .fixedSize()
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Headers").font(Chrome.sectionFont).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            var copy = request
                            copy.headers.append(.init(name: "", value: ""))
                            update(copy)
                        } label: {
                            Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Add header")
                    }
                    if request.headers.isEmpty {
                        Text("No headers. Accept and Content-Type default to JSON.").font(Chrome.captionFont).foregroundStyle(.tertiary)
                    }
                    ForEach(request.headers) { header in
                        HStack(spacing: 6) {
                            TextField("Name", text: Binding(get: { header.name }, set: { value in
                                var copy = request
                                if let i = copy.headers.firstIndex(where: { $0.id == header.id }) { copy.headers[i].name = value }
                                update(copy)
                            }))
                            .frame(width: 150)
                            TextField("Value ({{ token }} works here too)", text: Binding(get: { header.value }, set: { value in
                                var copy = request
                                if let i = copy.headers.firstIndex(where: { $0.id == header.id }) { copy.headers[i].value = value }
                                update(copy)
                            }))
                            Button {
                                var copy = request
                                copy.headers.removeAll { $0.id == header.id }
                                update(copy)
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    }
                }

                if request.method.allowsBody {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Body").font(Chrome.sectionFont).foregroundStyle(.secondary)
                        Picker("", selection: binding(\.bodyMode)) {
                            Text("None").tag(HTTPRequestStep.BodyMode.none)
                            Text("Step input as JSON").tag(HTTPRequestStep.BodyMode.input)
                            Text("Custom").tag(HTTPRequestStep.BodyMode.custom)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        if request.bodyMode == .custom {
                            SourceEditor(text: binding(\.customBody))
                                .frame(height: 110)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Response").font(Chrome.sectionFont).foregroundStyle(.secondary)
                    Picker("", selection: binding(\.outputMode)) {
                        Text("Body only").tag(HTTPRequestStep.OutputMode.body)
                        Text("Status, headers and body").tag(HTTPRequestStep.OutputMode.full)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Toggle("Fail the step on non-2xx status codes", isOn: binding(\.failOnErrorStatus))
                        .font(.system(size: 12.5))
                }

                Text("Placeholders like `{{ user.id }}` in the URL, header values and custom body are filled from the step input. Requests are only sent when you press Run or Send; live edits reuse the last response.")
                    .font(Chrome.captionFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }
}
