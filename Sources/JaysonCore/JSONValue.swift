import Foundation

// MARK: - Numbers

/// A JSON number that remembers its source literal so round-tripping is lossless
/// (e.g. `1.0`, `1e3`, or integers beyond Double precision keep their spelling).
public struct JSONNumber: Hashable, Sendable, CustomStringConvertible {
    public var literal: String
    public var doubleValue: Double

    public init(literal: String) {
        self.literal = literal
        self.doubleValue = Double(literal) ?? .nan
    }

    public init(_ value: Double) {
        self.doubleValue = value
        if value.isFinite, value == value.rounded(), abs(value) < 1e15 {
            self.literal = String(Int64(value))
        } else {
            self.literal = String(value)
        }
    }

    public init(_ value: Int) {
        self.doubleValue = Double(value)
        self.literal = String(value)
    }

    /// True when the number has no fractional part (JSON Schema's notion of "integer").
    public var isInteger: Bool {
        doubleValue.isFinite && doubleValue == doubleValue.rounded()
    }

    public var intValue: Int? {
        guard isInteger, abs(doubleValue) < 9.007199254740992e15 else { return Int(literal) }
        return Int(doubleValue)
    }

    public var description: String { literal }

    public static func == (lhs: JSONNumber, rhs: JSONNumber) -> Bool {
        if lhs.doubleValue == rhs.doubleValue { return true }
        return lhs.literal == rhs.literal
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(doubleValue)
    }
}

// MARK: - Ordered object

/// An insertion-ordered JSON object.
public struct JSONObject: Hashable, Sendable {
    public private(set) var keys: [String]
    private var storage: [String: JSONValue]

    public init() {
        keys = []
        storage = [:]
    }

    public init(_ pairs: [(String, JSONValue)]) {
        self.init()
        for (key, value) in pairs { self[key] = value }
    }

    public init(_ pairs: KeyValuePairs<String, JSONValue>) {
        self.init()
        for (key, value) in pairs { self[key] = value }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    public var members: [(key: String, value: JSONValue)] {
        keys.map { ($0, storage[$0]!) }
    }

    public var values: [JSONValue] { keys.map { storage[$0]! } }

    public subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil {
                    keys.append(key)
                }
            } else {
                removeValue(forKey: key)
            }
        }
    }

    public func contains(_ key: String) -> Bool { storage[key] != nil }

    @discardableResult
    public mutating func removeValue(forKey key: String) -> JSONValue? {
        guard let removed = storage.removeValue(forKey: key) else { return nil }
        keys.removeAll { $0 == key }
        return removed
    }

    /// Inserts a key at a specific position. If the key already exists it is moved.
    public mutating func insert(_ value: JSONValue, forKey key: String, at index: Int) {
        keys.removeAll { $0 == key }
        storage[key] = value
        keys.insert(key, at: min(max(index, 0), keys.count))
    }

    /// Renames a key in place, keeping its position. Returns false if the new key already exists.
    @discardableResult
    public mutating func rename(_ key: String, to newKey: String) -> Bool {
        guard key != newKey, let idx = keys.firstIndex(of: key), storage[newKey] == nil else { return key == newKey }
        let value = storage.removeValue(forKey: key)!
        storage[newKey] = value
        keys[idx] = newKey
        return true
    }

    public func sortedByKey() -> JSONObject {
        var copy = self
        copy.keys.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return copy
    }

    public func mapValues(_ transform: (JSONValue) -> JSONValue) -> JSONObject {
        var copy = self
        for key in keys { copy.storage[key] = transform(storage[key]!) }
        return copy
    }
}

// MARK: - Value

public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(JSONNumber)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    // Convenience constructors
    public static func number(_ value: Double) -> JSONValue { .number(JSONNumber(value)) }
    public static func number(_ value: Int) -> JSONValue { .number(JSONNumber(value)) }
    public static func object(_ pairs: KeyValuePairs<String, JSONValue>) -> JSONValue { .object(JSONObject(pairs)) }

    /// JSON Schema type name: object, array, string, number, boolean, null.
    public var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    public var isContainer: Bool {
        switch self {
        case .array, .object: return true
        default: return false
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var numberValue: JSONNumber? { if case .number(let n) = self { return n } else { return nil } }
    public var doubleValue: Double? { numberValue?.doubleValue }
    public var intValue: Int? { numberValue?.intValue }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var objectValue: JSONObject? { if case .object(let o) = self { return o } else { return nil } }
    public var isNull: Bool { if case .null = self { return true } else { return false } }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// Number of direct children (array elements or object members). Scalars return 0.
    public var childCount: Int {
        switch self {
        case .array(let a): return a.count
        case .object(let o): return o.count
        default: return 0
        }
    }

    /// Semantic JSON equality as defined by JSON Schema: numbers compare by value and
    /// object member order is ignored.
    public func isJSONEqual(to other: JSONValue) -> Bool {
        switch (self, other) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.number(let a), .number(let b)): return a.doubleValue == b.doubleValue || a.literal == b.literal
        case (.string(let a), .string(let b)): return a == b
        case (.array(let a), .array(let b)):
            guard a.count == b.count else { return false }
            return zip(a, b).allSatisfy { $0.isJSONEqual(to: $1) }
        case (.object(let a), .object(let b)):
            guard a.count == b.count else { return false }
            for (key, value) in a.members {
                guard let otherValue = b[key], value.isJSONEqual(to: otherValue) else { return false }
            }
            return true
        default: return false
        }
    }

    /// Recursively sorts object keys.
    public func sortingKeys() -> JSONValue {
        switch self {
        case .array(let a): return .array(a.map { $0.sortingKeys() })
        case .object(let o): return .object(o.sortedByKey().mapValues { $0.sortingKeys() })
        default: return self
        }
    }

    /// Depth-first, pre-order traversal of every value with its path.
    public func walk(_ body: (ValuePath, JSONValue) throws -> Void) rethrows {
        try walk(from: .root, body)
    }

    public func walk(from path: ValuePath, _ body: (ValuePath, JSONValue) throws -> Void) rethrows {
        try body(path, self)
        switch self {
        case .array(let a):
            for (i, element) in a.enumerated() { try element.walk(from: path.appending(.index(i)), body) }
        case .object(let o):
            for (key, value) in o.members { try value.walk(from: path.appending(.key(key)), body) }
        default: break
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(JSONNumber(value)) }
    public init(floatLiteral value: Double) { self = .number(JSONNumber(value)) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(JSONObject(elements)) }
}

// MARK: - Paths

public enum PathComponent: Hashable, Sendable, CustomStringConvertible {
    case key(String)
    case index(Int)

    public var description: String {
        switch self {
        case .key(let k): return k
        case .index(let i): return String(i)
        }
    }

    public var key: String? { if case .key(let k) = self { return k } else { return nil } }
    public var index: Int? { if case .index(let i) = self { return i } else { return nil } }
}

/// A location inside a JSON document (e.g. `$.users[2].name`).
public struct ValuePath: Hashable, Sendable, CustomStringConvertible {
    public var components: [PathComponent]

    public init(_ components: [PathComponent] = []) {
        self.components = components
    }

    public static let root = ValuePath()

    public var isRoot: Bool { components.isEmpty }
    public var count: Int { components.count }
    public var last: PathComponent? { components.last }
    public var parent: ValuePath? {
        guard !components.isEmpty else { return nil }
        return ValuePath(Array(components.dropLast()))
    }

    public func appending(_ component: PathComponent) -> ValuePath {
        ValuePath(components + [component])
    }

    public func appending(key: String) -> ValuePath { appending(.key(key)) }
    public func appending(index: Int) -> ValuePath { appending(.index(index)) }

    public func hasPrefix(_ other: ValuePath) -> Bool {
        guard other.components.count <= components.count else { return false }
        return Array(components.prefix(other.components.count)) == other.components
    }

    /// JSONPath-style rendering: `$.store.book[0]['odd key']`.
    public var jsonPathString: String {
        var out = "$"
        for component in components {
            switch component {
            case .index(let i):
                out += "[\(i)]"
            case .key(let k):
                if ValuePath.isBareIdentifier(k) {
                    out += ".\(k)"
                } else {
                    let escaped = k.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                    out += "['\(escaped)']"
                }
            }
        }
        return out
    }

    /// RFC 6901 JSON Pointer rendering: `/store/book/0`.
    public var jsonPointer: String {
        if components.isEmpty { return "" }
        return components.map { component -> String in
            switch component {
            case .index(let i): return "/\(i)"
            case .key(let k): return "/" + k.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
            }
        }.joined()
    }

    public var description: String { jsonPathString }

    /// Parses an RFC 6901 pointer (`/a/b/0`). Numeric tokens become indices only when
    /// resolved against a value; here they are kept as keys and resolved lazily.
    public static func fromJSONPointer(_ pointer: String) -> [String]? {
        if pointer.isEmpty { return [] }
        guard pointer.hasPrefix("/") else { return nil }
        return pointer.dropFirst().components(separatedBy: "/").map {
            $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        }
    }

    static func isBareIdentifier(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first else { return false }
        guard first == "_" || first.properties.isAlphabetic else { return false }
        return s.unicodeScalars.allSatisfy { $0 == "_" || $0.properties.isAlphabetic || ($0.properties.numericType != nil) }
    }
}

// MARK: - Path access & mutation

public enum JSONError: Error, LocalizedError, Equatable, Sendable {
    case pathNotFound(ValuePath)
    case notAnArray(ValuePath)
    case notAnObject(ValuePath)
    case indexOutOfRange(ValuePath, Int)
    case cannotRemoveRoot

    public var errorDescription: String? {
        switch self {
        case .pathNotFound(let p): return "No value at \(p.jsonPathString)"
        case .notAnArray(let p): return "\(p.jsonPathString) is not an array"
        case .notAnObject(let p): return "\(p.jsonPathString) is not an object"
        case .indexOutOfRange(let p, let i): return "Index \(i) is out of range at \(p.jsonPathString)"
        case .cannotRemoveRoot: return "The root value cannot be removed"
        }
    }
}

extension JSONValue {
    public subscript(path path: ValuePath) -> JSONValue? {
        value(at: path)
    }

    public func value(at path: ValuePath) -> JSONValue? {
        var current = self
        for component in path.components {
            switch (component, current) {
            case (.key(let k), .object(let o)):
                guard let next = o[k] else { return nil }
                current = next
            case (.index(let i), .array(let a)):
                guard a.indices.contains(i) else { return nil }
                current = a[i]
            default:
                return nil
            }
        }
        return current
    }

    /// Resolves a JSON Pointer token list, treating numeric tokens as indices when the
    /// container is an array.
    public func value(atPointerTokens tokens: [String]) -> (ValuePath, JSONValue)? {
        var current = self
        var path = ValuePath.root
        for token in tokens {
            switch current {
            case .object(let o):
                guard let next = o[token] else { return nil }
                current = next
                path = path.appending(.key(token))
            case .array(let a):
                guard let i = Int(token), a.indices.contains(i) else { return nil }
                current = a[i]
                path = path.appending(.index(i))
            default:
                return nil
            }
        }
        return (path, current)
    }

    /// Replaces the value at `path`. The parent container must exist; for objects a
    /// missing key is created, for arrays the index must be in range.
    public mutating func set(_ newValue: JSONValue, at path: ValuePath) throws {
        guard let component = path.last, let parentPath = path.parent else {
            self = newValue
            return
        }
        try update(at: parentPath) { parent in
            switch (component, parent) {
            case (.key(let k), .object(var o)):
                o[k] = newValue
                parent = .object(o)
            case (.index(let i), .array(var a)):
                guard a.indices.contains(i) else { throw JSONError.indexOutOfRange(parentPath, i) }
                a[i] = newValue
                parent = .array(a)
            case (.key, _):
                throw JSONError.notAnObject(parentPath)
            case (.index, _):
                throw JSONError.notAnArray(parentPath)
            }
        }
    }

    @discardableResult
    public mutating func remove(at path: ValuePath) throws -> JSONValue {
        guard let component = path.last, let parentPath = path.parent else { throw JSONError.cannotRemoveRoot }
        var removed: JSONValue?
        try update(at: parentPath) { parent in
            switch (component, parent) {
            case (.key(let k), .object(var o)):
                guard let r = o.removeValue(forKey: k) else { throw JSONError.pathNotFound(path) }
                removed = r
                parent = .object(o)
            case (.index(let i), .array(var a)):
                guard a.indices.contains(i) else { throw JSONError.indexOutOfRange(parentPath, i) }
                removed = a.remove(at: i)
                parent = .array(a)
            case (.key, _):
                throw JSONError.notAnObject(parentPath)
            case (.index, _):
                throw JSONError.notAnArray(parentPath)
            }
        }
        return removed!
    }

    /// Inserts into the array at `arrayPath`. A nil index appends.
    public mutating func insert(_ newValue: JSONValue, intoArrayAt arrayPath: ValuePath, at index: Int? = nil) throws {
        try update(at: arrayPath) { target in
            guard case .array(var a) = target else { throw JSONError.notAnArray(arrayPath) }
            let i = index ?? a.count
            guard (0...a.count).contains(i) else { throw JSONError.indexOutOfRange(arrayPath, i) }
            a.insert(newValue, at: i)
            target = .array(a)
        }
    }

    /// Inserts a member into the object at `objectPath`.
    public mutating func insert(_ newValue: JSONValue, forKey key: String, intoObjectAt objectPath: ValuePath, at index: Int? = nil) throws {
        try update(at: objectPath) { target in
            guard case .object(var o) = target else { throw JSONError.notAnObject(objectPath) }
            o.insert(newValue, forKey: key, at: index ?? o.count)
            target = .object(o)
        }
    }

    /// Renames the object key addressed by `path` (which must end in a key component).
    public mutating func renameKey(at path: ValuePath, to newKey: String) throws {
        guard case .key(let oldKey)? = path.last, let parentPath = path.parent else { throw JSONError.pathNotFound(path) }
        try update(at: parentPath) { parent in
            guard case .object(var o) = parent else { throw JSONError.notAnObject(parentPath) }
            guard o.contains(oldKey) else { throw JSONError.pathNotFound(path) }
            o.rename(oldKey, to: newKey)
            parent = .object(o)
        }
    }

    public mutating func update(at path: ValuePath, _ body: (inout JSONValue) throws -> Void) throws {
        try update(components: path.components[...], fullPath: path, body)
    }

    private mutating func update(components: ArraySlice<PathComponent>, fullPath: ValuePath, _ body: (inout JSONValue) throws -> Void) throws {
        guard let component = components.first else {
            try body(&self)
            return
        }
        let rest = components.dropFirst()
        switch (component, self) {
        case (.key(let k), .object(var o)):
            guard var child = o[k] else { throw JSONError.pathNotFound(fullPath) }
            try child.update(components: rest, fullPath: fullPath, body)
            o[k] = child
            self = .object(o)
        case (.index(let i), .array(var a)):
            guard a.indices.contains(i) else { throw JSONError.pathNotFound(fullPath) }
            var child = a[i]
            try child.update(components: rest, fullPath: fullPath, body)
            a[i] = child
            self = .array(a)
        default:
            throw JSONError.pathNotFound(fullPath)
        }
    }
}
