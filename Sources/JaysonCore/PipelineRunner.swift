import Foundation

// MARK: - Results

public struct PipelineStepResult: Identifiable, Hashable, Sendable {
    /// The step's id.
    public var id: UUID
    public var input: JSONValue?
    public var output: JSONValue?
    public var error: String?
    /// Line inside a script step where the error happened, when known.
    public var errorLine: Int?
    public var logs: [String] = []
    public var duration: TimeInterval = 0
    /// True when the step did not run: it is disabled, or an earlier step failed.
    public var wasSkipped = false
    /// True when an HTTP step was not sent because the run only allowed cached responses.
    public var wasDeferred = false

    public var isFailure: Bool { error != nil }
}

public struct PipelineRunResult: Hashable, Sendable {
    public var pipelineID: UUID
    public var input: JSONValue
    public var steps: [PipelineStepResult]
    /// The last step's output, or nil when the pipeline failed.
    public var output: JSONValue?
    public var failedStepID: UUID?
    public var duration: TimeInterval

    public var isSuccess: Bool { failedStepID == nil }

    public func result(for stepID: UUID) -> PipelineStepResult? {
        steps.first { $0.id == stepID }
    }

    public var failure: PipelineStepResult? {
        guard let failedStepID else { return nil }
        return result(for: failedStepID)
    }

    /// The run stopped at an HTTP step that is waiting for an explicit run.
    public var isDeferred: Bool { failure?.wasDeferred == true }
}

/// Remembers HTTP responses by request so live runs (which never touch the network) can reuse
/// what an explicit run fetched. Thread-safe.
public final class HTTPResponseCache: @unchecked Sendable {
    private var storage: [String: JSONValue] = [:]
    private let lock = NSLock()

    public init() {}

    public func value(for key: String) -> JSONValue? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func store(_ value: JSONValue, for key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}

// MARK: - Runner

/// Executes a pipeline step by step. Steps run sequentially; a failing step stops the run and
/// the remaining steps are reported as skipped.
public struct PipelineRunner: Sendable {
    public enum NetworkPolicy: Sendable {
        /// HTTP steps send their request (and store the response in `httpCache`).
        case allow
        /// HTTP steps only use cached responses; otherwise the run stops there, deferred.
        case cachedOnly
    }

    /// Looks up pipelines referenced by `.pipeline` steps (normally the library).
    public var resolvePipeline: @Sendable (UUID) -> Pipeline?
    public var scriptTimeout: TimeInterval = ScriptEngine.defaultTimeout
    public var typeScript: TypeScriptService = .shared
    public var networkPolicy: NetworkPolicy = .allow
    public var httpCache: HTTPResponseCache?
    public var urlSession: URLSession = .shared

    public init(resolvePipeline: @escaping @Sendable (UUID) -> Pipeline? = { _ in nil }) {
        self.resolvePipeline = resolvePipeline
    }

    public func run(_ pipeline: Pipeline, input: JSONValue, schema: JSONValue? = nil) async -> PipelineRunResult {
        await run(pipeline, input: input, schema: schema, visited: [])
    }

    private func run(_ pipeline: Pipeline, input: JSONValue, schema: JSONValue?, visited: Set<UUID>) async -> PipelineRunResult {
        let start = Date()
        var results: [PipelineStepResult] = []
        var current: JSONValue? = input
        var failedStepID: UUID?
        var previousOutputs: [JSONValue?] = []
        var previousNames: [String] = []

        for step in pipeline.steps {
            guard let stepInput = current, failedStepID == nil else {
                results.append(PipelineStepResult(id: step.id, wasSkipped: true))
                continue
            }
            guard step.isEnabled else {
                results.append(PipelineStepResult(id: step.id, input: stepInput, output: stepInput, wasSkipped: true))
                previousOutputs.append(stepInput)
                previousNames.append(step.displayName)
                continue
            }
            var context = ScriptContext(input: stepInput, document: input, schema: stepInput == input ? schema : nil)
            context.previousOutputs = previousOutputs
            context.previousNames = previousNames
            var result = await execute(step, context: context, visited: visited.union([pipeline.id]))
            result.id = step.id
            result.input = stepInput
            if let output = result.output, result.error == nil {
                current = output
            } else {
                failedStepID = step.id
                current = nil
            }
            results.append(result)
            previousOutputs.append(result.output)
            previousNames.append(step.displayName)
        }

        return PipelineRunResult(
            pipelineID: pipeline.id,
            input: input,
            steps: results,
            output: failedStepID == nil ? current : nil,
            failedStepID: failedStepID,
            duration: Date().timeIntervalSince(start)
        )
    }

    private func execute(_ step: PipelineStep, context: ScriptContext, visited: Set<UUID>) async -> PipelineStepResult {
        let start = Date()
        var result = PipelineStepResult(id: step.id)
        switch step.kind {
        case .script(let language, let code):
            var javaScript = code
            if language == .typescript {
                do {
                    javaScript = try await typeScript.transpile(code)
                } catch let error as TypeScriptError {
                    if case .syntax(let diagnostics) = error, let first = diagnostics.first {
                        result.error = first.message
                        result.errorLine = first.line
                    } else {
                        result.error = error.localizedDescription
                    }
                    result.duration = Date().timeIntervalSince(start)
                    return result
                } catch {
                    result.error = error.localizedDescription
                    result.duration = Date().timeIntervalSince(start)
                    return result
                }
            }
            let outcome = await Self.runScript(javaScript, context: context, timeout: scriptTimeout)
            result.output = outcome.output
            result.error = outcome.error?.message
            result.errorLine = outcome.error?.line
            result.logs = outcome.logs

        case .jsonPath(let expression, let firstMatchOnly):
            do {
                let matches = try JSONPathQuery.evaluate(expression, on: context.input)
                if firstMatchOnly {
                    result.output = matches.first?.value ?? .null
                } else {
                    result.output = .array(matches.map(\.value))
                }
            } catch let error as JSONPathError {
                result.error = error.message
            } catch {
                result.error = error.localizedDescription
            }

        case .flatten(let depth):
            guard let elements = context.input.arrayValue else {
                result.error = "Flatten expects an array, but the input is \(article(context.input.typeName))."
                break
            }
            result.output = .array(Self.flatten(elements, depth: depth ?? Int.max))

        case .pipeline(let id):
            guard let nested = resolvePipeline(id) else {
                result.error = "The referenced pipeline no longer exists in the library."
                break
            }
            guard !visited.contains(id) else {
                result.error = "“\(nested.name)” would run itself recursively."
                break
            }
            let inner = await run(nested, input: context.input, schema: nil, visited: visited)
            if let failure = inner.failure {
                let failedName = nested.step(withID: failure.id)?.displayName ?? "a step"
                result.error = "“\(nested.name)” failed at \(failedName): \(failure.error ?? "unknown error")"
                result.wasDeferred = failure.wasDeferred
            } else {
                result.output = inner.output
            }
            result.logs = inner.steps.flatMap(\.logs)

        case .httpRequest(let request):
            let key = request.cacheKey(input: context.input)
            if let cached = httpCache?.value(for: key) {
                result.output = cached
                result.logs = ["Reused the response from the last run (press Run to send again)."]
                break
            }
            if networkPolicy == .cachedOnly {
                result.wasDeferred = true
                result.error = "Requests are not sent while editing. Press Run (⌥⌘R) to send it."
                break
            }
            do {
                let (value, log) = try await send(request, input: context.input)
                result.output = value
                result.logs = [log]
                httpCache?.store(value, for: key)
            } catch {
                result.error = error.localizedDescription
            }
        }
        result.duration = Date().timeIntervalSince(start)
        return result
    }

    /// Scripts block their thread (JavaScriptCore is synchronous), so they run off the
    /// cooperative pool to keep other async work responsive.
    private static func runScript(_ javaScript: String, context: ScriptContext, timeout: TimeInterval) async -> ScriptRunOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ScriptEngine.run(javaScript: javaScript, context: context, timeout: timeout))
            }
        }
    }

    // MARK: HTTP

    private struct HTTPStepError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private func send(_ step: HTTPRequestStep, input: JSONValue) async throws -> (JSONValue, String) {
        let urlText = HTTPRequestStep.expand(step.url, input: input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlText.isEmpty else { throw HTTPStepError(message: "Enter a URL for the request.") }
        guard let url = URL(string: urlText), url.scheme != nil else { throw HTTPStepError(message: "“\(urlText)” is not a valid URL.") }

        var request = URLRequest(url: url, timeoutInterval: step.timeout)
        request.httpMethod = step.method.rawValue
        request.setValue("application/json, */*;q=0.8", forHTTPHeaderField: "Accept")
        var hasContentType = false
        for header in step.headers where !header.name.trimmingCharacters(in: .whitespaces).isEmpty {
            request.setValue(HTTPRequestStep.expand(header.value, input: input), forHTTPHeaderField: header.name)
            if header.name.lowercased() == "content-type" { hasContentType = true }
        }
        if step.method.allowsBody {
            switch step.bodyMode {
            case .none: break
            case .input:
                request.httpBody = Data(JSONFormatter.minify(input).utf8)
                if !hasContentType { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            case .custom:
                let body = HTTPRequestStep.expand(step.customBody, input: input)
                request.httpBody = Data(body.utf8)
                if !hasContentType { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            }
        }

        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw HTTPStepError(message: "Request failed: \(error.localizedDescription)")
        }
        let elapsed = Date().timeIntervalSince(started)

        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let body: JSONValue
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body = .null
        } else if let parsed = try? JSONParser.parse(text) {
            body = parsed
        } else {
            body = .string(text)
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        if step.failOnErrorStatus, !(200..<300).contains(status) {
            let preview = JSONFormatter.preview(body, maxLength: 160)
            throw HTTPStepError(message: "Server returned HTTP \(status)\(preview.isEmpty || preview == "null" ? "" : ": \(preview)")")
        }
        let log = "\(step.method.rawValue) \(urlText) → \(status) · \(data.count) bytes · \(Int(elapsed * 1000)) ms"

        switch step.outputMode {
        case .body:
            return (body, log)
        case .full:
            var headers = JSONObject()
            for (name, value) in http?.allHeaderFields ?? [:] {
                headers[String(describing: name)] = .string(String(describing: value))
            }
            return (.object(JSONObject([("status", .number(status)), ("headers", .object(headers.sortedByKey())), ("body", body)])), log)
        }
    }

    static func flatten(_ elements: [JSONValue], depth: Int) -> [JSONValue] {
        guard depth > 0 else { return elements }
        var out: [JSONValue] = []
        for element in elements {
            if let nested = element.arrayValue {
                out.append(contentsOf: flatten(nested, depth: depth - 1))
            } else {
                out.append(element)
            }
        }
        return out
    }

    private func article(_ typeName: String) -> String {
        switch typeName {
        case "object", "array": return "an \(typeName)"
        case "null": return "null"
        default: return "a \(typeName)"
        }
    }
}

// MARK: - Type declarations for script steps

extension PipelineRunner {
    /// The `.d.ts` text a TypeScript step is checked against: `Input` (from the schema when
    /// the step reads the document and a schema is loaded, otherwise inferred from the
    /// actual input), the `$` helpers, and `console`.
    public static func declarations(input: JSONValue?, schema: JSONValue?) -> String {
        let inputType: String
        if let schema {
            inputType = SchemaTypeScript.declarations(for: schema)
        } else if let input {
            inputType = SchemaTypeScript.declarations(inferredFrom: input)
        } else {
            inputType = "type Input = unknown;\n"
        }
        return inputType + "\n" + helperDeclarations
    }

    public static let helperDeclarations = """
    declare const input: Input;

    type KeyOrFn<T> = keyof T | string | ((item: T) => unknown);

    interface JaysonHelpers {
      /** The pipeline's original input (the whole document). */
      readonly document: unknown;
      /** The schema loaded for the document, or null. */
      readonly schema: unknown;
      /** Outputs of the previous steps, in order. */
      readonly steps: unknown[];
      /** Output of a previous step by name or index (negative counts from the end). */
      step(nameOrIndex: string | number): unknown;
      /** Reads a dotted path such as "store.book[0].title". */
      get(value: unknown, path: string | (string | number)[], fallback?: unknown): unknown;
      flatten<T>(array: T[], depth?: number): unknown[];
      flattenDeep(array: unknown[]): unknown[];
      /** Turns nested objects into one level of dotted keys. */
      flattenObject(value: unknown, separator?: string): Record<string, unknown>;
      pick<T extends object>(value: T, ...keys: (keyof T | string | string[])[]): Partial<T>;
      pick<T extends object>(value: T[], ...keys: (keyof T | string | string[])[]): Partial<T>[];
      omit<T extends object>(value: T, ...keys: (keyof T | string | string[])[]): Partial<T>;
      omit<T extends object>(value: T[], ...keys: (keyof T | string | string[])[]): Partial<T>[];
      rename(value: unknown, mapping: Record<string, string>): unknown;
      mapValues<T, U>(value: Record<string, T>, transform: (value: T, key: string) => U): Record<string, U>;
      keys(value: object): string[];
      values<T>(value: Record<string, T>): T[];
      entries<T>(value: Record<string, T>): [string, T][];
      fromEntries<T>(entries: Iterable<readonly [string, T]>): Record<string, T>;
      groupBy<T>(array: T[], key: KeyOrFn<T>): Record<string, T[]>;
      countBy<T>(array: T[], key: KeyOrFn<T>): Record<string, number>;
      sortBy<T>(array: T[], key: KeyOrFn<T>, direction?: "asc" | "desc"): T[];
      uniq<T>(array: T[]): T[];
      uniqBy<T>(array: T[], key: KeyOrFn<T>): T[];
      sum<T>(array: T[], key?: KeyOrFn<T>): number;
      min<T>(array: T[], key?: KeyOrFn<T>): number | undefined;
      max<T>(array: T[], key?: KeyOrFn<T>): number | undefined;
      compact<T>(array: (T | null | undefined)[]): T[];
      chunk<T>(array: T[], size: number): T[][];
      /** Evaluates a JSONPath expression and returns the matching values. */
      jsonPath(value: unknown, expression: string): unknown[];
      clone<T>(value: T): T;
    }
    declare const $: JaysonHelpers;

    declare const console: {
      log(...args: unknown[]): void;
      info(...args: unknown[]): void;
      warn(...args: unknown[]): void;
      error(...args: unknown[]): void;
      debug(...args: unknown[]): void;
      table(...args: unknown[]): void;
      dir(...args: unknown[]): void;
    };
    """
}
