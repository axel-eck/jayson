import Foundation
import JavaScriptCore

// MARK: - Types

/// A script failure with the line/column inside the user's code when JavaScriptCore reports one.
public struct ScriptError: Error, LocalizedError, Hashable, Sendable {
    public var message: String
    public var line: Int?
    public var column: Int?

    public init(message: String, line: Int? = nil, column: Int? = nil) {
        self.message = message
        self.line = line
        self.column = column
    }

    public var errorDescription: String? {
        if let line { return "Line \(line): \(message)" }
        return message
    }
}

public struct ScriptRunOutcome: Sendable {
    public var output: JSONValue?
    public var error: ScriptError?
    public var logs: [String]
    public var duration: TimeInterval
    /// Variables the script assigned with `$.setVar(name, value)`.
    public var variableUpdates: [String: JSONValue] = [:]
}

/// Everything a script can see besides its `input`.
public struct ScriptContext: Sendable {
    public var input: JSONValue
    /// The pipeline's original input (the document), available as `$.document`.
    public var document: JSONValue
    /// The schema loaded for the document, available as `$.schema` (null when none).
    public var schema: JSONValue?
    /// Outputs of the previous steps, available as `$.steps[i]` and `$.step("name")`.
    public var previousOutputs: [JSONValue?] = []
    public var previousNames: [String] = []
    /// Variables of the run, available as `$.vars`.
    public var variables: [String: JSONValue] = [:]
    /// The current For Each iteration, available as `$.loop` (null outside a loop).
    public var loop: TemplateContext.LoopInfo?

    public init(input: JSONValue, document: JSONValue? = nil, schema: JSONValue? = nil) {
        self.input = input
        self.document = document ?? input
        self.schema = schema
    }
}

// MARK: - Engine

/// Runs one JavaScript step in a fresh JavaScriptCore context with a wall-clock limit.
///
/// The code is treated as a function body: `input` and `$` are parameters and the returned
/// value is the output. When the whole text parses as a single expression, its value is
/// returned instead, so `input.items.length` works without `return`.
public enum ScriptEngine {
    public static let defaultTimeout: TimeInterval = 5

    public static func run(javaScript code: String, context: ScriptContext, timeout: TimeInterval = defaultTimeout) -> ScriptRunOutcome {
        let start = Date()
        var logs: [String] = []
        guard let js = JSContext() else {
            return ScriptRunOutcome(output: nil, error: ScriptError(message: "Could not create a JavaScript context"), logs: [], duration: 0)
        }
        js.name = "Jayson pipeline step"
        installTimeLimit(js, seconds: timeout)

        let sink = ExceptionSink()
        js.exceptionHandler = { _, exception in sink.value = exception }

        // Native bridges. Values cross the boundary as JSON text so key order survives.
        let log: @convention(block) (String, String) -> Void = { level, message in
            logs.append(level == "log" ? message : "[\(level)] \(message)")
        }
        js.setObject(log, forKeyedSubscript: "__jayson_log" as NSString)

        weak var weakContext = js
        let jsonPath: @convention(block) (String, String) -> String = { valueText, expression in
            do {
                let value = try JSONParser.parse(valueText)
                let matches = try JSONPathQuery.evaluate(expression, on: value)
                return JSONFormatter.minify(.array(matches.map(\.value)))
            } catch let error as JSONPathError {
                weakContext?.exception = JSValue(newErrorFromMessage: "Invalid JSONPath: \(error.message)", in: weakContext)
                return "null"
            } catch {
                weakContext?.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: weakContext)
                return "null"
            }
        }
        js.setObject(jsonPath, forKeyedSubscript: "__jayson_jsonPath" as NSString)

        js.setObject(JSONFormatter.minify(context.input), forKeyedSubscript: "__jayson_inputText" as NSString)
        js.setObject(JSONFormatter.minify(context.document), forKeyedSubscript: "__jayson_documentText" as NSString)
        js.setObject(JSONFormatter.minify(context.schema ?? .null), forKeyedSubscript: "__jayson_schemaText" as NSString)
        js.setObject(JSONFormatter.minify(.array(context.previousOutputs.map { $0 ?? .null })), forKeyedSubscript: "__jayson_stepsText" as NSString)
        js.setObject(JSONFormatter.minify(.array(context.previousNames.map { .string($0) })), forKeyedSubscript: "__jayson_stepNamesText" as NSString)
        let variables = JSONObject(context.variables.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
        js.setObject(JSONFormatter.minify(.object(variables)), forKeyedSubscript: "__jayson_varsText" as NSString)
        js.setObject(JSONFormatter.minify(context.loop?.jsonValue ?? .null), forKeyedSubscript: "__jayson_loopText" as NSString)

        js.evaluateScript(prelude, withSourceURL: URL(string: "jayson://prelude"))
        if let exception = sink.value {
            return ScriptRunOutcome(output: nil, error: ScriptError(message: "Internal error in helper prelude: \(exception)"), logs: logs, duration: Date().timeIntervalSince(start))
        }

        // Compile the user code, preferring the expression form.
        let compiled = compile(code, in: js, sink: sink)
        guard let function = compiled.function else {
            return ScriptRunOutcome(output: nil, error: compiled.error ?? ScriptError(message: "Could not compile the script"), logs: logs, duration: Date().timeIntervalSince(start))
        }

        let input = js.evaluateScript("JSON.parse(__jayson_inputText)") ?? JSValue(undefinedIn: js)!
        let helpers = js.objectForKeyedSubscript("$") ?? JSValue(undefinedIn: js)!
        sink.value = nil
        var result = function.call(withArguments: [input, helpers])
        if let exception = sink.value {
            return ScriptRunOutcome(output: nil, error: scriptError(from: exception, in: js, lineOffset: compiled.lineOffset), logs: logs, duration: Date().timeIntervalSince(start))
        }

        // Promises: let the microtask queue drain once, then read the settled value.
        if let value = result, value.isObject, value.hasProperty("then"), value.forProperty("then").isObject {
            js.setObject(value, forKeyedSubscript: "__jayson_pending" as NSString)
            js.evaluateScript("""
            var __jayson_settled = undefined, __jayson_rejected = undefined, __jayson_done = false;
            __jayson_pending.then(function (v) { __jayson_settled = v; __jayson_done = true; }, function (e) { __jayson_rejected = e; __jayson_done = true; });
            """)
            js.evaluateScript("0")
            if js.evaluateScript("__jayson_done").toBool() == false {
                return ScriptRunOutcome(output: nil, error: ScriptError(message: "The script returned a promise that never settled. Only synchronous work is available in a step."), logs: logs, duration: Date().timeIntervalSince(start))
            }
            if let rejection = js.evaluateScript("__jayson_rejected"), !rejection.isUndefined {
                return ScriptRunOutcome(output: nil, error: scriptError(from: rejection, in: js, lineOffset: compiled.lineOffset), logs: logs, duration: Date().timeIntervalSince(start))
            }
            result = js.evaluateScript("__jayson_settled")
        }

        guard let result, !result.isUndefined else {
            return ScriptRunOutcome(
                output: nil,
                error: ScriptError(message: "The script did not return a value. End with `return …` or write a single expression."),
                logs: logs,
                duration: Date().timeIntervalSince(start)
            )
        }

        js.setObject(result, forKeyedSubscript: "__jayson_result" as NSString)
        sink.value = nil
        let serialized = js.evaluateScript("JSON.stringify(__jayson_result)")
        if let exception = sink.value {
            return ScriptRunOutcome(output: nil, error: ScriptError(message: "The result cannot be converted to JSON: \(exception)"), logs: logs, duration: Date().timeIntervalSince(start))
        }
        guard let text = serialized, text.isString, let string = text.toString() else {
            return ScriptRunOutcome(output: nil, error: ScriptError(message: "The result cannot be converted to JSON (functions and symbols are not JSON)."), logs: logs, duration: Date().timeIntervalSince(start))
        }
        do {
            let value = try JSONParser.parse(string)
            var updates: [String: JSONValue] = [:]
            if let updatesText = js.evaluateScript("JSON.stringify(__jayson_varUpdates)")?.toString(),
               let parsed = try? JSONParser.parse(updatesText), let object = parsed.objectValue {
                for (name, value) in object.members { updates[name] = value }
            }
            return ScriptRunOutcome(output: value, error: nil, logs: logs, duration: Date().timeIntervalSince(start), variableUpdates: updates)
        } catch {
            return ScriptRunOutcome(output: nil, error: ScriptError(message: "The result is not valid JSON: \(error.localizedDescription)"), logs: logs, duration: Date().timeIntervalSince(start))
        }
    }

    // MARK: Compilation

    private struct Compiled {
        var function: JSValue?
        var error: ScriptError?
        /// Number of lines the wrapper adds before the user's first line.
        var lineOffset: Int
    }

    /// True when `code` is a single JavaScript expression (so it can be returned directly).
    static func isExpression(_ code: String, in js: JSContext) -> Bool {
        js.setObject(code, forKeyedSubscript: "__jayson_code" as NSString)
        let probe = js.evaluateScript("""
        (function () {
          try { new Function("input", "$", "return (" + __jayson_code + "\\n)"); return true; } catch (e) { return false; }
        })()
        """)
        return probe?.toBool() ?? false
    }

    /// Reference box so the exception handler can write while callers hold no overlapping access.
    private final class ExceptionSink {
        var value: JSValue?
    }

    private static func compile(_ code: String, in js: JSContext, sink: ExceptionSink) -> Compiled {
        let expression = isExpression(code, in: js)
        let source = expression
            ? "(function (input, $) {\nreturn (\n\(code)\n);\n})"
            : "(function (input, $) {\n\(code)\n})"
        let lineOffset = expression ? 2 : 1
        sink.value = nil
        let function = js.evaluateScript(source, withSourceURL: URL(string: "jayson://step.js"))
        if let exception = sink.value {
            return Compiled(function: nil, error: scriptError(from: exception, in: js, lineOffset: lineOffset), lineOffset: lineOffset)
        }
        guard let function, function.isObject else {
            return Compiled(function: nil, error: ScriptError(message: "Could not compile the script"), lineOffset: lineOffset)
        }
        return Compiled(function: function, error: nil, lineOffset: lineOffset)
    }

    private static func scriptError(from exception: JSValue, in js: JSContext, lineOffset: Int) -> ScriptError {
        var message = exception.toString() ?? "Unknown error"
        if exception.isObject, let name = exception.forProperty("name")?.toString(), let detail = exception.forProperty("message")?.toString(), !detail.isEmpty {
            message = name == "Error" ? detail : "\(name): \(detail)"
        }
        if message == "JavaScript execution terminated." {
            message = "The script took too long and was stopped."
        }
        var line: Int?
        var column: Int?
        if exception.isObject {
            let url = exception.forProperty("sourceURL")?.toString() ?? ""
            let rawLine = exception.forProperty("line")
            if url.hasSuffix("step.js"), let rawLine, rawLine.isNumber {
                line = max(Int(rawLine.toInt32()) - lineOffset, 1)
                if let rawColumn = exception.forProperty("column"), rawColumn.isNumber { column = Int(rawColumn.toInt32()) }
            }
        }
        return ScriptError(message: message, line: line, column: column)
    }

    // MARK: Time limit

    private typealias TerminateCallback = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool

    // JavaScriptCore ships this in a private header, but the symbol is exported and stable
    // (WebKit relies on it). It is the only way to interrupt a runaway script.
    @_silgen_name("JSContextGroupSetExecutionTimeLimit")
    private static func JSContextGroupSetExecutionTimeLimit(_ group: JSContextGroupRef?, _ limit: Double, _ callback: TerminateCallback?, _ context: UnsafeMutableRawPointer?)

    private static func installTimeLimit(_ js: JSContext, seconds: TimeInterval) {
        guard seconds > 0 else { return }
        let group = JSContextGetGroup(js.jsGlobalContextRef)
        let terminate: TerminateCallback = { _, _ in true }
        JSContextGroupSetExecutionTimeLimit(group, seconds, terminate, nil)
    }

    // MARK: Prelude

    /// Helpers available to every script as `$`, plus a `console` that feeds the step log.
    static let prelude = """
    var console = (function () {
      function fmt(args) {
        return Array.prototype.map.call(args, function (a) {
          if (typeof a === "string") return a;
          if (a instanceof Error) return String(a);
          try { var s = JSON.stringify(a, null, 2); return s === undefined ? String(a) : s; } catch (e) { return String(a); }
        }).join(" ");
      }
      var c = {};
      ["log", "info", "warn", "error", "debug"].forEach(function (level) {
        c[level] = function () { __jayson_log(level, fmt(arguments)); };
      });
      c.table = c.log; c.dir = c.log;
      return c;
    })();

    var __jayson_varUpdates = {};
    var $ = (function () {
      var document = JSON.parse(__jayson_documentText);
      var schema = JSON.parse(__jayson_schemaText);
      var steps = JSON.parse(__jayson_stepsText);
      var stepNames = JSON.parse(__jayson_stepNamesText);
      var vars = JSON.parse(__jayson_varsText);
      var loop = JSON.parse(__jayson_loopText);

      function fn(keyOrFn) {
        if (typeof keyOrFn === "function") return keyOrFn;
        if (keyOrFn === undefined || keyOrFn === null) return function (x) { return x; };
        return function (x) { return get(x, keyOrFn); };
      }
      function toKeys(keys) {
        return Array.prototype.concat.apply([], Array.prototype.slice.call(keys).map(function (k) { return Array.isArray(k) ? k : [k]; }));
      }
      function get(obj, path, fallback) {
        if (path === undefined || path === null || path === "") return obj;
        var parts = Array.isArray(path) ? path : String(path).replace(/\\[(\\d+)\\]/g, ".$1").split(".").filter(Boolean);
        var cur = obj;
        for (var i = 0; i < parts.length; i++) {
          if (cur === null || cur === undefined) return fallback;
          cur = cur[parts[i]];
        }
        return cur === undefined ? fallback : cur;
      }
      function isPlainObject(v) { return v !== null && typeof v === "object" && !Array.isArray(v); }

      var helpers = {
        document: document,
        schema: schema,
        steps: steps,
        step: function (ref) {
          if (typeof ref === "number") return steps[ref < 0 ? steps.length + ref : ref];
          var i = stepNames.indexOf(ref);
          if (i < 0) throw new Error("No previous step named \\"" + ref + "\\"");
          return steps[i];
        },
        vars: vars,
        setVar: function (name, value) {
          if (typeof name !== "string" || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) {
            throw new Error("Variable names use letters, digits and underscores, starting with a letter: " + JSON.stringify(name));
          }
          var v = value === undefined ? null : JSON.parse(JSON.stringify(value));
          vars[name] = v;
          __jayson_varUpdates[name] = v;
        },
        loop: loop,
        get: get,
        flatten: function (arr, depth) {
          if (!Array.isArray(arr)) return arr;
          return arr.flat(depth === undefined ? 1 : depth);
        },
        flattenDeep: function (arr) { return Array.isArray(arr) ? arr.flat(Infinity) : arr; },
        flattenObject: function (obj, separator) {
          var sep = separator === undefined ? "." : separator;
          var out = {};
          (function walk(value, prefix) {
            if (isPlainObject(value) && Object.keys(value).length) {
              Object.keys(value).forEach(function (k) { walk(value[k], prefix ? prefix + sep + k : k); });
            } else if (Array.isArray(value) && value.length) {
              value.forEach(function (v, i) { walk(v, prefix ? prefix + sep + i : String(i)); });
            } else {
              out[prefix] = value;
            }
          })(obj, "");
          return out;
        },
        pick: function (obj) {
          var keys = toKeys(Array.prototype.slice.call(arguments, 1));
          if (Array.isArray(obj)) return obj.map(function (o) { return helpers.pick.apply(null, [o].concat(keys)); });
          if (!isPlainObject(obj)) return obj;
          var out = {};
          keys.forEach(function (k) { if (k in obj) out[k] = obj[k]; });
          return out;
        },
        omit: function (obj) {
          var keys = toKeys(Array.prototype.slice.call(arguments, 1));
          if (Array.isArray(obj)) return obj.map(function (o) { return helpers.omit.apply(null, [o].concat(keys)); });
          if (!isPlainObject(obj)) return obj;
          var out = {};
          Object.keys(obj).forEach(function (k) { if (keys.indexOf(k) < 0) out[k] = obj[k]; });
          return out;
        },
        rename: function (obj, mapping) {
          if (Array.isArray(obj)) return obj.map(function (o) { return helpers.rename(o, mapping); });
          if (!isPlainObject(obj)) return obj;
          var out = {};
          Object.keys(obj).forEach(function (k) { out[mapping[k] !== undefined ? mapping[k] : k] = obj[k]; });
          return out;
        },
        mapValues: function (obj, f) {
          var out = {};
          Object.keys(obj).forEach(function (k) { out[k] = f(obj[k], k); });
          return out;
        },
        keys: function (obj) { return Object.keys(obj); },
        values: function (obj) { return Object.values(obj); },
        entries: function (obj) { return Object.entries(obj); },
        fromEntries: function (entries) { return Object.fromEntries(entries); },
        groupBy: function (arr, keyOrFn) {
          var f = fn(keyOrFn), out = {};
          arr.forEach(function (item) { var k = String(f(item)); (out[k] = out[k] || []).push(item); });
          return out;
        },
        countBy: function (arr, keyOrFn) {
          var f = fn(keyOrFn), out = {};
          arr.forEach(function (item) { var k = String(f(item)); out[k] = (out[k] || 0) + 1; });
          return out;
        },
        sortBy: function (arr, keyOrFn, direction) {
          var f = fn(keyOrFn), sign = direction === "desc" ? -1 : 1;
          return arr.slice().sort(function (a, b) {
            var x = f(a), y = f(b);
            if (x === y) return 0;
            if (x === undefined || x === null) return 1;
            if (y === undefined || y === null) return -1;
            return (x < y ? -1 : 1) * sign;
          });
        },
        uniq: function (arr) { return Array.from(new Set(arr)); },
        uniqBy: function (arr, keyOrFn) {
          var f = fn(keyOrFn), seen = new Set();
          return arr.filter(function (item) { var k = JSON.stringify(f(item)); if (seen.has(k)) return false; seen.add(k); return true; });
        },
        sum: function (arr, keyOrFn) { var f = fn(keyOrFn); return arr.reduce(function (t, x) { return t + (Number(f(x)) || 0); }, 0); },
        min: function (arr, keyOrFn) { var f = fn(keyOrFn); return arr.length ? Math.min.apply(null, arr.map(f)) : undefined; },
        max: function (arr, keyOrFn) { var f = fn(keyOrFn); return arr.length ? Math.max.apply(null, arr.map(f)) : undefined; },
        compact: function (arr) { return arr.filter(function (x) { return x !== null && x !== undefined; }); },
        chunk: function (arr, size) {
          var out = [];
          for (var i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
          return out;
        },
        jsonPath: function (value, expression) {
          return JSON.parse(__jayson_jsonPath(JSON.stringify(value === undefined ? null : value), expression));
        },
        clone: function (value) { return JSON.parse(JSON.stringify(value)); },
      };
      return helpers;
    })();
    """
}
