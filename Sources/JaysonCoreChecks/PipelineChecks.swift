import Foundation
import JaysonCore

/// Runs async work synchronously for the check harness.
func awaitValue<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: T?
    Task.detached {
        result = await body()
        semaphore.signal()
    }
    semaphore.wait()
    return result!
}

private let sample: JSONValue = [
    "store": [
        "name": "Jayson Books",
        "book": [
            ["title": "A", "price": 8.95, "tags": ["x", "y"]],
            ["title": "B", "price": 12.99, "tags": ["z"]],
            ["title": "C", "price": 22.99, "tags": []],
        ],
    ],
]

func runPipelineModelChecks() {
    check("pipeline JSON round-trips every step kind") {
        let sub = UUID()
        let pipeline = Pipeline(name: "Test", steps: [
            PipelineStep(name: "titles", kind: .script(language: .javascript, code: "input.map(b => b.title)")),
            PipelineStep(kind: .script(language: .typescript, code: "return input as string[]")),
            PipelineStep(kind: .jsonPath(expression: "$..title", firstMatchOnly: true)),
            PipelineStep(isEnabled: false, kind: .flatten(depth: nil)),
            PipelineStep(kind: .flatten(depth: 2)),
            PipelineStep(kind: .pipeline(id: sub)),
            PipelineStep(kind: .httpRequest({
                var r = HTTPRequestStep()
                r.method = .post
                r.url = "https://example.com/{{ id }}"
                r.headers = [.init(name: "Authorization", value: "Bearer x")]
                r.bodyMode = .custom
                r.customBody = "{\"a\":1}"
                r.outputMode = .full
                r.failOnErrorStatus = false
                return r
            }())),
        ])
        let data = try pipeline.exportJSON()
        let decoded = try Pipeline.importJSON(data)
        expectEqual(decoded, pipeline)
        let text = String(decoding: data, as: UTF8.self)
        expect(text.contains("\"type\" : \"jsonPath\""), "uses a type discriminator")
        expect(text.contains("\"pipelineID\""), "pipeline reference is encoded")
    }

    check("decoding tolerates missing optional fields and rejects unknown kinds") {
        let minimal = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"m","steps":[{"kind":{"type":"flatten"}}]}"#
        let pipeline = try Pipeline.importJSON(Data(minimal.utf8))
        expectEqual(pipeline.steps.count, 1)
        expectEqual(pipeline.steps[0].kind, .flatten(depth: nil))
        expect(pipeline.steps[0].isEnabled)
        expectEqual(pipeline.steps[0].displayName, "Flatten")
        let bogus = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"m","steps":[{"kind":{"type":"teleport"}}]}"#
        expectThrows { _ = try Pipeline.importJSON(Data(bogus.utf8)) }
    }
}

func runScriptEngineChecks() {
    func run(_ code: String, input: JSONValue = sample, timeout: TimeInterval = 5) -> ScriptRunOutcome {
        ScriptEngine.run(javaScript: code, context: ScriptContext(input: input), timeout: timeout)
    }

    check("bare expression is returned") {
        let outcome = run("input.store.book.map(b => b.title)")
        expectNil(outcome.error)
        expectEqual(outcome.output, ["A", "B", "C"])
    }

    check("function body with return, statements and comments") {
        let outcome = run("""
        // total price
        const prices = input.store.book.map(b => b.price);
        let total = 0;
        for (const p of prices) total += p;
        return { total: Math.round(total * 100) / 100, count: prices.length };
        """)
        expectNil(outcome.error)
        expectEqual(outcome.output, ["total": 44.93, "count": 3])
    }

    check("object literal expression and key order survive") {
        let outcome = run("({ z: 1, a: input.store.name })")
        expectEqual(outcome.output, ["z": 1, "a": "Jayson Books"])
        expectEqual(outcome.output?.objectValue?.keys, ["z", "a"])
        let braces = run("{ z: 1, a: 2 }")
        expectEqual(braces.output, ["z": 1, "a": 2])
    }

    check("console output is captured in order") {
        let outcome = run("console.log('hello', { a: 1 }); console.warn('careful'); return 1")
        expectEqual(outcome.logs, ["hello {\n  \"a\": 1\n}", "[warn] careful"])
        expectEqual(outcome.output, 1)
    }

    check("undefined result is an error with guidance") {
        let outcome = run("const x = 1;")
        expect(outcome.error?.message.contains("did not return") == true, "\(outcome.error?.message ?? "nil")")
        expectNil(outcome.output)
    }

    check("runtime errors report the user's line") {
        let outcome = run("""
        const a = 1;
        const b = input.nothing.here;
        return b;
        """)
        expect(outcome.error?.message.contains("undefined") == true, "\(outcome.error?.message ?? "nil")")
        expectEqual(outcome.error?.line, 2)
        let thrown = run("throw new Error('boom')")
        expectEqual(thrown.error?.message, "boom")
        expectEqual(thrown.error?.line, 1)
    }

    check("syntax errors report the user's line") {
        let outcome = run("""
        const a = 1;
        const b = ;
        return a;
        """)
        expectEqual(outcome.error?.line, 2, "\(outcome.error?.message ?? "nil")")
    }

    check("runaway scripts are stopped") {
        let start = Date()
        let outcome = run("while (true) {}", timeout: 0.3)
        expect(Date().timeIntervalSince(start) < 3, "returned promptly")
        expect(outcome.error?.message.contains("too long") == true, "\(outcome.error?.message ?? "nil")")
    }

    check("helpers: flatten, pick, groupBy, sortBy, sum, get, flattenObject") {
        let outcome = run("""
        const books = input.store.book;
        return {
          tags: $.flatten(books.map(b => b.tags)),
          picked: $.pick(books, "title"),
          groups: $.keys($.groupBy(books, b => b.price > 10 ? "pricey" : "cheap")),
          sorted: $.sortBy(books, "price", "desc").map(b => b.title),
          total: Math.round($.sum(books, "price") * 100) / 100,
          name: $.get(input, "store.book[1].title"),
          flat: $.flattenObject({ a: { b: [1, { c: 2 }] } }),
          uniq: $.uniq([1, 1, 2]),
          omitted: $.omit(books[0], "tags", "price"),
        }
        """)
        expectNil(outcome.error, outcome.error?.message ?? "")
        expectEqual(outcome.output?["tags"], ["x", "y", "z"])
        expectEqual(outcome.output?["picked"], [["title": "A"], ["title": "B"], ["title": "C"]])
        expectEqual(outcome.output?["groups"], ["cheap", "pricey"])
        expectEqual(outcome.output?["sorted"], ["C", "B", "A"])
        expectEqual(outcome.output?["total"], 44.93)
        expectEqual(outcome.output?["name"], "B")
        expectEqual(outcome.output?["flat"], ["a.b.0": 1, "a.b.1.c": 2])
        expectEqual(outcome.output?["uniq"], [1, 2])
        expectEqual(outcome.output?["omitted"], ["title": "A"])
    }

    check("helpers: jsonPath bridges to the native engine") {
        let outcome = run("$.jsonPath(input, '$.store.book[?(@.price < 10)].title')")
        expectNil(outcome.error, outcome.error?.message ?? "")
        expectEqual(outcome.output, ["A"])
        let bad = run("$.jsonPath(input, '$[')")
        expect(bad.error?.message.contains("Invalid JSONPath") == true, "\(bad.error?.message ?? "nil")")
    }

    check("context: $.document, $.schema and previous steps") {
        var context = ScriptContext(input: [1, 2], document: sample, schema: ["type": "object"])
        context.previousOutputs = ["first", nil]
        context.previousNames = ["one", "two"]
        let outcome = ScriptEngine.run(javaScript: "[$.document.store.name, $.schema.type, $.step('one'), $.step(-1), $.steps.length, input.length]", context: context)
        expectNil(outcome.error, outcome.error?.message ?? "")
        expectEqual(outcome.output, ["Jayson Books", "object", "first", nil, 2, 2])
        let noSchema = run("$.schema")
        expectEqual(noSchema.output, .null)
    }

    check("resolved promises are unwrapped") {
        let outcome = run("Promise.resolve(input.store.name)")
        expectNil(outcome.error, outcome.error?.message ?? "")
        expectEqual(outcome.output, "Jayson Books")
        let rejected = run("Promise.reject(new Error('nope'))")
        expectEqual(rejected.error?.message, "nope")
    }

    check("non-JSON results are rejected") {
        let outcome = run("() => 1")
        expect(outcome.error?.message.contains("JSON") == true, "\(outcome.error?.message ?? "nil")")
        let big = run("BigInt(1)")
        expect(big.error != nil)
    }

    check("scripts are isolated from each other") {
        _ = run("globalThis.leak = 42; return 1")
        let outcome = run("typeof globalThis.leak")
        expectEqual(outcome.output, "undefined")
    }
}

func runSchemaTypeScriptChecks() {
    check("object schema with required, optional, nullable and enum") {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "id": ["type": "integer"],
                "name": ["type": "string"],
                "nick-name": ["type": ["string", "null"]],
                "role": ["enum": ["admin", "user", 1, nil]],
                "tags": ["type": "array", "items": ["type": "string"]],
                "mixed": ["type": "array", "items": ["anyOf": [["type": "string"], ["type": "number"]]]],
                "meta": ["type": "object", "additionalProperties": ["type": "boolean"]],
                "anything": true,
                "nothing": false,
            ],
            "required": ["id", "name"],
        ]
        let text = SchemaTypeScript.declarations(for: schema)
        let expected = """
        type Input = {
          id: number;
          name: string;
          "nick-name"?: string | null;
          role?: "admin" | "user" | 1 | null;
          tags?: string[];
          mixed?: (string | number)[];
          meta?: Record<string, boolean>;
          anything?: unknown;
          nothing?: never;
        };

        """
        expectEqual(text, expected)
    }

    check("$defs become aliases and $ref resolves to them") {
        let schema: JSONValue = [
            "$defs": [
                "book": ["type": "object", "properties": ["title": ["type": "string"]], "required": ["title"], "additionalProperties": false],
                "2-bad name": ["type": "string"],
            ],
            "type": "object",
            "properties": [
                "books": ["type": "array", "items": ["$ref": "#/$defs/book"]],
                "label": ["$ref": "#/$defs/2-bad name"],
                "self": ["$ref": "#"],
                "unknownRef": ["$ref": "https://example.com/x"],
            ],
            "additionalProperties": true,
        ]
        let text = SchemaTypeScript.declarations(for: schema)
        expect(text.contains("books?: Book[];"), text)
        expect(text.contains("label?: _2BadName;"), text)
        expect(text.contains("self?: Input;"), text)
        expect(text.contains("unknownRef?: unknown;"), text)
        expect(text.contains("[key: string]: unknown;"), text)
        expect(text.contains("\ntype Book = {\n  title: string;\n};\n"), text)
        expect(text.contains("\ntype _2BadName = string;\n"), text)
    }

    check("tuples, intersections, const and empty objects") {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "pair": ["prefixItems": [["type": "string"], ["type": "number"]], "items": false],
                "rest": ["prefixItems": [["type": "string"]], "items": ["type": "boolean"]],
                "both": ["allOf": [["type": "object", "properties": ["a": ["type": "string"]]], ["type": "object", "properties": ["b": ["type": "number"]]]]],
                "fixed": ["const": "yes"],
                "empty": ["type": "object"],
                "closed": ["type": "object", "additionalProperties": false],
                "untyped": [:],
            ],
        ]
        let text = SchemaTypeScript.declarations(for: schema)
        expect(text.contains("pair?: [string, number];"), text)
        expect(text.contains("rest?: [string, ...boolean[]];"), text)
        expect(text.contains("both?: {\n    a?: string;\n  } & {\n    b?: number;\n  };"), text)
        expect(text.contains("fixed?: \"yes\";"), text)
        expect(text.contains("empty?: Record<string, unknown>;"), text)
        expect(text.contains("closed?: Record<string, never>;"), text)
        expect(text.contains("untyped?: unknown;"), text)
    }

    check("inferred declarations follow the value's shape") {
        let text = SchemaTypeScript.declarations(inferredFrom: sample)
        expect(text.hasPrefix("type Input = {\n  store: {\n    name: string;\n    book: {\n      title: string;\n      price: number;\n      tags: string[];\n    }[];\n  };\n};"), text)
    }
}

func runPipelineRunnerChecks() {
    let library = Pipeline(name: "Titles", steps: [
        PipelineStep(kind: .jsonPath(expression: "$.store.book[*].title", firstMatchOnly: false)),
    ])
    let runner = PipelineRunner(resolvePipeline: { id in id == library.id ? library : nil })

    check("steps chain, each result keeps its input and output") {
        let pipeline = Pipeline(name: "P", steps: [
            PipelineStep(name: "books", kind: .jsonPath(expression: "$.store.book[*]", firstMatchOnly: false)),
            PipelineStep(kind: .script(language: .javascript, code: "input.map(b => b.tags)")),
            PipelineStep(kind: .flatten(depth: nil)),
            PipelineStep(kind: .script(language: .javascript, code: "({ tags: input, books: $.step('books').length })")),
        ])
        let result = awaitValue { await runner.run(pipeline, input: sample) }
        expect(result.isSuccess, result.failure?.error ?? "")
        expectEqual(result.output, ["tags": ["x", "y", "z"], "books": 3])
        expectEqual(result.steps.count, 4)
        expectEqual(result.steps[1].input, result.steps[0].output)
        expectEqual(result.steps[2].output, ["x", "y", "z"])
    }

    check("first-match JSONPath, flatten depth and flatten type error") {
        let first = Pipeline(name: "F", steps: [PipelineStep(kind: .jsonPath(expression: "$.store.name", firstMatchOnly: true))])
        expectEqual(awaitValue { await runner.run(first, input: sample) }.output, "Jayson Books")
        let none = Pipeline(name: "N", steps: [PipelineStep(kind: .jsonPath(expression: "$.missing", firstMatchOnly: true))])
        expectEqual(awaitValue { await runner.run(none, input: sample) }.output, .null)
        let depth = Pipeline(name: "D", steps: [PipelineStep(kind: .flatten(depth: 1))])
        expectEqual(awaitValue { await runner.run(depth, input: [[1, [2, [3]]], 4]) }.output, [1, [2, [3]], 4])
        let deep = Pipeline(name: "D", steps: [PipelineStep(kind: .flatten(depth: nil))])
        expectEqual(awaitValue { await runner.run(deep, input: [[1, [2, [3]]], 4]) }.output, [1, 2, 3, 4])
        let wrong = awaitValue { await runner.run(deep, input: ["a": 1]) }
        expect(wrong.failure?.error?.contains("expects an array") == true, wrong.failure?.error ?? "")
    }

    check("a failing step stops the run; later steps are skipped") {
        let pipeline = Pipeline(name: "P", steps: [
            PipelineStep(kind: .script(language: .javascript, code: "input.store.book")),
            PipelineStep(kind: .script(language: .javascript, code: "throw new Error('stop')")),
            PipelineStep(kind: .flatten(depth: nil)),
        ])
        let result = awaitValue { await runner.run(pipeline, input: sample) }
        expect(!result.isSuccess)
        expectEqual(result.failedStepID, pipeline.steps[1].id)
        expectEqual(result.failure?.error, "stop")
        expectEqual(result.failure?.errorLine, 1)
        expect(result.steps[2].wasSkipped)
        expectNil(result.steps[2].output)
        expectNil(result.output)
    }

    check("disabled steps pass their input through") {
        let pipeline = Pipeline(name: "P", steps: [
            PipelineStep(isEnabled: false, kind: .script(language: .javascript, code: "throw new Error('never')")),
            PipelineStep(kind: .script(language: .javascript, code: "input.store.name")),
        ])
        let result = awaitValue { await runner.run(pipeline, input: sample) }
        expect(result.isSuccess)
        expect(result.steps[0].wasSkipped)
        expectEqual(result.steps[0].output, sample)
        expectEqual(result.output, "Jayson Books")
    }

    check("nested pipelines run from the library; missing and recursive ones fail cleanly") {
        let pipeline = Pipeline(name: "P", steps: [
            PipelineStep(kind: .pipeline(id: library.id)),
            PipelineStep(kind: .script(language: .javascript, code: "input.join(',')")),
        ])
        let result = awaitValue { await runner.run(pipeline, input: sample) }
        expect(result.isSuccess, result.failure?.error ?? "")
        expectEqual(result.output, "A,B,C")

        let missing = Pipeline(name: "M", steps: [PipelineStep(kind: .pipeline(id: UUID()))])
        expect(awaitValue { await runner.run(missing, input: sample) }.failure?.error?.contains("no longer exists") == true)

        let loopID = UUID()
        let selfReferential = Pipeline(id: loopID, name: "Loop", steps: [PipelineStep(kind: .pipeline(id: loopID))])
        let loopRunner = PipelineRunner(resolvePipeline: { [selfReferential] id in id == selfReferential.id ? selfReferential : nil })
        let loop = awaitValue { await loopRunner.run(selfReferential, input: sample) }
        expect(loop.failure?.error?.contains("recursively") == true, loop.failure?.error ?? "")
    }

    check("the schema is visible only while the input is still the document") {
        let pipeline = Pipeline(name: "P", steps: [
            PipelineStep(kind: .script(language: .javascript, code: "$.schema.title")),
            PipelineStep(kind: .script(language: .javascript, code: "[input, $.schema]")),
        ])
        let result = awaitValue { await runner.run(pipeline, input: sample, schema: ["title": "S"]) }
        expectEqual(result.output, ["S", nil])
    }

    check("declarations pick the schema for the document and inference otherwise") {
        let fromSchema = PipelineRunner.declarations(input: sample, schema: ["type": "string"])
        expect(fromSchema.hasPrefix("type Input = string;\n"), fromSchema)
        expect(fromSchema.contains("declare const $: JaysonHelpers;"))
        let inferred = PipelineRunner.declarations(input: ["a": 1], schema: nil)
        expect(inferred.hasPrefix("type Input = {\n  a: number;\n};\n"), inferred)
        expect(PipelineRunner.declarations(input: nil, schema: nil).hasPrefix("type Input = unknown;"))
    }
}

func runHTTPStepChecks() {
    check("placeholders expand from the input") {
        let input: JSONValue = ["user": ["id": 42, "name": "Ada Lovelace", "tags": ["a", "b"]], "flag": true]
        expectEqual(HTTPRequestStep.expand("https://x/{{ user.id }}/{{input.user.name}}?t={{ $.user.tags[1] }}", input: input), "https://x/42/Ada Lovelace?t=b")
        expectEqual(HTTPRequestStep.expand("{{ user.tags }}|{{ flag }}|{{ missing.path }}|{{ unclosed", input: input), "[\"a\",\"b\"]|true||{{ unclosed")
        expectEqual(HTTPRequestStep.expand("plain", input: input), "plain")
    }

    check("GET a data: URL and parse the JSON body") {
        var request = HTTPRequestStep()
        request.url = "data:application/json,{\"hello\":\"{{ name }}\"}"
        let pipeline = Pipeline(name: "H", steps: [PipelineStep(kind: .httpRequest(request))])
        let result = awaitValue { await PipelineRunner().run(pipeline, input: ["name": "world"]) }
        expect(result.isSuccess, result.failure?.error ?? "")
        expectEqual(result.output, ["hello": "world"])
        expect(result.steps[0].logs.first?.hasPrefix("GET data:") == true, result.steps[0].logs.description)
    }

    check("full output mode wraps status, headers and body; text bodies stay strings") {
        var request = HTTPRequestStep()
        request.url = "data:text/plain,not%20json"
        request.outputMode = .full
        let pipeline = Pipeline(name: "H", steps: [PipelineStep(kind: .httpRequest(request))])
        let result = awaitValue { await PipelineRunner().run(pipeline, input: .null) }
        expect(result.isSuccess, result.failure?.error ?? "")
        expectEqual(result.output?["body"], "not json")
        expectEqual(result.output?["status"], 200)
        expect(result.output?["headers"]?.objectValue != nil)
    }

    check("invalid and empty URLs fail with a message") {
        var request = HTTPRequestStep()
        let empty = Pipeline(name: "H", steps: [PipelineStep(kind: .httpRequest(request))])
        expect(awaitValue { await PipelineRunner().run(empty, input: .null) }.failure?.error?.contains("Enter a URL") == true)
        request.url = "not a url"
        let bad = Pipeline(name: "H", steps: [PipelineStep(kind: .httpRequest(request))])
        expect(awaitValue { await PipelineRunner().run(bad, input: .null) }.failure?.error?.contains("not a valid URL") == true)
    }

    check("cached-only runs defer the request; an allowed run fills the cache for later") {
        var request = HTTPRequestStep()
        request.url = "data:application/json,[1,2,3]"
        let pipeline = Pipeline(name: "H", steps: [
            PipelineStep(kind: .httpRequest(request)),
            PipelineStep(kind: .script(language: .javascript, code: "input.length")),
        ])
        let cache = HTTPResponseCache()
        var live = PipelineRunner()
        live.networkPolicy = .cachedOnly
        live.httpCache = cache
        let deferred = awaitValue { [live] in await live.run(pipeline, input: .null) }
        expect(deferred.isDeferred, "should be deferred")
        expect(deferred.failure?.error?.contains("Press Run") == true)
        expect(deferred.steps[1].wasSkipped)

        var explicit = PipelineRunner()
        explicit.httpCache = cache
        let sent = awaitValue { [explicit] in await explicit.run(pipeline, input: .null) }
        expect(sent.isSuccess, sent.failure?.error ?? "")
        expectEqual(sent.output, 3)

        let replay = awaitValue { [live] in await live.run(pipeline, input: .null) }
        expect(replay.isSuccess, replay.failure?.error ?? "")
        expectEqual(replay.output, 3)
        expect(replay.steps[0].logs.first?.contains("Reused") == true)
    }
}

func runTypeScriptChecks() {
    let service = TypeScriptService.shared
    guard service.isAvailable else {
        print("  – skipped: TypeScript compiler not installed (run Scripts/fetch-typescript.sh)")
        return
    }

    check("transpiles TypeScript and strips types") {
        let js = try awaitValue { try? await service.transpile("const n: number = (input as any).x;\nreturn n * 2") }
        expect(js?.contains(": number") == false, js ?? "nil")
        expect(js?.contains("n * 2") == true, js ?? "nil")
    }

    check("syntax errors surface with their line") {
        let error = awaitValue { () -> TypeScriptError? in
            do { _ = try await service.transpile("const a = 1;\nconst b: = 2;") } catch let e as TypeScriptError { return e } catch { return nil }
            return nil
        }
        guard case .syntax(let diagnostics)? = error, let first = diagnostics.first else { fail("expected a syntax error, got \(String(describing: error))"); return }
        expectEqual(first.line, 2)
    }

    check("TypeScript steps run end to end with typed input") {
        let runner = PipelineRunner()
        let pipeline = Pipeline(name: "TS", steps: [
            PipelineStep(kind: .script(language: .typescript, code: """
            type Book = { title: string; price: number };
            const books = (input as { store: { book: Book[] } }).store.book;
            return books.filter((b: Book) => b.price < 10).map(b => b.title);
            """)),
        ])
        let result = awaitValue { await runner.run(pipeline, input: sample) }
        expect(result.isSuccess, result.failure?.error ?? "")
        expectEqual(result.output, ["A"])
    }

    check("type errors are reported against the schema-derived Input type") {
        let declarations = PipelineRunner.declarations(input: sample, schema: nil)
        let good = try awaitValue { try? await service.check("return input.store.book.map(b => b.title.toUpperCase())", declarations: declarations, asExpression: false) }
        expectEqual(good?.filter { $0.category == .error }.count, 0, "\(good ?? [])")

        let bad = try awaitValue { try? await service.check("const x = 1;\nreturn input.store.book.map(b => b.titel)", declarations: declarations, asExpression: false) }
        let errors = bad?.filter { $0.category == .error } ?? []
        expectEqual(errors.count, 1, "\(errors)")
        expectEqual(errors.first?.line, 2)
        expect(errors.first?.message.contains("titel") == true, errors.first?.message ?? "")

        let expression = try awaitValue { try? await service.check("input.store.name.length", declarations: declarations, asExpression: true) }
        expectEqual(expression?.filter { $0.category == .error }.count, 0, "\(expression ?? [])")
        let helpers = try awaitValue { try? await service.check("$.sum(input.store.book, 'price') + console.log('x')", declarations: declarations, asExpression: true) }
        expect(helpers?.contains { $0.category == .error } == true, "void in arithmetic should be an error")
    }

    check("expression detection matches the engine after transpiling") {
        expectEqual(try awaitValue { try? await service.isExpression("input.store.name as string") }, true)
        expectEqual(try awaitValue { try? await service.isExpression("const a: number = 1;\nreturn a") }, false)
    }
}
