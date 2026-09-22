import Foundation

/// Best-effort navigation inside a JSON Schema document: finds the sub-schema that
/// applies to an instance location, following `properties`, `patternProperties`,
/// `additionalProperties`, `items`, `prefixItems`, `additionalItems` and local `$ref`s.
public enum SchemaLocator {
    /// Resolves a local reference (`#`, `#/$defs/x`, `#/definitions/x`, JSON pointers, `#anchor`).
    /// Returns nil for external references or dangling pointers.
    public static func resolveLocalRef(_ ref: String, in root: JSONValue) -> JSONValue? {
        guard let hash = ref.firstIndex(of: "#") else { return nil }
        let before = ref[ref.startIndex..<hash]
        guard before.isEmpty else { return nil } // external document
        let fragment = String(ref[ref.index(after: hash)...]).removingPercentEncoding ?? String(ref[ref.index(after: hash)...])
        if fragment.isEmpty { return root }
        if fragment.hasPrefix("/") {
            guard let tokens = ValuePath.fromJSONPointer(fragment) else { return nil }
            return root.value(atPointerTokens: tokens)?.1
        }
        // Plain-name fragment: look for $anchor or draft-6/7 "$id": "#name".
        var found: JSONValue?
        root.walk { _, value in
            guard found == nil, case .object(let o) = value else { return }
            if o["$anchor"]?.stringValue == fragment || o["$id"]?.stringValue == "#\(fragment)" || o["id"]?.stringValue == "#\(fragment)" {
                found = value
            }
        }
        return found
    }

    /// Follows `$ref` chains (up to a small limit) so callers see the concrete schema.
    public static func dereference(_ schema: JSONValue, root: JSONValue) -> JSONValue {
        var current = schema
        var hops = 0
        while hops < 16, case .object(let o) = current, let ref = o["$ref"]?.stringValue {
            guard let target = resolveLocalRef(ref, in: root) else { break }
            // 2019+ semantics: sibling keywords still apply; merge them over the target for navigation purposes.
            if case .object(var t) = target {
                for (key, value) in o.members where key != "$ref" && t[key] == nil { t[key] = value }
                current = .object(t)
            } else {
                current = target
            }
            hops += 1
        }
        return current
    }

    /// The sub-schema that applies at `path`, or nil when the schema says nothing specific.
    public static func subschema(at path: ValuePath, in root: JSONValue) -> JSONValue? {
        var current = dereference(root, root: root)
        for component in path.components {
            guard let next = child(of: current, for: component, root: root) else { return nil }
            current = dereference(next, root: root)
        }
        return current
    }

    /// The schema a *new* element appended to the array at `arrayPath` should satisfy.
    public static func newItemSchema(forArrayAt arrayPath: ValuePath, in root: JSONValue) -> JSONValue? {
        guard let arraySchema = subschema(at: arrayPath, in: root), case .object(let o) = arraySchema else { return nil }
        if let items = o["items"] {
            switch items {
            case .object, .bool: return dereference(items, root: root)
            case .array: // draft-4 tuple form
                if let additional = o["additionalItems"], additional.isContainer { return dereference(additional, root: root) }
                return items.arrayValue?.last.map { dereference($0, root: root) }
            default: break
            }
        }
        if let prefix = o["prefixItems"]?.arrayValue?.last { return dereference(prefix, root: root) }
        return nil
    }

    private static func child(of schema: JSONValue, for component: PathComponent, root: JSONValue) -> JSONValue? {
        guard case .object(let o) = schema else { return nil }
        switch component {
        case .key(let key):
            if let props = o["properties"]?.objectValue, let direct = props[key] { return direct }
            if let patterns = o["patternProperties"]?.objectValue {
                for (pattern, sub) in patterns.members {
                    if let regex = try? NSRegularExpression(pattern: pattern),
                       regex.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil {
                        return sub
                    }
                }
            }
            if let additional = o["additionalProperties"], additional.isContainer { return additional }
            // Look through combinators for a branch that knows the property.
            for combinator in ["allOf", "anyOf", "oneOf"] {
                for branch in o[combinator]?.arrayValue ?? [] {
                    if let found = child(of: dereference(branch, root: root), for: component, root: root) { return found }
                }
            }
            return nil
        case .index(let index):
            if let prefix = o["prefixItems"]?.arrayValue, prefix.indices.contains(index) { return prefix[index] }
            if let items = o["items"] {
                switch items {
                case .array(let tuple):
                    if tuple.indices.contains(index) { return tuple[index] }
                    if let additional = o["additionalItems"], additional.isContainer { return additional }
                    return nil
                case .object: return items
                default: break
                }
            }
            for combinator in ["allOf", "anyOf", "oneOf"] {
                for branch in o[combinator]?.arrayValue ?? [] {
                    if let found = child(of: dereference(branch, root: root), for: component, root: root) { return found }
                }
            }
            return nil
        }
    }
}
