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
    /// For a For Each step: one run of the body per input item, in input order.
    public var iterations: [PipelineRunResult] = []

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
    /// Variables at the end of the run (library values plus everything set during it).
    public var variables: [String: JSONValue] = [:]
    /// Variables that Set Variable steps asked to save to the library.
    public var savedVariables: [String: JSONValue] = [:]

    public var isSuccess: Bool { failedStepID == nil }

    /// The result of a step at this level, or, for a step inside a For Each, its result in
    /// the first iteration that ran it.
    public func result(for stepID: UUID) -> PipelineStepResult? {
        if let direct = steps.first(where: { $0.id == stepID }) { return direct }
        for step in steps where !step.iterations.isEmpty {
            for iteration in step.iterations {
                if let nested = iteration.result(for: stepID) { return nested }
            }
        }
        return nil
    }

    /// The result of a step inside a For Each for one particular item.
    public func result(for stepID: UUID, iteration index: Int) -> PipelineStepResult? {
        guard let loop = loopResult(containing: stepID) else { return result(for: stepID) }
        guard loop.iterations.indices.contains(index) else { return nil }
        return loop.iterations[index].result(for: stepID, iteration: index)
    }

    /// The For Each result (at any depth) whose iterations ran `stepID`.
    public func loopResult(containing stepID: UUID) -> PipelineStepResult? {
        for step in steps where !step.iterations.isEmpty {
            for iteration in step.iterations {
                if iteration.steps.contains(where: { $0.id == stepID }) { return step }
                if let deeper = iteration.loopResult(containing: stepID) { return deeper }
            }
        }
        return nil
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

    /// What every step of one pipeline run shares.
    private struct Scope: Sendable {
        var document: JSONValue
        var schema: JSONValue?
        var variables: [String: JSONValue]
        var savedVariables: [String: JSONValue] = [:]
        var loop: TemplateContext.LoopInfo?
        var visited: Set<UUID>
    }

    /// Runs `pipeline` on `input`. `variables` seeds `{{ vars.… }}` / `$.vars` (normally the
    /// variable library).
    public func run(_ pipeline: Pipeline, input: JSONValue, schema: JSONValue? = nil, variables: [String: JSONValue] = [:]) async -> PipelineRunResult {
        var scope = Scope(document: input, schema: schema, variables: variables, visited: [])
        return await run(pipeline.steps, pipelineID: pipeline.id, input: input, scope: &scope)
    }

    private func run(_ steps: [PipelineStep], pipelineID: UUID, input: JSONValue, scope: inout Scope) async -> PipelineRunResult {
        let start = Date()
        var results: [PipelineStepResult] = []
        var current: JSONValue? = input
        var failedStepID: UUID?
        var previousOutputs: [JSONValue?] = []
        var previousNames: [String] = []
        var stepsByName: [String: JSONValue] = [:]

        for step in steps {
            guard let stepInput = current, failedStepID == nil else {
                results.append(PipelineStepResult(id: step.id, wasSkipped: true))
                continue
            }
            guard step.isEnabled else {
                results.append(PipelineStepResult(id: step.id, input: stepInput, output: stepInput, wasSkipped: true))
                previousOutputs.append(stepInput)
                previousNames.append(step.displayName)
                stepsByName[step.displayName] = stepInput
                stepsByName[String(previousOutputs.count)] = stepInput
                continue
            }
            if Task.isCancelled {
                results.append(PipelineStepResult(id: step.id, input: stepInput, error: "The run was cancelled."))
                failedStepID = step.id
                current = nil
                continue
            }
            var context = ScriptContext(input: stepInput, document: scope.document, schema: stepInput == scope.document && scope.loop == nil ? scope.schema : nil)
            context.previousOutputs = previousOutputs
            context.previousNames = previousNames
            context.variables = scope.variables
            context.loop = scope.loop
            let template = TemplateContext(input: stepInput, variables: scope.variables, document: scope.document, steps: stepsByName, loop: scope.loop)
            var result = await execute(step, context: context, template: template, pipelineID: pipelineID, scope: &scope)
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
            if let output = result.output {
                stepsByName[step.displayName] = output
                stepsByName[String(previousOutputs.count)] = output
            }
        }

        return PipelineRunResult(
            pipelineID: pipelineID,
            input: input,
            steps: results,
            output: failedStepID == nil ? current : nil,
            failedStepID: failedStepID,
            duration: Date().timeIntervalSince(start),
            variables: scope.variables,
            savedVariables: scope.savedVariables
        )
    }

    private func execute(_ step: PipelineStep, context: ScriptContext, template: TemplateContext, pipelineID: UUID, scope: inout Scope) async -> PipelineStepResult {
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
            if outcome.error == nil {
                for (name, value) in outcome.variableUpdates { scope.variables[name] = value }
            }

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
            guard !scope.visited.contains(id), id != pipelineID else {
                result.error = "“\(nested.name)” would run itself recursively."
                break
            }
            var innerScope = scope
            innerScope.schema = nil
            innerScope.visited.insert(pipelineID)
            let inner = await run(nested.steps, pipelineID: nested.id, input: context.input, scope: &innerScope)
            scope.variables = innerScope.variables
            scope.savedVariables.merge(innerScope.savedVariables) { _, new in new }
            if let failure = inner.failure {
                let failedName = nested.step(withID: failure.id)?.displayName ?? "a step"
                result.error = "“\(nested.name)” failed at \(failedName): \(failure.error ?? "unknown error")"
                result.wasDeferred = failure.wasDeferred
            } else {
                result.output = inner.output
            }
            result.logs = inner.steps.flatMap(\.logs)

        case .httpRequest(let request):
            let key = request.cacheKey(context: template)
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
                let (value, log) = try await send(request, context: template)
                result.output = value
                result.logs = [log]
                httpCache?.store(value, for: key)
            } catch {
                result.error = error.localizedDescription
            }

        case .forEach(let loop):
            result = await runLoop(loop, step: step, input: context.input, pipelineID: pipelineID, scope: &scope)

        case .setVariable(let assignment):
            let name = assignment.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                result.error = "Give the variable a name."
                break
            }
            guard SetVariableStep.isValidName(name) else {
                result.error = "“\(name)” is not a valid variable name. Use letters, digits and underscores, starting with a letter."
                break
            }
            let value = assignment.resolve(in: template)
            scope.variables[name] = value
            if assignment.saveToLibrary { scope.savedVariables[name] = value }
            result.output = context.input
            result.logs = ["\(name) = \(JSONFormatter.preview(value, maxLength: 120))\(assignment.saveToLibrary ? " · saved to the library" : "")"]
        }
        result.duration = Date().timeIntervalSince(start)
        return result
    }

    // MARK: For Each

    private func runLoop(_ loop: ForEachStep, step: PipelineStep, input: JSONValue, pipelineID: UUID, scope: inout Scope) async -> PipelineStepResult {
        let start = Date()
        var result = PipelineStepResult(id: step.id)
        guard let items = input.arrayValue else {
            result.error = "For Each expects an array, but the input is \(article(input.typeName)). Select the array first (for example with JSONPath or `Object.values(input)`)."
            result.duration = Date().timeIntervalSince(start)
            return result
        }
        let concurrency = max(1, min(loop.concurrency, ForEachStep.maxConcurrency))
        let count = items.count
        let baseScope = scope
        let runner = self

        // Each iteration works on a copy of the variables; the body cannot leak assignments
        // into the outer run (iterations may run concurrently), but library saves are kept.
        var iterations = [PipelineRunResult?](repeating: nil, count: count)
        await withTaskGroup(of: (Int, PipelineRunResult).self) { group in
            var next = 0
            func enqueue() {
                guard next < count else { return }
                let index = next
                let item = items[index]
                next += 1
                group.addTask {
                    var iterationScope = baseScope
                    iterationScope.schema = nil
                    iterationScope.loop = TemplateContext.LoopInfo(index: index, count: count, item: item)
                    let run = await runner.run(loop.steps, pipelineID: pipelineID, input: item, scope: &iterationScope)
                    return (index, run)
                }
            }
            // On the first failure (with the `fail` policy) or a cancelled run, no further
            // items start; the ones in flight finish so the lowest failing item is reported.
            var stopped = false
            for _ in 0..<min(concurrency, count) { enqueue() }
            while let (index, run) = await group.next() {
                iterations[index] = run
                if (loop.errorPolicy == .fail && !run.isSuccess) || Task.isCancelled { stopped = true }
                if !stopped { enqueue() }
            }
        }

        var outputs: [JSONValue] = []
        var failures: [(index: Int, run: PipelineRunResult)] = []
        var deferred = false
        for (index, item) in items.enumerated() {
            guard let run = iterations[index] else { continue }
            if let failure = run.failure {
                failures.append((index, run))
                if failure.wasDeferred { deferred = true }
                if loop.errorPolicy == .null { outputs.append(.null) }
                continue
            }
            for (name, value) in run.savedVariables { scope.savedVariables[name] = value }
            let output = run.output ?? .null
            outputs.append(loop.outputMode == .merged ? ForEachStep.merge(item: item, result: output) : output)
        }
        result.iterations = iterations.enumerated().map { index, run in
            run ?? PipelineRunResult(pipelineID: pipelineID, input: items[index], steps: loop.steps.map { PipelineStepResult(id: $0.id, wasSkipped: true) }, output: nil, failedStepID: nil, duration: 0)
        }
        result.wasDeferred = deferred

        if loop.errorPolicy == .fail, let first = failures.min(by: { $0.index < $1.index }), let failure = first.run.failure {
            let name = loop.steps.first { $0.id == failure.id }?.displayName ?? "a step"
            if failure.wasDeferred {
                result.error = "Item \(first.index + 1) of \(count): \(failure.error ?? "the request was not sent")"
            } else {
                result.error = "Item \(first.index + 1) of \(count) failed at \(name): \(failure.error ?? "unknown error")"
            }
        } else if Task.isCancelled, iterations.contains(where: { $0 == nil }) {
            result.error = "The run was cancelled."
        } else {
            result.output = .array(outputs)
            var summary = "Ran \(count) item\(count == 1 ? "" : "s")"
            if !failures.isEmpty {
                summary += " · \(failures.count) failed and \(loop.errorPolicy == .skip ? "were left out" : "became null")"
            }
            if concurrency > 1, count > 1 { summary += " · up to \(concurrency) at a time" }
            result.logs = [summary] + failures.prefix(10).map { "Item \($0.index + 1): \($0.run.failure?.error ?? "failed")" }
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

    private func send(_ step: HTTPRequestStep, context: TemplateContext) async throws -> (JSONValue, String) {
        let urlText = context.expand(step.url).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlText.isEmpty else { throw HTTPStepError(message: "Enter a URL for the request.") }
        guard let url = URL(string: urlText), url.scheme != nil else { throw HTTPStepError(message: "“\(urlText)” is not a valid URL.") }

        var request = URLRequest(url: url, timeoutInterval: step.timeout)
        request.httpMethod = step.method.rawValue
        request.setValue("application/json, */*;q=0.8", forHTTPHeaderField: "Accept")
        var hasContentType = false
        for header in step.headers where !header.name.trimmingCharacters(in: .whitespaces).isEmpty {
            request.setValue(context.expand(header.value), forHTTPHeaderField: header.name)
            if header.name.lowercased() == "content-type" { hasContentType = true }
        }
        if step.method.allowsBody {
            switch step.bodyMode {
            case .none: break
            case .input:
                request.httpBody = Data(JSONFormatter.minify(context.input).utf8)
                if !hasContentType { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            case .custom:
                let body = context.expand(step.customBody)
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

    interface JaysonLoop {
      /** 0-based position of the current item. */
      readonly index: number;
      readonly count: number;
      /** The item this iteration started with. */
      readonly item: unknown;
    }

    interface JaysonHelpers {
      /** The pipeline's original input (the whole document). */
      readonly document: unknown;
      /** The schema loaded for the document, or null. */
      readonly schema: unknown;
      /** Outputs of the previous steps, in order. */
      readonly steps: unknown[];
      /** Output of a previous step by name or index (negative counts from the end). */
      step(nameOrIndex: string | number): unknown;
      /** Variables: the library values plus everything set earlier in this run. */
      readonly vars: Record<string, unknown>;
      /** Sets a variable for the rest of the run (`{{ vars.name }}` in later steps). */
      setVar(name: string, value: unknown): void;
      /** The current For Each iteration, or null outside a loop. */
      readonly loop: JaysonLoop | null;
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
