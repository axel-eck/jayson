import Foundation
import JavaScriptCore

// MARK: - Types

public struct TypeScriptDiagnostic: Hashable, Sendable, Identifiable {
    public enum Category: String, Sendable { case error, warning, suggestion, message }

    public var id: String { "\(line):\(column):\(code):\(message)" }
    public var message: String
    public var code: Int
    public var category: Category
    /// 1-based position inside the user's code.
    public var line: Int
    public var column: Int
}

public struct TypeScriptTranspileResult: Sendable {
    public var javaScript: String
    /// Syntax errors. The output is still usable when this is empty.
    public var diagnostics: [TypeScriptDiagnostic]
}

public enum TypeScriptError: Error, LocalizedError, Sendable {
    case compilerUnavailable
    case syntax([TypeScriptDiagnostic])
    case internalFailure(String)

    public var errorDescription: String? {
        switch self {
        case .compilerUnavailable:
            return "The TypeScript compiler is not installed. Run `make typescript` (or Scripts/fetch-typescript.sh) and relaunch, or switch the step to JavaScript."
        case .syntax(let diagnostics):
            return diagnostics.map { "Line \($0.line): \($0.message)" }.joined(separator: "\n")
        case .internalFailure(let message):
            return message
        }
    }
}

// MARK: - Service

/// Hosts the TypeScript compiler (typescript.js) in its own JavaScriptCore context.
///
/// Loading the compiler costs about a second, so one instance is shared and kept warm. The
/// compiler and the ES2020 lib declarations are looked up in `Resources/TypeScript`, which
/// `Scripts/fetch-typescript.sh` populates; they are not committed to the repository.
public actor TypeScriptService {
    public static let shared = TypeScriptService()

    private var context: JSContext?
    private var libCache: [String: String] = [:]
    private var loadFailure: String?
    private let resourcesURL: URL?

    public init(resourcesURL: URL? = TypeScriptService.locateResources()) {
        self.resourcesURL = resourcesURL
    }

    /// True when the compiler files are present (loading happens lazily on first use).
    public nonisolated var isAvailable: Bool {
        guard let resourcesURL else { return false }
        return FileManager.default.fileExists(atPath: resourcesURL.appendingPathComponent("typescript.js").path)
    }

    /// Version string written by the fetch script, if any.
    public nonisolated var version: String? {
        guard let resourcesURL, let text = try? String(contentsOf: resourcesURL.appendingPathComponent("VERSION"), encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where the compiler lives: `JAYSON_TYPESCRIPT_DIR`, the app bundle, Application Support,
    /// or the repository's `Resources/TypeScript` for development runs.
    public nonisolated static func locateResources() -> URL? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["JAYSON_TYPESCRIPT_DIR"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("TypeScript") {
            candidates.append(bundled)
        }
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(support.appendingPathComponent("Jayson/TypeScript"))
        }
        // Sources/JaysonCore/TypeScriptService.swift → <repo>/Resources/TypeScript
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(repo.appendingPathComponent("Resources/TypeScript"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("typescript.js").path) }
    }

    // MARK: Public API

    /// Transpiles TypeScript to ES2020 JavaScript. Throws on syntax errors.
    public func transpile(_ source: String) throws -> String {
        let js = try loadedContext()
        js.setObject(source, forKeyedSubscript: "__jayson_source" as NSString)
        guard let result = js.evaluateScript("JSON.stringify(__jaysonTS.transpile(__jayson_source))"), result.isString,
              let text = result.toString(), let data = text.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(TranspilePayload.self, from: data) else {
            throw TypeScriptError.internalFailure("The TypeScript compiler returned an unexpected result")
        }
        let errors = parsed.diagnostics.map { $0.diagnostic(lineOffset: 0) }.filter { $0.category == .error }
        if !errors.isEmpty { throw TypeScriptError.syntax(errors) }
        // TypeScript terminates a bare expression with `;`, which would turn it into a
        // statement body that returns nothing. Drop it when the remainder is an expression.
        let trimmed = parsed.js.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(";") {
            let candidate = String(trimmed.dropLast())
            if ScriptEngine.isExpression(candidate, in: js) { return candidate }
        }
        return parsed.js
    }

    /// Type-checks `source` against `declarations` (the `Input`, `$` and `console` types).
    /// `asExpression` mirrors how the engine will run the code, so `return` is only allowed
    /// in the function-body form.
    public func check(_ source: String, declarations: String, asExpression: Bool) throws -> [TypeScriptDiagnostic] {
        let js = try loadedContext()
        js.setObject(source, forKeyedSubscript: "__jayson_source" as NSString)
        js.setObject(declarations, forKeyedSubscript: "__jayson_declarations" as NSString)
        js.setObject(asExpression, forKeyedSubscript: "__jayson_asExpression" as NSString)
        guard let result = js.evaluateScript("JSON.stringify(__jaysonTS.check(__jayson_source, __jayson_declarations, __jayson_asExpression))"),
              result.isString, let text = result.toString(), let data = text.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(CheckPayload.self, from: data) else {
            throw TypeScriptError.internalFailure("The TypeScript checker returned an unexpected result")
        }
        return parsed.diagnostics.map { $0.diagnostic(lineOffset: parsed.preludeLines) }
    }

    /// Whether `source` (after transpiling) is a single expression, matching `ScriptEngine`.
    public func isExpression(_ source: String) throws -> Bool {
        let javaScript = try transpile(source)
        let js = try loadedContext()
        return ScriptEngine.isExpression(javaScript, in: js)
    }

    // MARK: Loading

    private func loadedContext() throws -> JSContext {
        if let context { return context }
        if let loadFailure { throw TypeScriptError.internalFailure(loadFailure) }
        guard isAvailable, let resourcesURL else { throw TypeScriptError.compilerUnavailable }
        guard let js = JSContext() else { throw TypeScriptError.internalFailure("Could not create a JavaScript context") }
        js.name = "TypeScript compiler"
        var failure: String?
        js.exceptionHandler = { _, exception in failure = exception?.toString() }

        let compilerURL = resourcesURL.appendingPathComponent("typescript.js")
        guard let compiler = try? String(contentsOf: compilerURL, encoding: .utf8) else {
            throw TypeScriptError.compilerUnavailable
        }
        js.evaluateScript(compiler, withSourceURL: compilerURL)
        if let failure {
            loadFailure = "Could not load typescript.js: \(failure)"
            throw TypeScriptError.internalFailure(loadFailure!)
        }
        guard let ts = js.objectForKeyedSubscript("ts"), ts.isObject else {
            loadFailure = "typescript.js did not define `ts`"
            throw TypeScriptError.internalFailure(loadFailure!)
        }

        let readLib: @convention(block) (String) -> JSValue = { [resourcesURL] name in
            let safe = URL(fileURLWithPath: name).lastPathComponent
            guard safe.hasPrefix("lib."), safe.hasSuffix(".d.ts"),
                  let text = try? String(contentsOf: resourcesURL.appendingPathComponent(safe), encoding: .utf8) else {
                return JSValue(nullIn: js)
            }
            return JSValue(object: text, in: js)
        }
        js.setObject(readLib, forKeyedSubscript: "__jayson_readLib" as NSString)
        js.evaluateScript(Self.harness, withSourceURL: URL(string: "jayson://ts-harness"))
        if let failure {
            loadFailure = "Could not initialise the TypeScript harness: \(failure)"
            throw TypeScriptError.internalFailure(loadFailure!)
        }
        context = js
        return js
    }

    // MARK: Payloads

    private struct DiagnosticPayload: Decodable {
        var message: String
        var code: Int
        var category: String
        var line: Int
        var column: Int

        func diagnostic(lineOffset: Int) -> TypeScriptDiagnostic {
            TypeScriptDiagnostic(
                message: message,
                code: code,
                category: TypeScriptDiagnostic.Category(rawValue: category) ?? .error,
                line: max(line - lineOffset, 1),
                column: max(column, 1)
            )
        }
    }

    private struct TranspilePayload: Decodable {
        var js: String
        var diagnostics: [DiagnosticPayload]
    }

    private struct CheckPayload: Decodable {
        var preludeLines: Int
        var diagnostics: [DiagnosticPayload]
    }

    /// JS side: a virtual compiler host over the bundled lib files, with lib source files
    /// cached across checks and the previous program reused for incremental re-checking.
    static let harness = """
    var __jaysonTS = (function () {
      var libTexts = new Map();
      var libFiles = new Map();
      var oldProgram = undefined;
      var LIB_DIR = "/lib/";
      var STEP = "/step.ts";

      function libName(fileName) { return fileName.slice(fileName.lastIndexOf("/") + 1); }
      function libText(fileName) {
        var name = libName(fileName);
        if (!libTexts.has(name)) libTexts.set(name, __jayson_readLib(name));
        return libTexts.get(name);
      }
      function categoryName(c) {
        switch (c) {
          case ts.DiagnosticCategory.Warning: return "warning";
          case ts.DiagnosticCategory.Suggestion: return "suggestion";
          case ts.DiagnosticCategory.Message: return "message";
          default: return "error";
        }
      }
      function describe(d) {
        var line = 1, column = 1;
        if (d.file && typeof d.start === "number") {
          var pos = d.file.getLineAndCharacterOfPosition(d.start);
          line = pos.line + 1; column = pos.character + 1;
        }
        return { message: ts.flattenDiagnosticMessageText(d.messageText, "\\n"), code: d.code, category: categoryName(d.category), line: line, column: column };
      }

      var compilerOptions = {
        target: ts.ScriptTarget.ES2020,
        module: ts.ModuleKind.None,
        lib: ["lib.es2020.d.ts"],
        strict: true,
        noImplicitAny: false,
        noEmit: true,
        skipLibCheck: true,
        types: [],
        allowUnreachableCode: true,
        noImplicitReturns: false,
      };

      function check(source, declarations, asExpression) {
        var prelude = declarations.replace(/\\s+$/, "") + "\\n";
        var wrapped = asExpression
          ? prelude + "const __jayson_output = (\\n" + source + "\\n);\\n"
          : prelude + "function __jayson_step(): unknown {\\n" + source + "\\n}\\n";
        var preludeLines = prelude.split("\\n").length;  // user code starts on line preludeLines + 1
        var files = {};
        files[STEP] = wrapped;
        var host = {
          getSourceFile: function (fileName, languageVersion) {
            if (files[fileName] !== undefined) return ts.createSourceFile(fileName, files[fileName], languageVersion, true);
            if (libFiles.has(fileName)) return libFiles.get(fileName);
            var text = libText(fileName);
            if (text === null || text === undefined) return undefined;
            var sf = ts.createSourceFile(fileName, text, languageVersion, true);
            libFiles.set(fileName, sf);
            return sf;
          },
          getDefaultLibFileName: function () { return LIB_DIR + "lib.es2020.d.ts"; },
          getDefaultLibLocation: function () { return LIB_DIR; },
          writeFile: function () {},
          getCurrentDirectory: function () { return "/"; },
          getCanonicalFileName: function (f) { return f; },
          useCaseSensitiveFileNames: function () { return true; },
          getNewLine: function () { return "\\n"; },
          fileExists: function (f) { return files[f] !== undefined || (f.indexOf(LIB_DIR) === 0 && libText(f) != null); },
          readFile: function (f) { return files[f] !== undefined ? files[f] : libText(f); },
          directoryExists: function () { return true; },
          getDirectories: function () { return []; },
        };
        var program = ts.createProgram([STEP], compilerOptions, host, oldProgram);
        oldProgram = program;
        var diagnostics = ts.getPreEmitDiagnostics(program).filter(function (d) { return !d.file || d.file.fileName === STEP; });
        return { preludeLines: preludeLines, diagnostics: diagnostics.map(describe) };
      }

      function transpile(source) {
        var result = ts.transpileModule(source, {
          compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ESNext, removeComments: false },
          reportDiagnostics: true,
          fileName: "step.ts",
        });
        return { js: result.outputText, diagnostics: (result.diagnostics || []).map(describe) };
      }

      return { check: check, transpile: transpile };
    })();
    """
}
