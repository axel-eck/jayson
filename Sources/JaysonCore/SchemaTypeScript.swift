import Foundation

/// Renders JSON Schema as TypeScript type declarations, so TypeScript pipeline steps can be
/// written (and type-checked) against the shape of their input.
///
/// Supported: `type` (single or array), `properties`/`required`/`additionalProperties`,
/// `items`/`prefixItems`, `enum`/`const`, `anyOf`/`oneOf`/`allOf`, boolean schemas, and
/// local `$ref`s to `$defs`/`definitions`, which become named type aliases.
public enum SchemaTypeScript {
    public struct Options: Sendable, Equatable {
        /// Name of the alias generated for the root schema.
        public var rootName = "Input"
        public var indent = "  "
        public init(rootName: String = "Input") { self.rootName = rootName }
    }

    /// `type Input = …;` followed by one alias per definition the schema declares.
    public static func declarations(for schema: JSONValue, options: Options = Options()) -> String {
        var renderer = Renderer(options: options, schema: schema)
        return renderer.render()
    }

    /// Declarations for a JSON value (via schema inference); used when no schema is loaded.
    public static func declarations(inferredFrom value: JSONValue, options: Options = Options()) -> String {
        var inference = SchemaInferenceOptions()
        inference.detectFormats = false
        inference.addSchemaKeyword = false
        return declarations(for: SchemaInferrer.infer(from: value, options: inference), options: options)
    }

    // MARK: - Rendering

    private struct TSType {
        var text: String
        /// True for top-level unions/intersections, which need parentheses inside `T[]`.
        var isCompound = false

        var asElement: String { isCompound ? "(\(text))" : text }
    }

    private struct Renderer {
        let options: Options
        let schema: JSONValue
        /// definition key → alias name
        var aliases: [String: String] = [:]
        var definitions: [(alias: String, schema: JSONValue)] = []

        init(options: Options, schema: JSONValue) {
            self.options = options
            self.schema = schema
            collectDefinitions()
        }

        private mutating func collectDefinitions() {
            var taken: Set<String> = [options.rootName]
            for container in ["$defs", "definitions"] {
                guard let defs = schema[container]?.objectValue else { continue }
                for (key, value) in defs.members {
                    var alias = SchemaTypeScript.identifier(from: key, fallback: "Def")
                    if taken.contains(alias) {
                        var n = 2
                        while taken.contains("\(alias)\(n)") { n += 1 }
                        alias = "\(alias)\(n)"
                    }
                    taken.insert(alias)
                    aliases["#/\(container)/\(key)"] = alias
                    definitions.append((alias, value))
                }
            }
        }

        mutating func render() -> String {
            var out = "type \(options.rootName) = \(type(for: schema, depth: 0).text);\n"
            for definition in definitions {
                out += "\ntype \(definition.alias) = \(type(for: definition.schema, depth: 0).text);\n"
            }
            return out
        }

        private func type(for schema: JSONValue, depth: Int) -> TSType {
            switch schema {
            case .bool(true): return TSType(text: "unknown")
            case .bool(false): return TSType(text: "never")
            case .object(let object): return type(forObjectSchema: object, depth: depth)
            default: return TSType(text: "unknown")
            }
        }

        private func type(forObjectSchema s: JSONObject, depth: Int) -> TSType {
            if let ref = s["$ref"]?.stringValue {
                if ref == "#" || ref == "#/" { return TSType(text: options.rootName) }
                if let alias = aliases[ref] { return TSType(text: alias) }
                return TSType(text: "unknown")
            }
            if let constant = s["const"] {
                return TSType(text: literal(constant))
            }
            if let cases = s["enum"]?.arrayValue {
                if cases.isEmpty { return TSType(text: "never") }
                return union(cases.map { TSType(text: literal($0)) })
            }
            var parts: [TSType] = []
            if let allOf = s["allOf"]?.arrayValue, !allOf.isEmpty {
                let members = allOf.map { type(for: $0, depth: depth) }
                let text = members.map { $0.isCompound ? "(\($0.text))" : $0.text }.joined(separator: " & ")
                parts.append(TSType(text: text, isCompound: members.count > 1))
            }
            for keyword in ["anyOf", "oneOf"] {
                if let alternatives = s[keyword]?.arrayValue, !alternatives.isEmpty {
                    parts.append(union(alternatives.map { type(for: $0, depth: depth) }))
                }
            }

            let typeNames: [String]
            if let single = s["type"]?.stringValue {
                typeNames = [single]
            } else if let many = s["type"]?.arrayValue {
                typeNames = many.compactMap(\.stringValue)
            } else if s.contains("properties") || s.contains("additionalProperties") || s.contains("required") {
                typeNames = ["object"]
            } else if s.contains("items") || s.contains("prefixItems") {
                typeNames = ["array"]
            } else {
                typeNames = []
            }
            if !typeNames.isEmpty {
                parts.append(union(typeNames.map { type(named: $0, schema: s, depth: depth) }))
            }

            switch parts.count {
            case 0: return TSType(text: "unknown")
            case 1: return parts[0]
            default:
                let text = parts.map { $0.isCompound ? "(\($0.text))" : $0.text }.joined(separator: " & ")
                return TSType(text: text, isCompound: true)
            }
        }

        private func type(named name: String, schema s: JSONObject, depth: Int) -> TSType {
            switch name {
            case "string": return TSType(text: "string")
            case "number", "integer": return TSType(text: "number")
            case "boolean": return TSType(text: "boolean")
            case "null": return TSType(text: "null")
            case "array": return arrayType(s, depth: depth)
            case "object": return objectType(s, depth: depth)
            default: return TSType(text: "unknown")
            }
        }

        private func arrayType(_ s: JSONObject, depth: Int) -> TSType {
            if let prefix = s["prefixItems"]?.arrayValue, !prefix.isEmpty {
                var elements = prefix.map { type(for: $0, depth: depth).text }
                if let rest = s["items"], rest != .bool(false) {
                    elements.append("...\(type(for: rest, depth: depth).asElement)[]")
                }
                return TSType(text: "[\(elements.joined(separator: ", "))]")
            }
            if let items = s["items"] {
                return TSType(text: "\(type(for: items, depth: depth).asElement)[]")
            }
            return TSType(text: "unknown[]")
        }

        private func objectType(_ s: JSONObject, depth: Int) -> TSType {
            let properties = s["properties"]?.objectValue ?? JSONObject()
            let required = Set(s["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            let additional = s["additionalProperties"]

            if properties.isEmpty {
                switch additional {
                case .bool(false)?: return TSType(text: "Record<string, never>")
                case let extra? where extra != .bool(true): return TSType(text: "Record<string, \(type(for: extra, depth: depth).text)>")
                default: return TSType(text: "Record<string, unknown>")
                }
            }

            let inner = String(repeating: options.indent, count: depth + 1)
            let outer = String(repeating: options.indent, count: depth)
            var lines: [String] = []
            for (key, value) in properties.members {
                let optional = required.contains(key) ? "" : "?"
                lines.append("\(inner)\(SchemaTypeScript.propertyName(key))\(optional): \(type(for: value, depth: depth + 1).text);")
            }
            if let additional, additional != .bool(false) {
                let valueType = additional == .bool(true) ? "unknown" : type(for: additional, depth: depth + 1).text
                lines.append("\(inner)[key: string]: \(valueType);")
            }
            return TSType(text: "{\n\(lines.joined(separator: "\n"))\n\(outer)}")
        }

        private func union(_ members: [TSType]) -> TSType {
            var seen: Set<String> = []
            let unique = members.filter { seen.insert($0.text).inserted }
            if unique.count == 1 { return unique[0] }
            let text = unique.map { $0.isCompound ? "(\($0.text))" : $0.text }.joined(separator: " | ")
            return TSType(text: text, isCompound: true)
        }

        private func literal(_ value: JSONValue) -> String {
            switch value {
            case .null: return "null"
            case .bool(let b): return b ? "true" : "false"
            case .number(let n): return n.literal
            case .string(let s): return JSONFormatter.escape(s)
            case .array, .object: return "unknown"
            }
        }
    }

    // MARK: - Names

    /// A TypeScript identifier derived from an arbitrary definition key (`user-profile` → `UserProfile`).
    static func identifier(from key: String, fallback: String) -> String {
        var result = ""
        var capitalizeNext = true
        for scalar in key.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                let char = String(scalar)
                result += capitalizeNext ? char.uppercased() : char
                capitalizeNext = false
            } else {
                capitalizeNext = true
            }
        }
        if result.isEmpty { return fallback }
        if let first = result.unicodeScalars.first, CharacterSet.decimalDigits.contains(first) { result = "_" + result }
        return result
    }

    /// Quotes property names that are not plain identifiers.
    static func propertyName(_ key: String) -> String {
        guard let first = key.unicodeScalars.first else { return "\"\"" }
        let identifierStart = CharacterSet.letters.union(CharacterSet(charactersIn: "_$"))
        let identifierPart = identifierStart.union(.decimalDigits)
        let isIdentifier = identifierStart.contains(first) && key.unicodeScalars.allSatisfy { identifierPart.contains($0) }
        return isIdentifier ? key : JSONFormatter.escape(key)
    }
}
