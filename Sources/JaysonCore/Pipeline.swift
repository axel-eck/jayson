import Foundation

// MARK: - Model

/// Language of a script step. TypeScript is transpiled (and type-checked against the
/// step's input type) by the bundled TypeScript compiler; see `TypeScriptService`.
public enum ScriptLanguage: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case javascript
    case typescript

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        }
    }

    public var shortTitle: String {
        switch self {
        case .javascript: return "JS"
        case .typescript: return "TS"
        }
    }
}

/// What a step does with its input. Every step receives one JSON value and produces one.
public indirect enum PipelineStepKind: Hashable, Sendable {
    /// Runs user code. `input` is bound to the step input; the value returned (or the value
    /// of a bare expression) becomes the output.
    case script(language: ScriptLanguage, code: String)
    /// Selects values with a JSONPath expression. The output is the array of matches, or the
    /// first match (null when nothing matched) when `firstMatchOnly` is set.
    case jsonPath(expression: String, firstMatchOnly: Bool)
    /// Flattens nested arrays. `depth == nil` flattens completely.
    case flatten(depth: Int?)
    /// Runs another pipeline from the library, so pipelines can be composed and reused.
    case pipeline(id: UUID)
    /// Sends an HTTP request; the response (parsed as JSON when possible) becomes the output.
    case httpRequest(HTTPRequestStep)
    /// Runs a body of steps once per element of the (array) input.
    case forEach(ForEachStep)
    /// Stores a value under a name for the rest of the run (`{{ vars.name }}`, `$.vars.name`),
    /// optionally saving it to the variable library. The input passes through unchanged.
    case setVariable(SetVariableStep)

    public var typeIdentifier: String {
        switch self {
        case .script: return "script"
        case .jsonPath: return "jsonPath"
        case .flatten: return "flatten"
        case .pipeline: return "pipeline"
        case .httpRequest: return "httpRequest"
        case .forEach: return "forEach"
        case .setVariable: return "setVariable"
        }
    }

    /// Default label shown for a step without a custom name.
    public var title: String {
        switch self {
        case .script(let language, _): return language.title
        case .jsonPath: return "JSONPath"
        case .flatten: return "Flatten"
        case .pipeline: return "Pipeline"
        case .httpRequest: return "HTTP Request"
        case .forEach: return "For Each"
        case .setVariable: return "Set Variable"
        }
    }

    /// The steps nested inside this step (the body of a For Each), if any.
    public var childSteps: [PipelineStep]? {
        get {
            if case .forEach(let loop) = self { return loop.steps }
            return nil
        }
        set {
            guard case .forEach(var loop) = self, let newValue else { return }
            loop.steps = newValue
            self = .forEach(loop)
        }
    }
}

// MARK: - Templates

/// Everything a `{{ … }}` placeholder can refer to. Paths are resolved against the step
/// input by default; the first component selects another root:
/// `vars.token`, `steps.Login.token`, `document.id`, `loop.index`, `loop.item.id`.
public struct TemplateContext: Sendable {
    public var input: JSONValue
    public var variables: [String: JSONValue]
    public var document: JSONValue?
    /// Outputs of the previous steps of the same pipeline, keyed by display name and by
    /// 1-based position.
    public var steps: [String: JSONValue]
    public var loop: LoopInfo?

    public struct LoopInfo: Hashable, Sendable {
        public var index: Int
        public var count: Int
        public var item: JSONValue
        public init(index: Int, count: Int, item: JSONValue) {
            self.index = index
            self.count = count
            self.item = item
        }

        public var jsonValue: JSONValue {
            .object(JSONObject([("index", .number(index)), ("count", .number(count)), ("item", item)]))
        }
    }

    public init(input: JSONValue, variables: [String: JSONValue] = [:], document: JSONValue? = nil, steps: [String: JSONValue] = [:], loop: LoopInfo? = nil) {
        self.input = input
        self.variables = variables
        self.document = document
        self.steps = steps
        self.loop = loop
    }

    /// Replaces `{{ path }}` placeholders. Strings are inserted raw, other values as minified
    /// JSON, unknown paths as "".
    public func expand(_ template: String) -> String {
        guard template.contains("{{") else { return template }
        var result = ""
        var rest = template[...]
        while let open = rest.range(of: "{{") {
            result += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                result += rest[open.lowerBound...]
                return result
            }
            let path = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            result += Self.render(value(at: path))
            rest = rest[close.upperBound...]
        }
        result += rest
        return result
    }

    /// Resolves a dotted path (`user.id`, `vars.token`, `steps.Login.body[0]`). An empty path
    /// is the input itself.
    public func value(at path: String) -> JSONValue? {
        var components = path.replacingOccurrences(of: "]", with: "").split(whereSeparator: { $0 == "." || $0 == "[" }).map(String.init)
        var current: JSONValue
        switch components.first {
        case "input"?, "$"?:
            components.removeFirst()
            current = input
        case "vars"?, "env"?:
            components.removeFirst()
            current = .object(JSONObject(variables.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
        case "steps"?:
            components.removeFirst()
            current = .object(JSONObject(steps.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
        case "document"?:
            components.removeFirst()
            current = document ?? .null
        case "loop"?:
            components.removeFirst()
            current = loop?.jsonValue ?? .null
        default:
            current = input
        }
        for component in components {
            if let index = Int(component), let element = current[index] {
                current = element
            } else if let member = current[component] {
                current = member
            } else {
                return nil
            }
        }
        return current
    }

    static func render(_ value: JSONValue?) -> String {
        switch value {
        case nil, .null?: return ""
        case .string(let s)?: return s
        case let other?: return JSONFormatter.minify(other)
        }
    }
}

/// Configuration of an `.httpRequest` step. The URL, header values and custom body accept
/// `{{ path }}` placeholders resolved against the step input (`{{ input.user.id }}` or
/// `{{ user.id }}`), the variables (`{{ vars.token }}`), previous steps
/// (`{{ steps.Login.token }}`) and the loop (`{{ loop.index }}`); see `TemplateContext`.
public struct HTTPRequestStep: Hashable, Codable, Sendable {
    public enum Method: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
        case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE", head = "HEAD"
        public var id: String { rawValue }
        public var allowsBody: Bool { self != .get && self != .head }
    }

    public enum BodyMode: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
        /// No request body.
        case none
        /// The step input, serialised as JSON.
        case input
        /// `customBody`, after placeholder expansion.
        case custom
        public var id: String { rawValue }
    }

    public enum OutputMode: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
        /// Only the response body (parsed as JSON when possible, otherwise a string).
        case body
        /// `{ "status": 200, "headers": {…}, "body": … }`.
        case full
        public var id: String { rawValue }
    }

    public struct Header: Hashable, Codable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var value: String
        public init(id: UUID = UUID(), name: String, value: String) {
            self.id = id
            self.name = name
            self.value = value
        }
    }

    public var method: Method = .get
    public var url: String = ""
    public var headers: [Header] = []
    public var bodyMode: BodyMode = .none
    public var customBody: String = ""
    public var outputMode: OutputMode = .body
    /// When set (the default), non-2xx responses fail the step instead of becoming its output.
    public var failOnErrorStatus = true
    public var timeout: TimeInterval = 30

    public init() {}

    private enum CodingKeys: String, CodingKey { case method, url, headers, bodyMode, customBody, outputMode, failOnErrorStatus, timeout }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        method = try c.decodeIfPresent(Method.self, forKey: .method) ?? .get
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        headers = try c.decodeIfPresent([Header].self, forKey: .headers) ?? []
        bodyMode = try c.decodeIfPresent(BodyMode.self, forKey: .bodyMode) ?? .none
        customBody = try c.decodeIfPresent(String.self, forKey: .customBody) ?? ""
        outputMode = try c.decodeIfPresent(OutputMode.self, forKey: .outputMode) ?? .body
        failOnErrorStatus = try c.decodeIfPresent(Bool.self, forKey: .failOnErrorStatus) ?? true
        timeout = try c.decodeIfPresent(TimeInterval.self, forKey: .timeout) ?? 30
    }

    /// Replaces `{{ path }}` placeholders with values from `input` only (no variables).
    public static func expand(_ template: String, input: JSONValue) -> String {
        TemplateContext(input: input).expand(template)
    }

    /// The cache key for a fully expanded request.
    public func cacheKey(context: TemplateContext) -> String {
        let headerText = headers.map { "\($0.name):\(context.expand($0.value))" }.joined(separator: "\n")
        let body: String
        switch bodyMode {
        case .none: body = ""
        case .input: body = method.allowsBody ? JSONFormatter.minify(context.input) : ""
        case .custom: body = method.allowsBody ? context.expand(customBody) : ""
        }
        return [method.rawValue, context.expand(url), headerText, body, outputMode.rawValue, failOnErrorStatus ? "fail" : "pass"].joined(separator: "\u{0}")
    }

    public func cacheKey(input: JSONValue) -> String {
        cacheKey(context: TemplateContext(input: input))
    }
}

/// Configuration of a `.forEach` step: the body runs once per element of the array input,
/// with that element as its input. Body steps see the loop as `{{ loop.index }}`,
/// `{{ loop.item }}` and `$.loop`.
public struct ForEachStep: Hashable, Codable, Sendable {
    public enum ErrorPolicy: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
        /// The first failing item fails the For Each step.
        case fail
        /// Failing items are left out of the output.
        case skip
        /// Failing items become `null` so positions line up with the input.
        case null
        public var id: String { rawValue }
    }

    public enum OutputMode: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
        /// The body outputs, in input order.
        case results
        /// Each item merged with its result: object keys of the result are added to the
        /// item; a non-object result is stored under `result`.
        case merged
        public var id: String { rawValue }
    }

    public static let maxConcurrency = 16

    public var steps: [PipelineStep] = []
    /// How many items run at the same time (1 keeps requests strictly sequential).
    public var concurrency: Int = 4
    public var errorPolicy: ErrorPolicy = .fail
    public var outputMode: OutputMode = .results

    public init(steps: [PipelineStep] = [], concurrency: Int = 4, errorPolicy: ErrorPolicy = .fail, outputMode: OutputMode = .results) {
        self.steps = steps
        self.concurrency = concurrency
        self.errorPolicy = errorPolicy
        self.outputMode = outputMode
    }

    private enum CodingKeys: String, CodingKey { case steps, concurrency, errorPolicy, outputMode }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        steps = try c.decodeIfPresent([PipelineStep].self, forKey: .steps) ?? []
        concurrency = try c.decodeIfPresent(Int.self, forKey: .concurrency) ?? 4
        errorPolicy = try c.decodeIfPresent(ErrorPolicy.self, forKey: .errorPolicy) ?? .fail
        outputMode = try c.decodeIfPresent(OutputMode.self, forKey: .outputMode) ?? .results
    }

    /// Combines an item with the output its body produced, for `.merged`.
    public static func merge(item: JSONValue, result: JSONValue) -> JSONValue {
        guard var object = item.objectValue else {
            return .object(JSONObject([("item", item), ("result", result)]))
        }
        if let fields = result.objectValue {
            for (key, value) in fields.members { object[key] = value }
        } else {
            object["result"] = result
        }
        return .object(object)
    }
}

/// Configuration of a `.setVariable` step.
public struct SetVariableStep: Hashable, Codable, Sendable {
    public enum Source: Hashable, Codable, Sendable {
        /// A path resolved like a placeholder (`access_token`, `input.data.token`,
        /// `steps.Login.token`). The JSON value is kept as is; an empty path means the input.
        case path(String)
        /// Text with `{{ … }}` placeholders; the result is a string.
        case template(String)

        public var text: String {
            switch self {
            case .path(let p), .template(let p): return p
            }
        }

        public var isTemplate: Bool {
            if case .template = self { return true }
            return false
        }
    }

    public var name: String = ""
    public var source: Source = .path("")
    /// Also store the value in the variable library so later runs (and other pipelines) can
    /// use it. The pipeline itself never contains the value.
    public var saveToLibrary = false

    public init(name: String = "", source: Source = .path(""), saveToLibrary: Bool = false) {
        self.name = name
        self.source = source
        self.saveToLibrary = saveToLibrary
    }

    private enum CodingKeys: String, CodingKey { case name, path, template, saveToLibrary }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        if let template = try c.decodeIfPresent(String.self, forKey: .template) {
            source = .template(template)
        } else {
            source = .path(try c.decodeIfPresent(String.self, forKey: .path) ?? "")
        }
        saveToLibrary = try c.decodeIfPresent(Bool.self, forKey: .saveToLibrary) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        switch source {
        case .path(let p): try c.encode(p, forKey: .path)
        case .template(let t): try c.encode(t, forKey: .template)
        }
        try c.encode(saveToLibrary, forKey: .saveToLibrary)
    }

    /// The value this step stores, given the step's context.
    public func resolve(in context: TemplateContext) -> JSONValue {
        switch source {
        case .path(let path):
            return context.value(at: path.trimmingCharacters(in: .whitespaces)) ?? .null
        case .template(let template):
            return .string(context.expand(template))
        }
    }

    /// Variable names are identifiers so `{{ vars.name }}` and `$.vars.name` stay simple.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || CharacterSet.alphanumerics.contains($0) }
    }
}

/// A named value kept in the variable library (outside pipelines) and offered to every run
/// as `{{ vars.name }}` and `$.vars.name`. Secret values are masked in the interface; they
/// are never part of an exported pipeline.
public struct PipelineVariable: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var value: String
    public var isSecret: Bool

    public init(id: UUID = UUID(), name: String, value: String = "", isSecret: Bool = false) {
        self.id = id
        self.name = name
        self.value = value
        self.isSecret = isSecret
    }

    private enum CodingKeys: String, CodingKey { case id, name, value, isSecret }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        isSecret = try c.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
    }

    /// The dictionary a run starts from. Later duplicates win.
    public static func values(_ variables: [PipelineVariable]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for variable in variables where !variable.name.isEmpty {
            out[variable.name] = .string(variable.value)
        }
        return out
    }
}

extension PipelineStepKind: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, language, code, expression, firstMatchOnly, depth, pipelineID, request, loop, variable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "script":
            self = .script(
                language: try container.decodeIfPresent(ScriptLanguage.self, forKey: .language) ?? .javascript,
                code: try container.decodeIfPresent(String.self, forKey: .code) ?? ""
            )
        case "jsonPath":
            self = .jsonPath(
                expression: try container.decodeIfPresent(String.self, forKey: .expression) ?? "$",
                firstMatchOnly: try container.decodeIfPresent(Bool.self, forKey: .firstMatchOnly) ?? false
            )
        case "flatten":
            self = .flatten(depth: try container.decodeIfPresent(Int.self, forKey: .depth))
        case "pipeline":
            self = .pipeline(id: try container.decode(UUID.self, forKey: .pipelineID))
        case "httpRequest":
            self = .httpRequest(try container.decodeIfPresent(HTTPRequestStep.self, forKey: .request) ?? HTTPRequestStep())
        case "forEach":
            self = .forEach(try container.decodeIfPresent(ForEachStep.self, forKey: .loop) ?? ForEachStep())
        case "setVariable":
            self = .setVariable(try container.decodeIfPresent(SetVariableStep.self, forKey: .variable) ?? SetVariableStep())
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown step type \"\(type)\"")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(typeIdentifier, forKey: .type)
        switch self {
        case .script(let language, let code):
            try container.encode(language, forKey: .language)
            try container.encode(code, forKey: .code)
        case .jsonPath(let expression, let firstMatchOnly):
            try container.encode(expression, forKey: .expression)
            try container.encode(firstMatchOnly, forKey: .firstMatchOnly)
        case .flatten(let depth):
            try container.encodeIfPresent(depth, forKey: .depth)
        case .pipeline(let id):
            try container.encode(id, forKey: .pipelineID)
        case .httpRequest(let request):
            try container.encode(request, forKey: .request)
        case .forEach(let loop):
            try container.encode(loop, forKey: .loop)
        case .setVariable(let variable):
            try container.encode(variable, forKey: .variable)
        }
    }
}

/// One block in a pipeline.
public struct PipelineStep: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    /// Optional user label. Empty means "use the kind's title".
    public var name: String
    /// Disabled steps pass their input through unchanged.
    public var isEnabled: Bool
    public var kind: PipelineStepKind

    public init(id: UUID = UUID(), name: String = "", isEnabled: Bool = true, kind: PipelineStepKind) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.kind = kind
    }

    public var displayName: String { name.isEmpty ? kind.title : name }

    private enum CodingKeys: String, CodingKey { case id, name, isEnabled, kind }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        kind = try container.decode(PipelineStepKind.self, forKey: .kind)
    }

    /// A copy with fresh ids for this step and every nested step.
    public func withFreshIDs() -> PipelineStep {
        var copy = self
        copy.id = UUID()
        if let children = copy.kind.childSteps {
            copy.kind.childSteps = children.map { $0.withFreshIDs() }
        }
        return copy
    }
}

/// An ordered list of steps. The document is the input of the first step; each step's output
/// feeds the next. Pipelines are saved in the library and can be applied to any document or
/// embedded in other pipelines.
public struct Pipeline: Identifiable, Hashable, Codable, Sendable {
    public static let fileExtension = "jayson-pipeline.json"

    public var id: UUID
    public var name: String
    public var steps: [PipelineStep]

    public init(id: UUID = UUID(), name: String, steps: [PipelineStep] = []) {
        self.id = id
        self.name = name
        self.steps = steps
    }

    // MARK: Step tree

    /// A step together with its place in the tree, in display order.
    public struct StepEntry: Hashable, Sendable {
        public var step: PipelineStep
        /// The For Each step containing it, or nil at the top level.
        public var parentID: UUID?
        public var depth: Int
        /// 1-based position among its siblings.
        public var position: Int
    }

    /// Every step, depth-first, in the order the panel lists them.
    public var allSteps: [StepEntry] {
        var out: [StepEntry] = []
        func walk(_ steps: [PipelineStep], parentID: UUID?, depth: Int) {
            for (index, step) in steps.enumerated() {
                out.append(StepEntry(step: step, parentID: parentID, depth: depth, position: index + 1))
                if let children = step.kind.childSteps { walk(children, parentID: step.id, depth: depth + 1) }
            }
        }
        walk(steps, parentID: nil, depth: 0)
        return out
    }

    /// Finds a step anywhere in the tree.
    public func step(withID id: UUID) -> PipelineStep? {
        allSteps.first { $0.step.id == id }?.step
    }

    public func entry(for id: UUID) -> StepEntry? {
        allSteps.first { $0.step.id == id }
    }

    /// Index among the top-level steps.
    public func index(of stepID: UUID) -> Int? {
        steps.firstIndex { $0.id == stepID }
    }

    /// The list of steps `id` belongs to: the top level, or a For Each body.
    public func siblings(of id: UUID) -> [PipelineStep] {
        guard let parentID = entry(for: id)?.parentID else { return steps }
        return step(withID: parentID)?.kind.childSteps ?? []
    }

    /// Edits the step with `id` wherever it is in the tree. Returns false when it is missing.
    @discardableResult
    public mutating func updateStep(_ id: UUID, _ body: (inout PipelineStep) -> Void) -> Bool {
        Self.update(&steps, id: id, body)
    }

    private static func update(_ steps: inout [PipelineStep], id: UUID, _ body: (inout PipelineStep) -> Void) -> Bool {
        for index in steps.indices {
            if steps[index].id == id {
                body(&steps[index])
                return true
            }
            if var children = steps[index].kind.childSteps {
                if update(&children, id: id, body) {
                    steps[index].kind.childSteps = children
                    return true
                }
            }
        }
        return false
    }

    /// Replaces the sibling list that contains `id` (or the top level when `id` is nil).
    public mutating func updateSiblings(of id: UUID?, _ body: (inout [PipelineStep]) -> Void) {
        guard let id, let parentID = entry(for: id)?.parentID else {
            body(&steps)
            return
        }
        updateStep(parentID) { parent in
            guard var children = parent.kind.childSteps else { return }
            body(&children)
            parent.kind.childSteps = children
        }
    }

    /// Inserts `step` after `afterID` in its sibling list, or appends it to the body of
    /// `insideID`, or appends it to the top level when both are nil.
    public mutating func insert(_ step: PipelineStep, after afterID: UUID? = nil, inside insideID: UUID? = nil) {
        if let insideID {
            updateStep(insideID) { parent in
                guard var children = parent.kind.childSteps else { return }
                children.append(step)
                parent.kind.childSteps = children
            }
        } else if let afterID {
            updateSiblings(of: afterID) { siblings in
                if let index = siblings.firstIndex(where: { $0.id == afterID }) {
                    siblings.insert(step, at: index + 1)
                } else {
                    siblings.append(step)
                }
            }
        } else {
            steps.append(step)
        }
    }

    /// Removes a step from wherever it is. Returns the step that now sits at its position,
    /// or the last sibling, for reselection.
    @discardableResult
    public mutating func remove(_ id: UUID) -> PipelineStep? {
        var replacement: PipelineStep?
        updateSiblings(of: id) { siblings in
            guard let index = siblings.firstIndex(where: { $0.id == id }) else { return }
            siblings.remove(at: index)
            replacement = siblings.indices.contains(index) ? siblings[index] : siblings.last
        }
        return replacement
    }

    /// Swaps a step with its neighbour among its siblings.
    public mutating func move(_ id: UUID, by offset: Int) {
        updateSiblings(of: id) { siblings in
            guard let index = siblings.firstIndex(where: { $0.id == id }) else { return }
            let target = index + offset
            guard siblings.indices.contains(target) else { return }
            siblings.swapAt(index, target)
        }
    }

    /// The code a new script step starts with.
    public static func starterCode(for language: ScriptLanguage) -> String {
        switch language {
        case .javascript:
            return """
            // `input` is this step's JSON. Return the value to pass on,
            // or write a single expression such as `input.items.map(i => i.name)`.
            // Helpers live on `$`: $.flatten, $.pick, $.groupBy, $.jsonPath, $.vars, …
            return input
            """
        case .typescript:
            return """
            // `input` is typed from the schema (see the Types tab).
            // Return the value to pass on, or write a single expression.
            return input
            """
        }
    }

    /// Encodes the pipeline as pretty-printed JSON for export.
    public func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Decodes a pipeline exported with `exportJSON()`.
    public static func importJSON(_ data: Data) throws -> Pipeline {
        try JSONDecoder().decode(Pipeline.self, from: data)
    }
}
