import Foundation

// MARK: - Options

/// Controls how `SchemaInferrer` derives a JSON Schema from sample documents.
public struct SchemaInferenceOptions: Sendable, Equatable {
    /// How the `required` keyword of inferred object schemas is populated.
    public enum RequiredPolicy: Sendable, Equatable {
        /// A property is required when every merged sample contains it (the default).
        case presentInAllSamples
        /// Never emit `required`.
        case none
        /// Every known property is required.
        case all
    }

    /// Detect `date-time`, `date`, `time`, `email`, `uri`, `uuid` and `ipv4` formats.
    /// A format is emitted only when every string sample at that location matches it.
    public var detectFormats = true
    /// Add `"examples": [<first sample>]` to scalar schemas.
    public var includeExamples = false
    /// How `required` is derived for object schemas.
    public var requiredPolicy: RequiredPolicy = .presentInAllSamples
    /// Add `"$schema": "https://json-schema.org/draft/2020-12/schema"` to root schemas.
    public var addSchemaKeyword = true

    public init() {}
}

// MARK: - Inferrer

/// Infers JSON Schema (draft 2020-12 vocabulary) from JSON values.
///
/// Output is deterministic: keywords are emitted in the order `$schema`, `type`, `format`,
/// `properties`, `required`, `items`, `anyOf`, `examples`, object properties follow first-seen
/// key order, and `type` arrays are sorted alphabetically with `null` last.
public enum SchemaInferrer {
    /// The `$schema` URI emitted at the root when `addSchemaKeyword` is enabled.
    public static let schemaKeywordValue = "https://json-schema.org/draft/2020-12/schema"

    /// Maximum number of values kept in a merged `examples` array.
    static let maxExamples = 5

    /// Root schema describing one document (adds `$schema` when enabled).
    public static func infer(from value: JSONValue, options: SchemaInferenceOptions = .init()) -> JSONValue {
        addingSchemaKeyword(to: schema(for: value, options: options), options: options)
    }

    /// Root schema that accepts every sample: the merge of the per-sample schemas.
    /// An empty sample list yields `{}` (plus `$schema` when enabled).
    public static func infer(fromSamples samples: [JSONValue], options: SchemaInferenceOptions = .init()) -> JSONValue {
        guard var merged = samples.first.map({ schema(for: $0, options: options) }) else {
            return addingSchemaKeyword(to: .object(JSONObject()), options: options)
        }
        for sample in samples.dropFirst() {
            merged = merge(merged, schema(for: sample, options: options), policy: options.requiredPolicy)
        }
        return addingSchemaKeyword(to: merged, options: options)
    }

    /// Sub-schema describing `value`. Never contains `$schema`.
    public static func schema(for value: JSONValue, options: SchemaInferenceOptions = .init()) -> JSONValue {
        var shape = Shape()
        switch value {
        case .null:
            shape.types = ["null"]
        case .bool:
            shape.types = ["boolean"]
            if options.includeExamples { shape.examples = [value] }
        case .number(let n):
            shape.types = [n.isInteger ? "integer" : "number"]
            if options.includeExamples { shape.examples = [value] }
        case .string(let s):
            shape.types = ["string"]
            if options.detectFormats { shape.format = FormatDetector.detect(s) }
            if options.includeExamples { shape.examples = [value] }
        case .array(let elements):
            shape.types = ["array"]
            var items: JSONValue?
            for element in elements {
                let elementSchema = schema(for: element, options: options)
                items = items.map { merge($0, elementSchema, policy: options.requiredPolicy) } ?? elementSchema
            }
            shape.items = items
        case .object(let object):
            shape.types = ["object"]
            var properties = JSONObject()
            for (key, member) in object.members {
                properties[key] = schema(for: member, options: options)
            }
            shape.properties = properties
            switch options.requiredPolicy {
            case .presentInAllSamples, .all: shape.required = object.keys
            case .none: shape.required = nil
            }
        }
        return shape.jsonValue
    }

    /// Merges two inferred schemas into one that accepts instances of either.
    ///
    /// Same-typed schemas merge structurally (property union, `required` intersection, merged
    /// `items`), `integer` and `number` widen to `number`, differing scalar types become a
    /// `type` array, and a container merged with anything else becomes `anyOf`. Formats survive
    /// only when both sides agree; `{}` (or a boolean schema) yields the other side unchanged.
    /// Only the keywords the inferrer itself emits are understood; others are dropped.
    public static func merge(_ a: JSONValue, _ b: JSONValue) -> JSONValue {
        merge(a, b, policy: .presentInAllSamples)
    }

    // MARK: Internals

    static func addingSchemaKeyword(to schema: JSONValue, options: SchemaInferenceOptions) -> JSONValue {
        guard options.addSchemaKeyword, case .object(let object) = schema else { return schema }
        var out = JSONObject()
        out["$schema"] = .string(schemaKeywordValue)
        for (key, value) in object.members where key != "$schema" { out[key] = value }
        return .object(out)
    }

    static func merge(_ a: JSONValue, _ b: JSONValue, policy: SchemaInferenceOptions.RequiredPolicy) -> JSONValue {
        let left = Shape(schema: a)
        let right = Shape(schema: b)
        let schemaKeyword = left.schemaKeyword ?? right.schemaKeyword

        var result: Shape
        if left.isUnknown {
            result = right
        } else if right.isUnknown {
            result = left
        } else if left.anyOf != nil || right.anyOf != nil || !left.isMergeable(with: right) {
            var alternatives: [JSONValue] = []
            for alternative in left.alternatives + right.alternatives {
                addAlternative(alternative, to: &alternatives, policy: policy)
            }
            if alternatives.count == 1 {
                result = Shape(schema: alternatives[0])
            } else {
                result = Shape()
                result.anyOf = alternatives
            }
        } else {
            result = mergeCompatible(left, right, policy: policy)
        }
        result.schemaKeyword = schemaKeyword
        return result.jsonValue
    }

    /// Merges two shapes that `isMergeable(with:)` accepted: both objects, both arrays, or both scalar.
    private static func mergeCompatible(_ a: Shape, _ b: Shape, policy: SchemaInferenceOptions.RequiredPolicy) -> Shape {
        var result = Shape()
        switch a.kind {
        case .object:
            result.types = ["object"]
            var properties = a.properties ?? JSONObject()
            for (key, schema) in (b.properties ?? JSONObject()).members {
                if let existing = properties[key] {
                    properties[key] = merge(existing, schema, policy: policy)
                } else {
                    properties[key] = schema
                }
            }
            result.properties = properties
            switch policy {
            case .presentInAllSamples:
                let common = Set(a.required ?? []).intersection(b.required ?? [])
                result.required = properties.keys.filter { common.contains($0) }
            case .all:
                result.required = properties.keys
            case .none:
                result.required = nil
            }
        case .array:
            result.types = ["array"]
            switch (a.items, b.items) {
            case (let x?, let y?): result.items = merge(x, y, policy: policy)
            case (let x?, nil), (nil, let x?): result.items = x
            case (nil, nil): result.items = nil
            }
        case .scalar, .mixed:
            var types = Set(a.types).union(b.types)
            if types.contains("number") { types.remove("integer") }
            result.types = Shape.sortedTypes(types)
            result.format = (a.format == b.format) ? a.format : nil
        }
        result.examples = mergeExamples(a.examples, b.examples)
        return result
    }

    private static func mergeExamples(_ a: [JSONValue]?, _ b: [JSONValue]?) -> [JSONValue]? {
        guard a != nil || b != nil else { return nil }
        var out = a ?? []
        for example in b ?? [] where out.count < maxExamples {
            if !out.contains(where: { $0.isJSONEqual(to: example) }) { out.append(example) }
        }
        return out
    }

    /// Adds `schema` to an `anyOf` alternative list, merging it into a compatible existing
    /// alternative when possible and skipping semantic duplicates.
    private static func addAlternative(_ schema: JSONValue, to alternatives: inout [JSONValue], policy: SchemaInferenceOptions.RequiredPolicy) {
        let shape = Shape(schema: schema)
        if shape.isUnknown { return }
        if let index = alternatives.firstIndex(where: { Shape(schema: $0).isMergeable(with: shape) }) {
            alternatives[index] = merge(alternatives[index], schema, policy: policy)
            return
        }
        if alternatives.contains(where: { $0.isJSONEqual(to: schema) }) { return }
        alternatives.append(schema)
    }
}

// MARK: - Shape

/// The subset of JSON Schema the inferrer produces, decomposed for merging.
struct Shape {
    enum Kind { case object, array, scalar, mixed }

    static let scalarTypes: Set<String> = ["string", "number", "integer", "boolean", "null"]

    var schemaKeyword: String?
    var types: [String] = []
    var format: String?
    var properties: JSONObject?
    var required: [String]?
    var items: JSONValue?
    var anyOf: [JSONValue]?
    var examples: [JSONValue]?

    init() {}

    /// Decomposes a schema value. Non-object schemas and objects without any recognised
    /// structural keyword become the "unknown" shape (`{}`).
    init(schema: JSONValue) {
        guard case .object(let object) = schema else { return }
        schemaKeyword = object["$schema"]?.stringValue
        switch object["type"] {
        case .string(let s)?: types = [s]
        case .array(let list)?: types = Shape.sortedTypes(Set(list.compactMap(\.stringValue)))
        default: break
        }
        format = object["format"]?.stringValue
        properties = object["properties"]?.objectValue
        if let list = object["required"]?.arrayValue { required = list.compactMap(\.stringValue) }
        if let items = object["items"], items.objectValue != nil { self.items = items }
        anyOf = object["anyOf"]?.arrayValue
        if let list = object["examples"]?.arrayValue, !list.isEmpty { examples = list }
        if types.isEmpty {
            if properties != nil || required != nil { types = ["object"] }
            else if items != nil { types = ["array"] }
        }
    }

    /// True for `{}`, boolean schemas, and anything without a `type`, `properties`, `items` or `anyOf`.
    var isUnknown: Bool { types.isEmpty && anyOf == nil }

    var kind: Kind {
        if types == ["object"] { return .object }
        if types == ["array"] { return .array }
        if !types.isEmpty, types.allSatisfy({ Shape.scalarTypes.contains($0) }) { return .scalar }
        return .mixed
    }

    /// The `anyOf` alternatives of this shape, or the shape itself when it has none.
    var alternatives: [JSONValue] {
        if let anyOf { return anyOf }
        var copy = self
        copy.schemaKeyword = nil
        return [copy.jsonValue]
    }

    /// True when the two shapes can be merged into a single schema without `anyOf`.
    func isMergeable(with other: Shape) -> Bool {
        guard anyOf == nil, other.anyOf == nil else { return false }
        switch (kind, other.kind) {
        case (.object, .object), (.array, .array), (.scalar, .scalar): return true
        default: return false
        }
    }

    /// Alphabetical order with `null` last.
    static func sortedTypes(_ types: Set<String>) -> [String] {
        var sorted = types.subtracting(["null"]).sorted()
        if types.contains("null") { sorted.append("null") }
        return sorted
    }

    /// Emits the schema with the canonical keyword order.
    var jsonValue: JSONValue {
        var out = JSONObject()
        if let schemaKeyword { out["$schema"] = .string(schemaKeyword) }
        if types.count == 1 {
            out["type"] = .string(types[0])
        } else if types.count > 1 {
            out["type"] = .array(types.map(JSONValue.string))
        }
        if let format { out["format"] = .string(format) }
        if let properties { out["properties"] = .object(properties) }
        if let required, !required.isEmpty { out["required"] = .array(required.map(JSONValue.string)) }
        if let items { out["items"] = items }
        if let anyOf, !anyOf.isEmpty { out["anyOf"] = .array(anyOf) }
        if let examples, !examples.isEmpty { out["examples"] = .array(examples) }
        return .object(out)
    }
}

// MARK: - Format detection

/// Heuristic detection of common JSON Schema string formats.
enum FormatDetector {
    /// Returns the first matching format in priority order, or nil.
    static func detect(_ string: String) -> String? {
        if string.isEmpty { return nil }
        if matches(string, dateTime) { return "date-time" }
        if matches(string, date), validCalendarDate(string) { return "date" }
        if matches(string, time) { return "time" }
        if matches(string, email) { return "email" }
        if matches(string, uuid) { return "uuid" }
        if matches(string, ipv4) { return "ipv4" }
        if matches(string, uri) { return "uri" }
        return nil
    }

    private static let dateTime = regex(#"^\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})$"#)
    private static let date = regex(#"^\d{4}-\d{2}-\d{2}$"#)
    private static let time = regex(#"^\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})$"#)
    private static let email = regex(#"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)+$"#)
    private static let uuid = regex(#"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#)
    private static let ipv4 = regex(#"^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$"#)
    private static let uri = regex(#"^([A-Za-z][A-Za-z0-9+.\-]*://[^\s]+|(mailto|urn|tel|data|news):[^\s]+)$"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are constants; a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern)
    }

    private static func matches(_ string: String, _ regex: NSRegularExpression) -> Bool {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, range: range) else { return false }
        return match.range == range
    }

    private static func validCalendarDate(_ string: String) -> Bool {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        return (1...12).contains(parts[1]) && (1...31).contains(parts[2])
    }
}
