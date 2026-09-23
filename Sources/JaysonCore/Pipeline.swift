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
public enum PipelineStepKind: Hashable, Sendable {
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

    public var typeIdentifier: String {
        switch self {
        case .script: return "script"
        case .jsonPath: return "jsonPath"
        case .flatten: return "flatten"
        case .pipeline: return "pipeline"
        case .httpRequest: return "httpRequest"
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
        }
    }
}

/// Configuration of an `.httpRequest` step. The URL, header values and custom body accept
/// `{{ path }}` placeholders resolved against the step input (`{{ input.user.id }}` or
/// `{{ user.id }}`; strings are inserted raw, other values as minified JSON).
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

    /// Replaces `{{ path }}` placeholders with values from `input`. Unknown paths become "".
    public static func expand(_ template: String, input: JSONValue) -> String {
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
            result += render(value(at: path, in: input))
            rest = rest[close.upperBound...]
        }
        result += rest
        return result
    }

    private static func value(at path: String, in input: JSONValue) -> JSONValue? {
        var components = path.replacingOccurrences(of: "]", with: "").split(whereSeparator: { $0 == "." || $0 == "[" }).map(String.init)
        if let first = components.first, first == "input" || first == "$" { components.removeFirst() }
        var current = input
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

    private static func render(_ value: JSONValue?) -> String {
        switch value {
        case nil, .null?: return ""
        case .string(let s)?: return s
        case let other?: return JSONFormatter.minify(other)
        }
    }

    /// The cache key for a fully expanded request.
    public func cacheKey(input: JSONValue) -> String {
        let headerText = headers.map { "\($0.name):\(Self.expand($0.value, input: input))" }.joined(separator: "\n")
        let body: String
        switch bodyMode {
        case .none: body = ""
        case .input: body = method.allowsBody ? JSONFormatter.minify(input) : ""
        case .custom: body = method.allowsBody ? Self.expand(customBody, input: input) : ""
        }
        return [method.rawValue, Self.expand(url, input: input), headerText, body, outputMode.rawValue, failOnErrorStatus ? "fail" : "pass"].joined(separator: "\u{0}")
    }
}

extension PipelineStepKind: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, language, code, expression, firstMatchOnly, depth, pipelineID, request
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

    public func step(withID id: UUID) -> PipelineStep? {
        steps.first { $0.id == id }
    }

    public func index(of stepID: UUID) -> Int? {
        steps.firstIndex { $0.id == stepID }
    }

    /// The code a new script step starts with.
    public static func starterCode(for language: ScriptLanguage) -> String {
        switch language {
        case .javascript:
            return """
            // `input` is this step's JSON. Return the value to pass on,
            // or write a single expression such as `input.items.map(i => i.name)`.
            // Helpers live on `$`: $.flatten, $.pick, $.groupBy, $.jsonPath, …
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
