import Foundation

// MARK: - Public types

/// A single JSON Schema validation failure, located both in the instance and in the schema.
public struct SchemaValidationError: Hashable, Identifiable, CustomStringConvertible {
    /// Location of the offending value inside the validated instance.
    public let instancePath: ValuePath
    /// JSON pointer (with a leading `#`) to the keyword in the schema that failed, e.g. `#/properties/age/minimum`.
    public let schemaPath: String
    /// The keyword that produced the error, e.g. `minimum`, `required`, `type`, `$ref`.
    public let keyword: String
    /// Short human-readable sentence, e.g. "Expected string, got number".
    public let message: String

    public init(instancePath: ValuePath, schemaPath: String, keyword: String, message: String) {
        self.instancePath = instancePath
        self.schemaPath = schemaPath
        self.keyword = keyword
        self.message = message
    }

    /// Stable identifier, unique per (instance path, schema path, message).
    public var id: String { "\(instancePath.jsonPointer)|\(schemaPath)|\(message)" }

    public var description: String { "\(instancePath.jsonPathString): \(message)" }
}

/// Outcome of validating an instance against a schema.
public struct SchemaValidationResult: Equatable {
    /// Every error found, in instance document order where practical, de-duplicated.
    public let errors: [SchemaValidationError]

    public init(errors: [SchemaValidationError]) {
        self.errors = errors
    }

    /// True when no errors were produced.
    public var isValid: Bool { errors.isEmpty }
}

/// Thrown by `SchemaValidator.init` when the schema itself is structurally broken.
public struct SchemaCompileError: Error, LocalizedError, Equatable {
    /// What is wrong, e.g. "Invalid regular expression '[a-'".
    public let message: String
    /// JSON pointer (with a leading `#`) to the offending location in the schema.
    public let schemaPath: String

    public init(message: String, schemaPath: String) {
        self.message = message
        self.schemaPath = schemaPath
    }

    public var errorDescription: String? { "\(message) (at \(schemaPath))" }
}

// MARK: - Validator

/// Validates `JSONValue` instances against a JSON Schema (drafts 4 through 2020-12, handled leniently
/// in a single implementation). Compile once, validate many times.
public struct SchemaValidator {
    /// The schema this validator was compiled from.
    public let schema: JSONValue
    private let index: SchemaIndex

    /// Precompiles the schema: indexes `$id`/`$anchor`/`$defs`, compiles regular expressions, and checks
    /// that every position expecting a schema holds an object or boolean.
    /// - Throws: `SchemaCompileError` when the schema is structurally broken.
    public init(schema: JSONValue) throws {
        self.schema = schema
        var compiler = SchemaCompiler(root: schema)
        try compiler.compile()
        self.index = compiler.index
    }

    /// Validates `instance`, collecting every error rather than stopping at the first.
    public func validate(_ instance: JSONValue) -> SchemaValidationResult {
        var evaluator = SchemaEvaluator(root: schema, index: index)
        evaluator.validate(instance, at: .root, schema: schema, pointer: "")
        var seen = Set<SchemaValidationError>()
        let unique = evaluator.errors.filter { seen.insert($0).inserted }
        return SchemaValidationResult(errors: unique)
    }

    /// Convenience one-shot validation. A schema compile error is reported as a single error at the
    /// instance root with keyword `schema`.
    public static func validate(_ instance: JSONValue, against schema: JSONValue) -> SchemaValidationResult {
        do {
            return try SchemaValidator(schema: schema).validate(instance)
        } catch let error as SchemaCompileError {
            let single = SchemaValidationError(instancePath: .root, schemaPath: error.schemaPath, keyword: "schema", message: error.message)
            return SchemaValidationResult(errors: [single])
        } catch {
            let single = SchemaValidationError(instancePath: .root, schemaPath: "#", keyword: "schema", message: "\(error)")
            return SchemaValidationResult(errors: [single])
        }
    }
}

// MARK: - Compiled index

/// Everything the compiler learned about a schema document that the evaluator needs at run time.
struct SchemaIndex {
    /// Base URI of the root resource (`$id` of the root, or "" when absent).
    var rootBase = ""
    /// Schema pointer -> base URI of the resource enclosing that schema.
    var baseByPointer: [String: String] = [:]
    /// Resource base URI -> schema pointer of the subschema that declares it.
    var resources: [String: String] = [:]
    /// "base#name" -> schema pointer, for `$anchor` and draft-6/7 `$id: "#name"`.
    var anchors: [String: String] = [:]
    /// Precompiled `pattern` / `patternProperties` regular expressions keyed by their source text.
    var regexes: [String: NSRegularExpression] = [:]
}

enum SchemaPointer {
    /// Escapes a JSON Pointer reference token (RFC 6901).
    static func escape(_ token: String) -> String {
        token.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    /// Resolves a (possibly relative) URI against a base, dropping any fragment.
    static func resolveURI(_ reference: String, against base: String) -> String {
        let stripped = stripFragment(reference)
        guard !base.isEmpty, let baseURL = URL(string: base), let url = URL(string: stripped, relativeTo: baseURL) else {
            return stripped
        }
        return stripFragment(url.absoluteString)
    }

    static func stripFragment(_ uri: String) -> String {
        guard let hash = uri.firstIndex(of: "#") else { return uri }
        return String(uri[..<hash])
    }
}

// MARK: - Compiler

private struct SchemaCompiler {
    let root: JSONValue
    var index = SchemaIndex()
    private let isDraft4: Bool

    init(root: JSONValue) {
        self.root = root
        self.isDraft4 = root["$schema"]?.stringValue?.contains("draft-04") == true
    }

    mutating func compile() throws {
        if let rootID = identifier(of: root), !rootID.hasPrefix("#") {
            index.rootBase = SchemaPointer.stripFragment(rootID)
        }
        index.resources[index.rootBase] = ""
        try walkSchema(root, pointer: "", base: index.rootBase)
    }

    private func identifier(of schema: JSONValue) -> String? {
        if let id = schema["$id"]?.stringValue { return id }
        if isDraft4, let id = schema["id"]?.stringValue { return id }
        return nil
    }

    private mutating func walkSchema(_ value: JSONValue, pointer: String, base parentBase: String) throws {
        switch value {
        case .bool:
            return
        case .object(let object):
            var base = parentBase
            if let id = identifier(of: value) {
                if id.hasPrefix("#") {
                    let name = String(id.dropFirst())
                    if !name.isEmpty { index.anchors["\(base)#\(name)"] = pointer }
                } else {
                    base = SchemaPointer.resolveURI(id, against: parentBase)
                    if index.resources[base] == nil { index.resources[base] = pointer }
                }
            }
            if let anchor = object["$anchor"]?.stringValue {
                index.anchors["\(base)#\(anchor)"] = pointer
            }
            index.baseByPointer[pointer] = base

            if let pattern = object["pattern"]?.stringValue {
                try compileRegex(pattern, at: pointer + "/pattern")
            }

            for keyword in ["additionalItems", "contains", "additionalProperties", "propertyNames", "not", "if", "then", "else",
                            "unevaluatedItems", "unevaluatedProperties"] {
                if let sub = object[keyword] {
                    try walkSchema(sub, pointer: pointer + "/" + keyword, base: base)
                }
            }
            if let items = object["items"] {
                if let tuple = items.arrayValue {
                    try walkArray(tuple, pointer: pointer + "/items", base: base)
                } else {
                    try walkSchema(items, pointer: pointer + "/items", base: base)
                }
            }
            for keyword in ["allOf", "anyOf", "oneOf", "prefixItems"] {
                if let sub = object[keyword] {
                    guard let array = sub.arrayValue else {
                        throw SchemaCompileError(message: "Expected an array of schemas for '\(keyword)', got \(sub.typeName)", schemaPath: "#" + pointer + "/" + keyword)
                    }
                    try walkArray(array, pointer: pointer + "/" + keyword, base: base)
                }
            }
            for keyword in ["properties", "$defs", "definitions", "dependentSchemas"] {
                if let sub = object[keyword] {
                    guard let map = sub.objectValue else {
                        throw SchemaCompileError(message: "Expected an object of schemas for '\(keyword)', got \(sub.typeName)", schemaPath: "#" + pointer + "/" + keyword)
                    }
                    try walkMap(map, pointer: pointer + "/" + keyword, base: base)
                }
            }
            if let sub = object["patternProperties"] {
                guard let map = sub.objectValue else {
                    throw SchemaCompileError(message: "Expected an object of schemas for 'patternProperties', got \(sub.typeName)", schemaPath: "#" + pointer + "/patternProperties")
                }
                for key in map.keys {
                    try compileRegex(key, at: pointer + "/patternProperties/" + SchemaPointer.escape(key))
                }
                try walkMap(map, pointer: pointer + "/patternProperties", base: base)
            }
            if let sub = object["dependencies"] {
                guard let map = sub.objectValue else {
                    throw SchemaCompileError(message: "Expected an object for 'dependencies', got \(sub.typeName)", schemaPath: "#" + pointer + "/dependencies")
                }
                for (key, dependency) in map.members where dependency.arrayValue == nil {
                    try walkSchema(dependency, pointer: pointer + "/dependencies/" + SchemaPointer.escape(key), base: base)
                }
            }
        default:
            throw SchemaCompileError(message: "Expected a schema (object or boolean), got \(value.typeName)", schemaPath: "#" + pointer)
        }
    }

    private mutating func walkArray(_ array: [JSONValue], pointer: String, base: String) throws {
        for (i, sub) in array.enumerated() {
            try walkSchema(sub, pointer: pointer + "/\(i)", base: base)
        }
    }

    private mutating func walkMap(_ map: JSONObject, pointer: String, base: String) throws {
        for (key, sub) in map.members {
            try walkSchema(sub, pointer: pointer + "/" + SchemaPointer.escape(key), base: base)
        }
    }

    private mutating func compileRegex(_ pattern: String, at pointer: String) throws {
        if index.regexes[pattern] != nil { return }
        do {
            index.regexes[pattern] = try NSRegularExpression(pattern: pattern)
        } catch {
            throw SchemaCompileError(message: "Invalid regular expression '\(pattern)'", schemaPath: "#" + pointer)
        }
    }
}

// MARK: - Evaluator

private struct CycleKey: Hashable {
    let pointer: String
    let path: ValuePath
}

private enum RefResolution {
    case target(pointer: String, schema: JSONValue)
    case external
    case notFound
}

private struct SchemaEvaluator {
    let root: JSONValue
    let index: SchemaIndex
    var errors: [SchemaValidationError] = []
    private var activeRefs = Set<CycleKey>()

    init(root: JSONValue, index: SchemaIndex) {
        self.root = root
        self.index = index
    }

    // MARK: Error helpers

    private mutating func add(_ path: ValuePath, _ schemaPath: String, _ keyword: String, _ message: String) {
        errors.append(SchemaValidationError(instancePath: path, schemaPath: schemaPath, keyword: keyword, message: message))
    }

    private mutating func addKeyword(_ path: ValuePath, _ pointer: String, _ keyword: String, _ message: String) {
        add(path, "#" + pointer + "/" + keyword, keyword, message)
    }

    /// Runs `body` with a fresh error list and returns what it produced, leaving `errors` untouched.
    private mutating func collect(_ body: (inout SchemaEvaluator) -> Void) -> [SchemaValidationError] {
        let saved = errors
        errors = []
        body(&self)
        let produced = errors
        errors = saved
        return produced
    }

    private func regex(for pattern: String) -> NSRegularExpression? {
        index.regexes[pattern] ?? (try? NSRegularExpression(pattern: pattern))
    }

    private static func matches(_ regex: NSRegularExpression, _ string: String) -> Bool {
        regex.firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length)) != nil
    }

    private static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        n == 1 ? "1 \(singular)" : "\(n) \(plural ?? singular + "s")"
    }

    private static func render(_ value: JSONValue) -> String {
        JSONFormatter.minify(value)
    }

    /// Ranks a failed `anyOf`/`oneOf` branch: fewer errors is better, and a branch that fails on the
    /// instance's own `type` is treated as "not the intended branch" and ranked last.
    private static func branchScore(_ branch: [SchemaValidationError], at path: ValuePath) -> Int {
        let rejectsType = branch.contains { $0.keyword == "type" && $0.instancePath == path }
        return branch.count + (rejectsType ? 1_000_000 : 0)
    }

    // MARK: Entry

    mutating func validate(_ instance: JSONValue, at path: ValuePath, schema: JSONValue, pointer: String) {
        let object: JSONObject
        switch schema {
        case .bool(true):
            return
        case .bool(false):
            add(path, "#" + pointer, "false", "Value is not allowed")
            return
        case .object(let o):
            object = o
        default:
            add(path, "#" + pointer, "schema", "Expected a schema (object or boolean), got \(schema.typeName)")
            return
        }

        validateType(instance, at: path, schema: object, pointer: pointer)
        validateEnumConst(instance, at: path, schema: object, pointer: pointer)

        switch instance {
        case .number(let number):
            validateNumber(number, at: path, schema: object, pointer: pointer)
        case .string(let string):
            validateString(string, at: path, schema: object, pointer: pointer)
        case .array(let items):
            validateArray(items, at: path, schema: object, pointer: pointer)
        case .object(let members):
            validateObject(instance, members, at: path, schema: object, pointer: pointer)
        default:
            break
        }

        validateApplicators(instance, at: path, schema: object, pointer: pointer)
        validateRef(instance, at: path, schema: object, pointer: pointer)
    }

    // MARK: Generic keywords

    private static func typeMatches(_ instance: JSONValue, _ name: String) -> Bool {
        switch name {
        case "integer":
            if case .number(let n) = instance { return n.isInteger }
            return false
        case "any":
            return true
        default:
            return instance.typeName == name
        }
    }

    private mutating func validateType(_ instance: JSONValue, at path: ValuePath, schema: JSONObject, pointer: String) {
        guard let type = schema["type"] else { return }
        let names: [String]
        if let single = type.stringValue {
            names = [single]
        } else if let list = type.arrayValue {
            names = list.compactMap(\.stringValue)
        } else {
            return
        }
        guard !names.isEmpty, !names.contains(where: { Self.typeMatches(instance, $0) }) else { return }
        addKeyword(path, pointer, "type", "Expected \(names.joined(separator: " or ")), got \(instance.typeName)")
    }

    private mutating func validateEnumConst(_ instance: JSONValue, at path: ValuePath, schema: JSONObject, pointer: String) {
        if let candidates = schema["enum"]?.arrayValue, !candidates.contains(where: { $0.isJSONEqual(to: instance) }) {
            addKeyword(path, pointer, "enum", "Must be one of: " + candidates.map(Self.render).joined(separator: ", "))
        }
        if let constant = schema["const"], !constant.isJSONEqual(to: instance) {
            addKeyword(path, pointer, "const", "Must be equal to \(Self.render(constant))")
        }
    }

    // MARK: Numbers

    /// Floating-point tolerant multiple check: uses `Decimal` arithmetic on the source literals so that
    /// 0.3 is a multiple of 0.1, falling back to a relative epsilon on doubles.
    static func isMultiple(_ value: JSONNumber, of divisor: JSONNumber) -> Bool {
        guard divisor.doubleValue > 0, value.doubleValue.isFinite else { return false }
        if value.doubleValue == 0 { return true }
        if let a = Decimal(string: value.literal), let b = Decimal(string: divisor.literal), b != 0 {
            var quotient = a / b
            if !quotient.isNaN {
                var rounded = Decimal()
                NSDecimalRound(&rounded, &quotient, 0, .plain)
                return quotient == rounded
            }
        }
        let quotient = value.doubleValue / divisor.doubleValue
        guard quotient.isFinite else { return false }
        return abs(quotient - quotient.rounded()) < 1e-9
    }

    private mutating func validateNumber(_ number: JSONNumber, at path: ValuePath, schema: JSONObject, pointer: String) {
        let value = number.doubleValue

        if let divisor = schema["multipleOf"]?.numberValue, !Self.isMultiple(number, of: divisor) {
            addKeyword(path, pointer, "multipleOf", "Value \(number) is not a multiple of \(divisor)")
        }

        if let maximum = schema["maximum"]?.numberValue {
            if schema["exclusiveMaximum"]?.boolValue == true {
                if value >= maximum.doubleValue {
                    addKeyword(path, pointer, "maximum", "Value \(number) must be less than \(maximum)")
                }
            } else if value > maximum.doubleValue {
                addKeyword(path, pointer, "maximum", "Value \(number) exceeds maximum \(maximum)")
            }
        }
        if let exclusive = schema["exclusiveMaximum"]?.numberValue, value >= exclusive.doubleValue {
            addKeyword(path, pointer, "exclusiveMaximum", "Value \(number) must be less than \(exclusive)")
        }

        if let minimum = schema["minimum"]?.numberValue {
            if schema["exclusiveMinimum"]?.boolValue == true {
                if value <= minimum.doubleValue {
                    addKeyword(path, pointer, "minimum", "Value \(number) must be greater than \(minimum)")
                }
            } else if value < minimum.doubleValue {
                addKeyword(path, pointer, "minimum", "Value \(number) is less than minimum \(minimum)")
            }
        }
        if let exclusive = schema["exclusiveMinimum"]?.numberValue, value <= exclusive.doubleValue {
            addKeyword(path, pointer, "exclusiveMinimum", "Value \(number) must be greater than \(exclusive)")
        }
    }

    // MARK: Strings

    private mutating func validateString(_ string: String, at path: ValuePath, schema: JSONObject, pointer: String) {
        let length = string.unicodeScalars.count
        if let maximum = schema["maxLength"]?.intValue, length > maximum {
            addKeyword(path, pointer, "maxLength", "String length \(length) exceeds maximum \(maximum)")
        }
        if let minimum = schema["minLength"]?.intValue, length < minimum {
            addKeyword(path, pointer, "minLength", "String length \(length) is less than minimum \(minimum)")
        }
        if let pattern = schema["pattern"]?.stringValue {
            if let regex = regex(for: pattern) {
                if !Self.matches(regex, string) {
                    addKeyword(path, pointer, "pattern", "Does not match pattern '\(pattern)'")
                }
            } else {
                addKeyword(path, pointer, "pattern", "Invalid regular expression '\(pattern)'")
            }
        }
        if let format = schema["format"]?.stringValue, let failure = SchemaFormats.failureMessage(format: format, value: string) {
            addKeyword(path, pointer, "format", failure)
        }
    }

    // MARK: Arrays

    private mutating func validateArray(_ items: [JSONValue], at path: ValuePath, schema: JSONObject, pointer: String) {
        if let maximum = schema["maxItems"]?.intValue, items.count > maximum {
            addKeyword(path, pointer, "maxItems", "Array has \(Self.count(items.count, "item")), expected at most \(maximum)")
        }
        if let minimum = schema["minItems"]?.intValue, items.count < minimum {
            addKeyword(path, pointer, "minItems", "Array has \(Self.count(items.count, "item")), expected at least \(minimum)")
        }
        if schema["uniqueItems"]?.boolValue == true, items.count > 1 {
            for j in 1..<items.count {
                if let i = items[..<j].firstIndex(where: { $0.isJSONEqual(to: items[j]) }) {
                    addKeyword(path, pointer, "uniqueItems", "Array has duplicate items at indices \(i) and \(j)")
                }
            }
        }

        if let prefix = schema["prefixItems"]?.arrayValue {
            for (i, sub) in prefix.enumerated() where i < items.count {
                validate(items[i], at: path.appending(index: i), schema: sub, pointer: pointer + "/prefixItems/\(i)")
            }
            if let rest = schema["items"] {
                validateRemainingItems(items, from: prefix.count, at: path, schema: rest, keyword: "items", pointer: pointer)
            }
        } else if let itemsSchema = schema["items"] {
            if let tuple = itemsSchema.arrayValue {
                for (i, sub) in tuple.enumerated() where i < items.count {
                    validate(items[i], at: path.appending(index: i), schema: sub, pointer: pointer + "/items/\(i)")
                }
                if let additional = schema["additionalItems"] {
                    validateRemainingItems(items, from: tuple.count, at: path, schema: additional, keyword: "additionalItems", pointer: pointer)
                }
            } else {
                validateRemainingItems(items, from: 0, at: path, schema: itemsSchema, keyword: "items", pointer: pointer)
            }
        }

        if let containsSchema = schema["contains"] {
            var matched = 0
            for (i, item) in items.enumerated() {
                let branch = collect { $0.validate(item, at: path.appending(index: i), schema: containsSchema, pointer: pointer + "/contains") }
                if branch.isEmpty { matched += 1 }
            }
            let minimum = schema["minContains"]?.intValue ?? 1
            if let maximum = schema["maxContains"]?.intValue, matched > maximum {
                addKeyword(path, pointer, "maxContains", "Found \(Self.count(matched, "item")) matching 'contains', expected at most \(maximum)")
            }
            if matched < minimum {
                if matched == 0, schema["minContains"] == nil {
                    addKeyword(path, pointer, "contains", "No items match 'contains' schema")
                } else {
                    addKeyword(path, pointer, "minContains", "Found \(Self.count(matched, "item")) matching 'contains', expected at least \(minimum)")
                }
            }
        }
    }

    private mutating func validateRemainingItems(_ items: [JSONValue], from start: Int, at path: ValuePath, schema: JSONValue, keyword: String, pointer: String) {
        guard start < items.count else { return }
        for i in start..<items.count {
            let itemPath = path.appending(index: i)
            if case .bool(false) = schema {
                addKeyword(itemPath, pointer, keyword, "Unexpected item at index \(i)")
            } else {
                validate(items[i], at: itemPath, schema: schema, pointer: pointer + "/" + keyword)
            }
        }
    }

    // MARK: Objects

    private mutating func validateObject(_ instance: JSONValue, _ members: JSONObject, at path: ValuePath, schema: JSONObject, pointer: String) {
        if let required = schema["required"]?.arrayValue {
            for name in required.compactMap(\.stringValue) where !members.contains(name) {
                addKeyword(path, pointer, "required", "Missing required property '\(name)'")
            }
        }
        if let maximum = schema["maxProperties"]?.intValue, members.count > maximum {
            addKeyword(path, pointer, "maxProperties", "Object has \(Self.count(members.count, "property", "properties")), expected at most \(maximum)")
        }
        if let minimum = schema["minProperties"]?.intValue, members.count < minimum {
            addKeyword(path, pointer, "minProperties", "Object has \(Self.count(members.count, "property", "properties")), expected at least \(minimum)")
        }
        if let dependent = schema["dependentRequired"]?.objectValue {
            validateDependentRequired(dependent, members, at: path, keyword: "dependentRequired", pointer: pointer)
        }
        if let dependencies = schema["dependencies"]?.objectValue {
            validateDependentRequired(dependencies, members, at: path, keyword: "dependencies", pointer: pointer)
        }

        if let namesSchema = schema["propertyNames"] {
            for key in members.keys {
                validate(.string(key), at: path.appending(key: key), schema: namesSchema, pointer: pointer + "/propertyNames")
            }
        }

        let properties = schema["properties"]?.objectValue
        let patternProperties = schema["patternProperties"]?.objectValue
        let additional = schema["additionalProperties"]
        for (key, value) in members.members {
            let memberPath = path.appending(key: key)
            var evaluated = false
            if let sub = properties?[key] {
                validate(value, at: memberPath, schema: sub, pointer: pointer + "/properties/" + SchemaPointer.escape(key))
                evaluated = true
            }
            if let patterns = patternProperties {
                for (pattern, sub) in patterns.members {
                    guard let regex = regex(for: pattern), Self.matches(regex, key) else { continue }
                    validate(value, at: memberPath, schema: sub, pointer: pointer + "/patternProperties/" + SchemaPointer.escape(pattern))
                    evaluated = true
                }
            }
            if !evaluated, let additional {
                if case .bool(false) = additional {
                    addKeyword(memberPath, pointer, "additionalProperties", "Unexpected property '\(key)'")
                } else {
                    validate(value, at: memberPath, schema: additional, pointer: pointer + "/additionalProperties")
                }
            }
        }

        if let dependentSchemas = schema["dependentSchemas"]?.objectValue {
            for (key, sub) in dependentSchemas.members where members.contains(key) {
                validate(instance, at: path, schema: sub, pointer: pointer + "/dependentSchemas/" + SchemaPointer.escape(key))
            }
        }
        if let dependencies = schema["dependencies"]?.objectValue {
            for (key, sub) in dependencies.members where members.contains(key) && sub.arrayValue == nil {
                validate(instance, at: path, schema: sub, pointer: pointer + "/dependencies/" + SchemaPointer.escape(key))
            }
        }
    }

    private mutating func validateDependentRequired(_ map: JSONObject, _ members: JSONObject, at path: ValuePath, keyword: String, pointer: String) {
        for (key, dependency) in map.members where members.contains(key) {
            guard let names = dependency.arrayValue else { continue }
            for name in names.compactMap(\.stringValue) where !members.contains(name) {
                addKeyword(path, pointer, keyword, "Property '\(name)' is required when '\(key)' is present")
            }
        }
    }

    // MARK: Applicators

    private mutating func validateApplicators(_ instance: JSONValue, at path: ValuePath, schema: JSONObject, pointer: String) {
        if let all = schema["allOf"]?.arrayValue {
            for (i, sub) in all.enumerated() {
                validate(instance, at: path, schema: sub, pointer: pointer + "/allOf/\(i)")
            }
        }

        if let any = schema["anyOf"]?.arrayValue {
            var best: [SchemaValidationError]?
            var bestScore = Int.max
            var passed = false
            for (i, sub) in any.enumerated() {
                let branch = collect { $0.validate(instance, at: path, schema: sub, pointer: pointer + "/anyOf/\(i)") }
                if branch.isEmpty {
                    passed = true
                    break
                }
                let score = Self.branchScore(branch, at: path)
                if score < bestScore {
                    best = branch
                    bestScore = score
                }
            }
            if !passed {
                addKeyword(path, pointer, "anyOf", "Does not match any of \(Self.count(any.count, "schema"))")
                errors.append(contentsOf: best ?? [])
            }
        }

        if let one = schema["oneOf"]?.arrayValue {
            var best: [SchemaValidationError]?
            var bestScore = Int.max
            var passes = 0
            for (i, sub) in one.enumerated() {
                let branch = collect { $0.validate(instance, at: path, schema: sub, pointer: pointer + "/oneOf/\(i)") }
                if branch.isEmpty {
                    passes += 1
                    continue
                }
                let score = Self.branchScore(branch, at: path)
                if score < bestScore {
                    best = branch
                    bestScore = score
                }
            }
            if passes == 0 {
                addKeyword(path, pointer, "oneOf", "Does not match any of \(Self.count(one.count, "schema"))")
                errors.append(contentsOf: best ?? [])
            } else if passes > 1 {
                addKeyword(path, pointer, "oneOf", "Matches \(passes) of \(Self.count(one.count, "schema")), expected exactly one")
            }
        }

        if let not = schema["not"] {
            let branch = collect { $0.validate(instance, at: path, schema: not, pointer: pointer + "/not") }
            if branch.isEmpty {
                addKeyword(path, pointer, "not", "Must not match schema")
            }
        }

        if let condition = schema["if"] {
            let holds = collect { $0.validate(instance, at: path, schema: condition, pointer: pointer + "/if") }.isEmpty
            if holds {
                if let then = schema["then"] {
                    validate(instance, at: path, schema: then, pointer: pointer + "/then")
                }
            } else if let otherwise = schema["else"] {
                validate(instance, at: path, schema: otherwise, pointer: pointer + "/else")
            }
        }
    }

    // MARK: $ref

    private mutating func validateRef(_ instance: JSONValue, at path: ValuePath, schema: JSONObject, pointer: String) {
        let candidates: [(keyword: String, value: JSONValue?)] = [
            ("$ref", schema["$ref"]), ("$dynamicRef", schema["$dynamicRef"]), ("$recursiveRef", schema["$recursiveRef"]),
        ]
        for (keyword, value) in candidates {
            guard let ref = value?.stringValue else { continue }
            switch resolve(ref, fromPointer: pointer) {
            case .external:
                addKeyword(path, pointer, keyword, "External $ref '\(ref)' is not supported")
            case .notFound:
                addKeyword(path, pointer, keyword, "Cannot resolve $ref '\(ref)'")
            case .target(let targetPointer, let target):
                let key = CycleKey(pointer: targetPointer, path: path)
                if activeRefs.contains(key) {
                    addKeyword(path, pointer, keyword, "Circular $ref '\(ref)' does not terminate")
                    continue
                }
                activeRefs.insert(key)
                validate(instance, at: path, schema: target, pointer: targetPointer)
                activeRefs.remove(key)
            }
        }
    }

    private func resolve(_ ref: String, fromPointer pointer: String) -> RefResolution {
        let base = index.baseByPointer[pointer] ?? index.rootBase
        let uriPart: String
        let fragment: String?
        if let hash = ref.firstIndex(of: "#") {
            uriPart = String(ref[..<hash])
            fragment = String(ref[ref.index(after: hash)...])
        } else {
            uriPart = ref
            fragment = nil
        }

        let resourceBase: String
        let resourcePointer: String
        if uriPart.isEmpty {
            resourceBase = base
            resourcePointer = index.resources[base] ?? ""
        } else {
            let resolved = SchemaPointer.resolveURI(uriPart, against: base)
            guard let found = index.resources[resolved] else { return .external }
            resourceBase = resolved
            resourcePointer = found
        }

        guard let fragment, !fragment.isEmpty else { return lookup(resourcePointer) }
        let decoded = fragment.removingPercentEncoding ?? fragment
        if decoded.hasPrefix("/") {
            return lookup(resourcePointer + decoded)
        }
        guard let anchored = index.anchors["\(resourceBase)#\(decoded)"] else { return .notFound }
        return lookup(anchored)
    }

    private func lookup(_ pointer: String) -> RefResolution {
        guard let tokens = ValuePath.fromJSONPointer(pointer), let (_, value) = root.value(atPointerTokens: tokens) else {
            return .notFound
        }
        return .target(pointer: pointer, schema: value)
    }
}
