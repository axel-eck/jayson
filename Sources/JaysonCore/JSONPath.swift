import Foundation

// MARK: - Public API

/// A single result of a JSONPath query: the matched value together with its location
/// in the document, so a tree view can highlight the node.
public struct JSONPathMatch: Hashable {
    /// Location of the matched value inside the queried document.
    public let path: ValuePath
    /// The matched value.
    public let value: JSONValue

    public init(path: ValuePath, value: JSONValue) {
        self.path = path
        self.value = value
    }
}

/// A syntax error in a JSONPath expression.
public struct JSONPathError: Error, LocalizedError, Equatable {
    /// Human readable description of the problem, e.g. `Unexpected ']'`.
    public let message: String
    /// Character offset (0-based) in the expression where the problem was detected.
    public let position: Int

    public init(message: String, position: Int) {
        self.message = message
        self.position = position
    }

    /// The message with its position appended, e.g. `Unexpected ']' at position 7`.
    public var errorDescription: String? { "\(message) at position \(position)" }
}

/// A parsed JSONPath expression (Goessner / RFC 9535 style) that can be evaluated against
/// any `JSONValue`.
///
/// Supported syntax: `$` root (optional: `store.book[0]` means `$.store.book[0]`), child
/// access with `.name`, `['name']`, `["name"]`, wildcards `.*` and `[*]`, indices including
/// negatives, unions `[0,2]` / `['a','b']`, Python-style slices `[start:end:step]`, recursive
/// descent `..name` / `..[*]` / `..*` / `..[?(...)]`, filters `[?(@.price < 10)]` (parentheses
/// optional) with `== != < <= > >=`, `=~ /regex/flags`, `&& || !` and grouping, and a virtual
/// `.length` on arrays and strings.
public struct JSONPathQuery: Hashable, CustomStringConvertible {
    /// The original expression text.
    public let expression: String
    let segments: [JSONPathSegment]

    /// Parses `expression`, throwing a `JSONPathError` that points at the offending position
    /// when it is malformed.
    public init(_ expression: String) throws {
        self.expression = expression
        var parser = JSONPathParser(expression)
        self.segments = try parser.parseQuery()
    }

    /// Evaluates the query against `root`. Results are in document order (a union in a child
    /// segment, such as `['b','a']`, keeps the order it was written in) and are de-duplicated by
    /// path. Never throws or traps, whatever the document looks like.
    public func evaluate(_ root: JSONValue) -> [JSONPathMatch] {
        JSONPathEvaluator.evaluate(segments: segments, on: root)
    }

    /// Parses and evaluates `expression` against `root` in one step.
    public static func evaluate(_ expression: String, on root: JSONValue) throws -> [JSONPathMatch] {
        try JSONPathQuery(expression).evaluate(root)
    }

    public var description: String { expression }

    public static func == (lhs: JSONPathQuery, rhs: JSONPathQuery) -> Bool { lhs.expression == rhs.expression }
    public func hash(into hasher: inout Hasher) { hasher.combine(expression) }
}

// MARK: - Syntax tree

enum JSONPathSegment {
    /// Applies the selectors to each input node.
    case child([JSONPathSelector])
    /// Applies the selectors to each input node and every descendant of it.
    case descendant([JSONPathSelector])
}

indirect enum JSONPathSelector {
    case name(String)
    case wildcard
    case index(Int)
    case slice(start: Int?, end: Int?, step: Int?)
    case filter(JSONPathFilterExpression)
}

indirect enum JSONPathFilterExpression {
    case literal(JSONValue)
    /// A path relative to the node being tested (`@...`).
    case currentPath([JSONPathSegment])
    /// A path relative to the document root (`$...`).
    case rootPath([JSONPathSegment])
    case comparison(JSONPathFilterExpression, JSONPathComparisonOperator, JSONPathFilterExpression)
    case regexMatch(JSONPathFilterExpression, NSRegularExpression)
    case and(JSONPathFilterExpression, JSONPathFilterExpression)
    case or(JSONPathFilterExpression, JSONPathFilterExpression)
    case not(JSONPathFilterExpression)
}

enum JSONPathComparisonOperator {
    case equal, notEqual, less, lessOrEqual, greater, greaterOrEqual
}

// MARK: - Parser

struct JSONPathParser {
    private let chars: [Character]
    private var pos = 0
    private var parenDepth = 0
    private let maxParenDepth = 64

    init(_ expression: String) {
        chars = Array(expression)
    }

    // MARK: Cursor helpers

    private var atEnd: Bool { pos >= chars.count }
    private var current: Character? { pos < chars.count ? chars[pos] : nil }

    private func peek(_ offset: Int = 1) -> Character? {
        let i = pos + offset
        return i < chars.count ? chars[i] : nil
    }

    private mutating func advance(_ n: Int = 1) { pos = min(pos + n, chars.count) }

    private mutating func skipWhitespace() {
        while let c = current, c.isWhitespace { pos += 1 }
    }

    private func error(_ message: String, at position: Int? = nil) -> JSONPathError {
        JSONPathError(message: message, position: position ?? pos)
    }

    private func unexpected() -> JSONPathError {
        if let c = current { return error("Unexpected '\(c)'") }
        return error("Unexpected end of expression")
    }

    private static func isNameCharacter(_ c: Character) -> Bool {
        if c.isASCII { return c.isLetter || c.isNumber || c == "_" || c == "-" }
        return !c.isWhitespace
    }

    // MARK: Query

    mutating func parseQuery() throws -> [JSONPathSegment] {
        skipWhitespace()
        guard !atEnd else { throw error("Empty expression", at: 0) }
        var segments: [JSONPathSegment] = []
        if current == "$" {
            advance()
        } else if current != "." && current != "[" {
            // Bare `store.book[0]` is treated as `$.store.book[0]`.
            segments.append(.child([try parseDotSelector()]))
        }
        try parseSegments(into: &segments)
        skipWhitespace()
        if !atEnd { throw unexpected() }
        return segments
    }

    /// Parses zero or more segments (`.name`, `..name`, `[...]`, `..[...]`) and stops at the
    /// first character that cannot start a segment.
    private mutating func parseSegments(into segments: inout [JSONPathSegment]) throws {
        while true {
            let save = pos
            skipWhitespace()
            guard let c = current else { pos = save; return }
            if c == "." {
                if peek() == "." {
                    advance(2)
                    if current == "[" {
                        segments.append(.descendant(try parseBracket()))
                    } else {
                        segments.append(.descendant([try parseDotSelector()]))
                    }
                } else {
                    advance()
                    segments.append(.child([try parseDotSelector()]))
                }
            } else if c == "[" {
                segments.append(.child(try parseBracket()))
            } else {
                pos = save
                return
            }
        }
    }

    /// Parses the `name` or `*` that follows a `.` or `..`.
    private mutating func parseDotSelector() throws -> JSONPathSelector {
        if current == "*" {
            advance()
            return .wildcard
        }
        let start = pos
        while let c = current, JSONPathParser.isNameCharacter(c) { advance() }
        guard pos > start else { throw unexpected() }
        return .name(String(chars[start..<pos]))
    }

    /// Parses `[selector, selector, ...]`; `current` must be `[`.
    private mutating func parseBracket() throws -> [JSONPathSelector] {
        let open = pos
        advance()
        var selectors: [JSONPathSelector] = []
        while true {
            skipWhitespace()
            selectors.append(try parseBracketSelector())
            skipWhitespace()
            guard let c = current else { throw error("Expected ']' to close '[' at position \(open)") }
            if c == "," {
                advance()
                continue
            }
            if c == "]" {
                advance()
                return selectors
            }
            throw unexpected()
        }
    }

    private mutating func parseBracketSelector() throws -> JSONPathSelector {
        guard let c = current else { throw unexpected() }
        switch c {
        case "*":
            advance()
            return .wildcard
        case "'", "\"":
            return .name(try parseStringLiteral())
        case "?":
            advance()
            return .filter(try parseFilterExpression())
        case "-", ":", "0"..."9":
            return try parseIndexOrSlice()
        default:
            throw unexpected()
        }
    }

    private mutating func parseIndexOrSlice() throws -> JSONPathSelector {
        let start = try parseOptionalInteger()
        skipWhitespace()
        guard current == ":" else {
            guard let start else { throw unexpected() }
            return .index(start)
        }
        advance()
        skipWhitespace()
        let end = try parseOptionalInteger()
        skipWhitespace()
        var step: Int?
        if current == ":" {
            advance()
            skipWhitespace()
            step = try parseOptionalInteger()
        }
        return .slice(start: start, end: end, step: step)
    }

    private mutating func parseOptionalInteger() throws -> Int? {
        let start = pos
        if current == "-" { advance() }
        while let c = current, c.isASCII, c.isNumber { advance() }
        guard pos > start else { return nil }
        let text = String(chars[start..<pos])
        guard let value = Int(text) else { throw error("Invalid integer '\(text)'", at: start) }
        return value
    }

    // MARK: Filters

    private mutating func parseFilterExpression() throws -> JSONPathFilterExpression {
        skipWhitespace()
        return try parseOr()
    }

    private mutating func parseOr() throws -> JSONPathFilterExpression {
        var left = try parseAnd()
        while true {
            skipWhitespace()
            guard current == "|", peek() == "|" else { return left }
            advance(2)
            let right = try parseAnd()
            left = .or(left, right)
        }
    }

    private mutating func parseAnd() throws -> JSONPathFilterExpression {
        var left = try parseUnary()
        while true {
            skipWhitespace()
            guard current == "&", peek() == "&" else { return left }
            advance(2)
            let right = try parseUnary()
            left = .and(left, right)
        }
    }

    private mutating func parseUnary() throws -> JSONPathFilterExpression {
        skipWhitespace()
        if current == "!", peek() != "=" {
            advance()
            return .not(try parseUnary())
        }
        return try parseComparison()
    }

    private mutating func parseComparison() throws -> JSONPathFilterExpression {
        let left = try parseOperand()
        skipWhitespace()
        if let op = parseComparisonOperator() {
            let right = try parseOperand()
            return .comparison(left, op, right)
        }
        if current == "=", peek() == "~" {
            advance(2)
            skipWhitespace()
            return .regexMatch(left, try parseRegexLiteral())
        }
        return left
    }

    private mutating func parseComparisonOperator() -> JSONPathComparisonOperator? {
        guard let c = current else { return nil }
        switch (c, peek()) {
        case ("=", "="): advance(2); return .equal
        case ("!", "="): advance(2); return .notEqual
        case ("<", "="): advance(2); return .lessOrEqual
        case (">", "="): advance(2); return .greaterOrEqual
        case ("<", _): advance(); return .less
        case (">", _): advance(); return .greater
        default: return nil
        }
    }

    private mutating func parseOperand() throws -> JSONPathFilterExpression {
        skipWhitespace()
        guard let c = current else { throw unexpected() }
        switch c {
        case "(":
            let open = pos
            parenDepth += 1
            defer { parenDepth -= 1 }
            guard parenDepth <= maxParenDepth else { throw error("Expression is nested too deeply") }
            advance()
            let inner = try parseOr()
            skipWhitespace()
            guard current == ")" else {
                if atEnd { throw error("Expected ')' to close '(' at position \(open)") }
                throw unexpected()
            }
            advance()
            return inner
        case "@":
            advance()
            var segments: [JSONPathSegment] = []
            try parseSegments(into: &segments)
            return .currentPath(segments)
        case "$":
            advance()
            var segments: [JSONPathSegment] = []
            try parseSegments(into: &segments)
            return .rootPath(segments)
        case "'", "\"":
            return .literal(.string(try parseStringLiteral()))
        case "-", "0"..."9":
            return .literal(.number(try parseNumberLiteral()))
        default:
            if c.isLetter {
                let start = pos
                while let c = current, c.isLetter { advance() }
                let word = String(chars[start..<pos])
                switch word {
                case "true": return .literal(.bool(true))
                case "false": return .literal(.bool(false))
                case "null": return .literal(.null)
                default: throw error("Unknown identifier '\(word)'", at: start)
                }
            }
            throw unexpected()
        }
    }

    private mutating func parseNumberLiteral() throws -> JSONNumber {
        let start = pos
        if current == "-" { advance() }
        while let c = current, c.isASCII, c.isNumber { advance() }
        if current == ".", let next = peek(), next.isASCII, next.isNumber {
            advance()
            while let c = current, c.isASCII, c.isNumber { advance() }
        }
        if current == "e" || current == "E" {
            advance()
            if current == "+" || current == "-" { advance() }
            while let c = current, c.isASCII, c.isNumber { advance() }
        }
        let text = String(chars[start..<pos])
        guard let value = Double(text), value.isFinite else { throw error("Invalid number '\(text)'", at: start) }
        return JSONNumber(literal: text)
    }

    // MARK: Literals

    /// Parses a single- or double-quoted string with backslash escapes; `current` must be the
    /// opening quote.
    private mutating func parseStringLiteral() throws -> String {
        guard let quote = current else { throw unexpected() }
        let start = pos
        advance()
        var out = ""
        while let c = current {
            if c == quote {
                advance()
                return out
            }
            guard c == "\\" else {
                out.append(c)
                advance()
                continue
            }
            let escapeStart = pos
            advance()
            guard let e = current else { break }
            switch e {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "b": out.append("\u{8}")
            case "f": out.append("\u{c}")
            case "0": out.append("\u{0}")
            case "\\", "/", "'", "\"": out.append(e)
            case "u":
                advance()
                let scalar = try parseUnicodeEscape(escapeStart: escapeStart)
                out.unicodeScalars.append(scalar)
                continue
            default:
                throw error("Invalid escape sequence '\\\(e)'", at: escapeStart)
            }
            advance()
        }
        throw error("Unterminated string literal", at: start)
    }

    /// Parses the four hex digits after `\u` (and a following low surrogate escape if present).
    private mutating func parseUnicodeEscape(escapeStart: Int) throws -> Unicode.Scalar {
        func hex4() -> UInt32? {
            guard pos + 4 <= chars.count else { return nil }
            let digits = String(chars[pos..<(pos + 4)])
            guard digits.allSatisfy({ $0.isASCII && $0.isHexDigit }), let value = UInt32(digits, radix: 16) else { return nil }
            return value
        }
        guard let first = hex4() else { throw error("Invalid unicode escape", at: escapeStart) }
        advance(4)
        if (0xD800...0xDBFF).contains(first) {
            if current == "\\", peek() == "u" {
                let save = pos
                advance(2)
                if let second = hex4(), (0xDC00...0xDFFF).contains(second) {
                    advance(4)
                    let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                    return Unicode.Scalar(combined) ?? "\u{FFFD}"
                }
                pos = save
            }
            return "\u{FFFD}"
        }
        return Unicode.Scalar(first) ?? "\u{FFFD}"
    }

    /// Parses `/pattern/flags` (or a quoted string used as a pattern).
    private mutating func parseRegexLiteral() throws -> NSRegularExpression {
        let start = pos
        var pattern = ""
        var options: NSRegularExpression.Options = []
        if current == "'" || current == "\"" {
            pattern = try parseStringLiteral()
        } else {
            guard current == "/" else {
                if atEnd { throw error("Expected a regular expression") }
                throw unexpected()
            }
            advance()
            var closed = false
            while let c = current {
                if c == "/" {
                    advance()
                    closed = true
                    break
                }
                if c == "\\", let next = peek() {
                    if next != "/" { pattern.append("\\") }
                    pattern.append(next)
                    advance(2)
                    continue
                }
                pattern.append(c)
                advance()
            }
            guard closed else { throw error("Unterminated regular expression", at: start) }
            while let c = current, c.isLetter {
                switch c {
                case "i": options.insert(.caseInsensitive)
                case "m": options.insert(.anchorsMatchLines)
                case "s": options.insert(.dotMatchesLineSeparators)
                case "x": options.insert(.allowCommentsAndWhitespace)
                default: throw error("Unknown regular expression flag '\(c)'")
                }
                advance()
            }
        }
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            throw self.error("Invalid regular expression", at: start)
        }
    }
}

// MARK: - Evaluator

enum JSONPathEvaluator {
    typealias Node = (path: ValuePath, value: JSONValue)

    static func evaluate(segments: [JSONPathSegment], on root: JSONValue) -> [JSONPathMatch] {
        let nodes = apply(segments, to: [(ValuePath.root, root)], root: root)
        var seen = Set<ValuePath>()
        var results: [JSONPathMatch] = []
        results.reserveCapacity(nodes.count)
        for node in nodes where seen.insert(node.path).inserted {
            results.append(JSONPathMatch(path: node.path, value: node.value))
        }
        return results
    }

    static func apply(_ segments: [JSONPathSegment], to input: [Node], root: JSONValue) -> [Node] {
        var current = input
        for segment in segments {
            var next: [Node] = []
            switch segment {
            case .child(let selectors):
                for node in current {
                    select(selectors, at: node.path, value: node.value, root: root, into: &next)
                }
            case .descendant(let selectors):
                for node in current {
                    descend(selectors, at: node.path, value: node.value, root: root, into: &next)
                }
                // Overlapping subtrees (e.g. `$..a..a`) can yield the same node twice; drop the
                // repeats early so later segments do not multiply the work.
                if current.count > 1 { next = deduplicated(next) }
            }
            current = next
            if current.isEmpty { break }
        }
        return current
    }

    /// Descendant segment: every node below `value` (at any depth) that one of the selectors,
    /// applied to its parent, would select. Emitting a node as soon as it is visited keeps the
    /// results in strict document order.
    private static func descend(_ selectors: [JSONPathSelector], at path: ValuePath, value: JSONValue, root: JSONValue, into out: inout [Node]) {
        switch value {
        case .array(let array):
            let mask = indexMask(selectors, count: array.count)
            for (i, element) in array.enumerated() {
                let childPath = path.appending(.index(i))
                if mask[i] || selectors.contains(where: { filterSelects($0, element, root: root) }) {
                    out.append((childPath, element))
                }
                descend(selectors, at: childPath, value: element, root: root, into: &out)
            }
        case .object(let object):
            for (key, member) in object.members {
                let childPath = path.appending(.key(key))
                let selected = selectors.contains { selector in
                    switch selector {
                    case .name(let name): return name == key
                    case .wildcard: return true
                    case .filter: return filterSelects(selector, member, root: root)
                    case .index, .slice: return false
                    }
                }
                if selected { out.append((childPath, member)) }
                descend(selectors, at: childPath, value: member, root: root, into: &out)
            }
        default:
            break
        }
    }

    /// Which elements of an array with `count` elements the index, slice and wildcard
    /// selectors pick.
    private static func indexMask(_ selectors: [JSONPathSelector], count: Int) -> [Bool] {
        var mask = [Bool](repeating: false, count: count)
        for selector in selectors {
            switch selector {
            case .wildcard:
                return [Bool](repeating: true, count: count)
            case .index(let index):
                let normalized = index < 0 ? count + index : index
                if mask.indices.contains(normalized) { mask[normalized] = true }
            case .slice(let start, let end, let step):
                for i in sliceIndices(start: start, end: end, step: step, count: count) { mask[i] = true }
            case .name, .filter:
                break
            }
        }
        return mask
    }

    private static func filterSelects(_ selector: JSONPathSelector, _ value: JSONValue, root: JSONValue) -> Bool {
        guard case .filter(let expression) = selector else { return false }
        return isTruthy(expression, current: value, root: root)
    }

    private static func deduplicated(_ nodes: [Node]) -> [Node] {
        var seen = Set<ValuePath>()
        return nodes.filter { seen.insert($0.path).inserted }
    }

    private static func select(_ selectors: [JSONPathSelector], at path: ValuePath, value: JSONValue, root: JSONValue, into out: inout [Node]) {
        for selector in selectors {
            switch selector {
            case .name(let name):
                if case .object(let object) = value, let child = object[name] {
                    out.append((path.appending(.key(name)), child))
                } else if name == "length" {
                    switch value {
                    case .array(let array): out.append((path.appending(.key(name)), .number(array.count)))
                    case .string(let string): out.append((path.appending(.key(name)), .number(string.count)))
                    default: break
                    }
                }
            case .wildcard:
                appendChildren(of: value, at: path, into: &out) { _ in true }
            case .index(let index):
                guard case .array(let array) = value else { continue }
                let normalized = index < 0 ? array.count + index : index
                if array.indices.contains(normalized) {
                    out.append((path.appending(.index(normalized)), array[normalized]))
                }
            case .slice(let start, let end, let step):
                guard case .array(let array) = value else { continue }
                for i in sliceIndices(start: start, end: end, step: step, count: array.count) {
                    out.append((path.appending(.index(i)), array[i]))
                }
            case .filter(let expression):
                appendChildren(of: value, at: path, into: &out) { child in
                    isTruthy(expression, current: child, root: root)
                }
            }
        }
    }

    private static func appendChildren(of value: JSONValue, at path: ValuePath, into out: inout [Node], where include: (JSONValue) -> Bool) {
        switch value {
        case .array(let array):
            for (i, element) in array.enumerated() where include(element) {
                out.append((path.appending(.index(i)), element))
            }
        case .object(let object):
            for (key, member) in object.members where include(member) {
                out.append((path.appending(.key(key)), member))
            }
        default:
            break
        }
    }

    /// Python / RFC 9535 slice semantics.
    static func sliceIndices(start: Int?, end: Int?, step: Int?, count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let rawStep = step ?? 1
        guard rawStep != 0 else { return [] }
        // Clamping the step keeps the arithmetic below free of overflow without changing results.
        let step = max(min(rawStep, count + 1), -(count + 1))
        func normalize(_ i: Int) -> Int { i < 0 ? count + i : i }
        var indices: [Int] = []
        if step > 0 {
            let lower = min(max(normalize(start ?? 0), 0), count)
            let upper = min(max(normalize(end ?? count), 0), count)
            var i = lower
            while i < upper {
                indices.append(i)
                i += step
            }
        } else {
            let upper = start.map { min(max(normalize($0), -1), count - 1) } ?? (count - 1)
            let lower = end.map { min(max(normalize($0), -1), count - 1) } ?? -1
            var i = upper
            while i > lower {
                indices.append(i)
                i += step
            }
        }
        return indices
    }

    // MARK: Filter evaluation

    private enum Operand {
        case nothing
        case single(JSONValue)
        case multiple([JSONValue])

        var values: [JSONValue] {
            switch self {
            case .nothing: return []
            case .single(let v): return [v]
            case .multiple(let vs): return vs
            }
        }
    }

    private static func isTruthy(_ expression: JSONPathFilterExpression, current: JSONValue, root: JSONValue) -> Bool {
        switch expression {
        case .literal(let value):
            switch value {
            case .bool(let b): return b
            case .null: return false
            default: return true
            }
        case .currentPath(let segments):
            return !apply(segments, to: [(ValuePath.root, current)], root: root).isEmpty
        case .rootPath(let segments):
            return !apply(segments, to: [(ValuePath.root, root)], root: root).isEmpty
        case .comparison(let lhs, let op, let rhs):
            return compare(operand(lhs, current: current, root: root), op, operand(rhs, current: current, root: root))
        case .regexMatch(let lhs, let regex):
            return operand(lhs, current: current, root: root).values.contains { value in
                guard case .string(let string) = value else { return false }
                return regex.firstMatch(in: string, options: [], range: NSRange(string.startIndex..., in: string)) != nil
            }
        case .and(let lhs, let rhs):
            return isTruthy(lhs, current: current, root: root) && isTruthy(rhs, current: current, root: root)
        case .or(let lhs, let rhs):
            return isTruthy(lhs, current: current, root: root) || isTruthy(rhs, current: current, root: root)
        case .not(let inner):
            return !isTruthy(inner, current: current, root: root)
        }
    }

    private static func operand(_ expression: JSONPathFilterExpression, current: JSONValue, root: JSONValue) -> Operand {
        switch expression {
        case .literal(let value):
            return .single(value)
        case .currentPath(let segments):
            return pathOperand(segments, base: current, root: root)
        case .rootPath(let segments):
            return pathOperand(segments, base: root, root: root)
        default:
            return .single(.bool(isTruthy(expression, current: current, root: root)))
        }
    }

    private static func pathOperand(_ segments: [JSONPathSegment], base: JSONValue, root: JSONValue) -> Operand {
        let nodes = apply(segments, to: [(ValuePath.root, base)], root: root)
        if isSingular(segments) {
            return nodes.first.map { .single($0.value) } ?? .nothing
        }
        return .multiple(nodes.map(\.value))
    }

    /// True when the path can address at most one node (only plain names and indices).
    private static func isSingular(_ segments: [JSONPathSegment]) -> Bool {
        segments.allSatisfy { segment in
            guard case .child(let selectors) = segment, selectors.count == 1 else { return false }
            switch selectors[0] {
            case .name, .index: return true
            default: return false
            }
        }
    }

    private static func compare(_ lhs: Operand, _ op: JSONPathComparisonOperator, _ rhs: Operand) -> Bool {
        switch (lhs, rhs) {
        case (.multiple, _), (_, .multiple):
            // "Any match" semantics for operands that address several nodes.
            let left = lhs.values, right = rhs.values
            for a in left {
                for b in right where compareValues(a, op, b) { return true }
            }
            return false
        case (.nothing, .nothing):
            return op == .equal || op == .lessOrEqual || op == .greaterOrEqual
        case (.nothing, _), (_, .nothing):
            return op == .notEqual
        case (.single(let a), .single(let b)):
            return compareValues(a, op, b)
        }
    }

    private static func compareValues(_ a: JSONValue, _ op: JSONPathComparisonOperator, _ b: JSONValue) -> Bool {
        switch op {
        case .equal: return a.isJSONEqual(to: b)
        case .notEqual: return !a.isJSONEqual(to: b)
        case .less: return isLess(a, b)
        case .greater: return isLess(b, a)
        case .lessOrEqual: return isLess(a, b) || a.isJSONEqual(to: b)
        case .greaterOrEqual: return isLess(b, a) || a.isJSONEqual(to: b)
        }
    }

    /// Ordering is defined for number/number and string/string only; anything else is false.
    private static func isLess(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.number(let x), .number(let y)): return x.doubleValue < y.doubleValue
        case (.string(let x), .string(let y)): return x < y
        default: return false
        }
    }
}
