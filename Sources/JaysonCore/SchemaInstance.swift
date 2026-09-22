import Foundation

// MARK: - Options

/// Controls how `SchemaInstanceGenerator` fills in values.
public struct SchemaInstanceOptions: Sendable, Equatable {
    /// When false, strings become `""`, numbers `0` and booleans `false`. When true, strings get
    /// realistic placeholders (`"text"`, or a format-specific value such as `"user@example.com"`).
    public var useSampleValues = false
    /// When false, objects only contain the properties listed in `required`.
    public var includeOptionalProperties = true

    public init() {}
}

// MARK: - Generator

/// Builds a template JSON value that satisfies a JSON Schema as far as the generator understands it.
///
/// Priority for each schema: boolean schemas give `null`; then `default`, `const`, the first
/// `examples` entry and the first `enum` entry win; otherwise the instance is assembled from
/// `type` (or inferred from `properties` / `items`), `allOf` branches, the first `anyOf` /
/// `oneOf` branch and a local `$ref`, all merged key-wise for objects.
public enum SchemaInstanceGenerator {
    /// Upper bound on how many `items` instances are produced to satisfy `minItems`.
    static let maxGeneratedItems = 100

    /// Builds a value satisfying `schema`. `root` resolves local `$ref`s (`#`, `#/$defs/x`,
    /// `#/definitions/x`, `#anchor`) and defaults to `schema` itself.
    public static func makeInstance(from schema: JSONValue, root: JSONValue? = nil, options: SchemaInstanceOptions = .init()) -> JSONValue {
        var context = Context(root: root ?? schema, options: options)
        return context.generate(schema)
    }
}

// MARK: - Context

private struct Context {
    let root: JSONValue
    let options: SchemaInstanceOptions
    /// `$ref` strings currently being expanded, for cycle detection.
    var refStack: [String] = []

    init(root: JSONValue, options: SchemaInstanceOptions) {
        self.root = root
        self.options = options
    }

    // MARK: Dispatch

    mutating func generate(_ schema: JSONValue) -> JSONValue {
        guard case .object(let object) = schema else { return .null }

        if let value = object["default"] { return value }
        if let value = object["const"] { return value }
        if let examples = object["examples"]?.arrayValue, let first = examples.first { return first }
        if let choices = object["enum"]?.arrayValue, let first = choices.first { return first }

        var instance: JSONValue = .null
        if let type = resolvedType(object) {
            instance = generate(type: type, object)
        }
        for branch in object["allOf"]?.arrayValue ?? [] {
            instance = Context.combine(instance, generate(branch))
        }
        for keyword in ["anyOf", "oneOf"] {
            if let first = object[keyword]?.arrayValue?.first {
                instance = Context.combine(instance, generate(first))
            }
        }
        if let ref = object["$ref"]?.stringValue {
            instance = Context.combine(instance, generate(ref: ref))
        }
        return instance
    }

    /// The effective type name: the first non-null `type` entry, or one inferred from
    /// structural keywords when `type` is missing.
    private func resolvedType(_ object: JSONObject) -> String? {
        switch object["type"] {
        case .string(let name)?:
            return name
        case .array(let list)?:
            let names = list.compactMap(\.stringValue)
            return names.first { $0 != "null" } ?? names.first
        default:
            if object["properties"] != nil { return "object" }
            if object["items"] != nil || object["prefixItems"] != nil { return "array" }
            return nil
        }
    }

    private mutating func generate(type: String, _ object: JSONObject) -> JSONValue {
        switch type {
        case "object": return generateObject(object)
        case "array": return generateArray(object)
        case "string": return .string(generateString(object))
        case "number": return .number(generateNumber(object, integral: false))
        case "integer": return .number(generateNumber(object, integral: true))
        case "boolean": return .bool(false)
        default: return .null
        }
    }

    // MARK: Containers

    private mutating func generateObject(_ object: JSONObject) -> JSONValue {
        let required = object["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let requiredSet = Set(required)
        var out = JSONObject()
        for (key, propertySchema) in object["properties"]?.objectValue?.members ?? [] {
            guard options.includeOptionalProperties || requiredSet.contains(key) else { continue }
            out[key] = generate(propertySchema)
        }
        for key in required where !out.contains(key) {
            out[key] = .null
        }
        return .object(out)
    }

    private mutating func generateArray(_ object: JSONObject) -> JSONValue {
        var out: [JSONValue] = []
        for prefixSchema in object["prefixItems"]?.arrayValue ?? [] {
            out.append(generate(prefixSchema))
        }
        let minItems = min(object["minItems"]?.intValue ?? 0, SchemaInstanceGenerator.maxGeneratedItems)
        let items = object["items"]
        while out.count < minItems {
            if let items, items.objectValue != nil {
                out.append(generate(items))
            } else {
                out.append(.null)
            }
        }
        return .array(out)
    }

    // MARK: Scalars

    private func generateString(_ object: JSONObject) -> String {
        var value = ""
        if options.useSampleValues {
            value = Context.sampleString(format: object["format"]?.stringValue)
        }
        if let minLength = object["minLength"]?.intValue, value.count < minLength {
            value += String(repeating: "a", count: minLength - value.count)
        }
        return value
    }

    private static func sampleString(format: String?) -> String {
        switch format {
        case "date-time": return "2024-01-01T00:00:00Z"
        case "date": return "2024-01-01"
        case "time": return "00:00:00Z"
        case "duration": return "PT0S"
        case "email", "idn-email": return "user@example.com"
        case "uri", "iri": return "https://example.com"
        case "uri-reference", "iri-reference": return "/path"
        case "uuid": return "00000000-0000-4000-8000-000000000000"
        case "ipv4": return "127.0.0.1"
        case "ipv6": return "::1"
        case "hostname", "idn-hostname": return "example.com"
        case "regex": return ".*"
        case "json-pointer": return "/a"
        case "relative-json-pointer": return "0"
        default: return "text"
        }
    }

    private func generateNumber(_ object: JSONObject, integral: Bool) -> JSONNumber {
        let multipleOf = object["multipleOf"]?.doubleValue.flatMap { $0 > 0 ? $0 : nil }
        var value: Double
        if let minimum = object["minimum"]?.numberValue {
            // Keep the author's literal when no adjustment is needed.
            if multipleOf == nil, !integral || minimum.isInteger { return minimum }
            value = minimum.doubleValue
        } else if let exclusive = object["exclusiveMinimum"]?.doubleValue {
            value = exclusive + (multipleOf ?? 1)
        } else {
            return JSONNumber(0)
        }

        if let multipleOf {
            value = (value / multipleOf).rounded(.up) * multipleOf
            if integral {
                // Step to the next multiple until it is integral (e.g. multipleOf 2.5 -> 5).
                var steps = 0
                while value != value.rounded(), steps < 1000 {
                    value += multipleOf
                    steps += 1
                }
            }
        }
        if integral {
            value = value.rounded(.up)
        }
        if let maximum = object["maximum"]?.doubleValue, value > maximum {
            value = maximum
            if let multipleOf { value = (value / multipleOf).rounded(.down) * multipleOf }
            if integral { value = value.rounded(.down) }
        }
        return JSONNumber(value)
    }

    // MARK: References

    private mutating func generate(ref: String) -> JSONValue {
        guard !refStack.contains(ref), let target = resolve(ref: ref) else { return .null }
        refStack.append(ref)
        defer { refStack.removeLast() }
        return generate(target)
    }

    /// Resolves a local reference against `root`: `#`, a JSON Pointer fragment, or a `$anchor`.
    private func resolve(ref: String) -> JSONValue? {
        guard let hash = ref.firstIndex(of: "#") else { return nil }
        // Anything before `#` must be empty: only same-document references are supported.
        guard ref[ref.startIndex..<hash].isEmpty else { return nil }
        let fragment = String(ref[ref.index(after: hash)...])
        if fragment.isEmpty { return root }
        if fragment.hasPrefix("/") {
            let decoded = fragment.removingPercentEncoding ?? fragment
            guard let tokens = ValuePath.fromJSONPointer(decoded) else { return nil }
            return root.value(atPointerTokens: tokens)?.1
        }
        return anchor(named: fragment, in: root)
    }

    private func anchor(named name: String, in value: JSONValue) -> JSONValue? {
        var found: JSONValue?
        value.walk { _, candidate in
            guard found == nil, case .object(let object) = candidate else { return }
            if object["$anchor"]?.stringValue == name { found = candidate }
        }
        return found
    }

    // MARK: Combining

    /// Merges two partial instances. Objects merge key-wise (recursively), `null` yields to
    /// anything else, and otherwise the first value wins.
    static func combine(_ base: JSONValue, _ extra: JSONValue) -> JSONValue {
        switch (base, extra) {
        case (.null, _):
            return extra
        case (.object(var merged), .object(let other)):
            for (key, value) in other.members {
                merged[key] = merged[key].map { combine($0, value) } ?? value
            }
            return .object(merged)
        default:
            return base
        }
    }
}
