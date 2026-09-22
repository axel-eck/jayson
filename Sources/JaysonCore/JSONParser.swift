import Foundation

public struct JSONParseError: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    /// 1-based line number.
    public let line: Int
    /// 1-based column number (in UTF-8 bytes).
    public let column: Int
    /// 0-based byte offset.
    public let offset: Int

    public init(message: String, line: Int, column: Int, offset: Int) {
        self.message = message
        self.line = line
        self.column = column
        self.offset = offset
    }

    public var errorDescription: String? { "Line \(line), column \(column): \(message)" }
}

public struct JSONParseOptions: Sendable {
    /// Allow `// line` and `/* block */` comments.
    public var allowComments = false
    /// Allow a trailing comma before `]` or `}`.
    public var allowTrailingCommas = false
    /// Allow `'single quoted'` strings.
    public var allowSingleQuotes = false
    /// Allow unquoted object keys (`{foo: 1}`).
    public var allowUnquotedKeys = false
    /// Allow `NaN`, `Infinity`, `-Infinity`, leading `+`, leading `.5` and trailing `5.`.
    public var allowNonStandardNumbers = false

    public init() {}

    public static let strict = JSONParseOptions()

    public static var lenient: JSONParseOptions {
        var o = JSONParseOptions()
        o.allowComments = true
        o.allowTrailingCommas = true
        o.allowSingleQuotes = true
        o.allowUnquotedKeys = true
        o.allowNonStandardNumbers = true
        return o
    }
}

/// A recursive-descent JSON parser that preserves object key order and number literals.
public struct JSONParser {
    public static func parse(_ text: String, options: JSONParseOptions = .strict) throws -> JSONValue {
        var parser = JSONParser(bytes: Array(text.utf8), options: options)
        return try parser.parseDocument()
    }

    public static func parse(_ data: Data, options: JSONParseOptions = .strict) throws -> JSONValue {
        var parser = JSONParser(bytes: [UInt8](data), options: options)
        return try parser.parseDocument()
    }

    private let bytes: [UInt8]
    private let options: JSONParseOptions
    private var pos = 0
    private var depth = 0
    private let maxDepth = 512

    private init(bytes: [UInt8], options: JSONParseOptions) {
        self.bytes = bytes
        self.options = options
        // Skip UTF-8 BOM.
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { pos = 3 }
    }

    private mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        guard pos < bytes.count else { throw error("Empty document") }
        let value = try parseValue()
        skipWhitespace()
        if pos < bytes.count {
            throw error("Unexpected trailing content")
        }
        return value
    }

    // MARK: Values

    private mutating func parseValue() throws -> JSONValue {
        skipWhitespace()
        guard pos < bytes.count else { throw error("Unexpected end of input") }
        let c = bytes[pos]
        switch c {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString(quote: c))
        case UInt8(ascii: "'") where options.allowSingleQuotes: return .string(try parseString(quote: c))
        case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"): try expectLiteral("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "+"), UInt8(ascii: "."), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return try parseNumber()
        case UInt8(ascii: "N") where options.allowNonStandardNumbers,
             UInt8(ascii: "I") where options.allowNonStandardNumbers:
            return try parseNumber()
        default:
            throw error("Unexpected character '\(Character(UnicodeScalar(c)))'")
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        try enter()
        defer { depth -= 1 }
        pos += 1 // {
        var object = JSONObject()
        skipWhitespace()
        if peek() == UInt8(ascii: "}") { pos += 1; return .object(object) }
        while true {
            skipWhitespace()
            let key = try parseKey()
            skipWhitespace()
            guard peek() == UInt8(ascii: ":") else { throw error("Expected ':' after object key") }
            pos += 1
            let value = try parseValue()
            object[key] = value
            skipWhitespace()
            guard let c = peek() else { throw error("Unterminated object") }
            if c == UInt8(ascii: ",") {
                pos += 1
                skipWhitespace()
                if peek() == UInt8(ascii: "}") {
                    if options.allowTrailingCommas { pos += 1; return .object(object) }
                    throw error("Trailing comma in object")
                }
            } else if c == UInt8(ascii: "}") {
                pos += 1
                return .object(object)
            } else {
                throw error("Expected ',' or '}' in object")
            }
        }
    }

    private mutating func parseKey() throws -> String {
        guard let c = peek() else { throw error("Unterminated object") }
        if c == UInt8(ascii: "\"") || (c == UInt8(ascii: "'") && options.allowSingleQuotes) {
            return try parseString(quote: c)
        }
        if options.allowUnquotedKeys, isIdentifierStart(c) {
            let start = pos
            while pos < bytes.count, isIdentifierPart(bytes[pos]) { pos += 1 }
            return String(decoding: bytes[start..<pos], as: UTF8.self)
        }
        if c == UInt8(ascii: "}") { throw error("Trailing comma in object") }
        throw error("Expected string key in object")
    }

    private mutating func parseArray() throws -> JSONValue {
        try enter()
        defer { depth -= 1 }
        pos += 1 // [
        var array: [JSONValue] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "]") { pos += 1; return .array(array) }
        while true {
            array.append(try parseValue())
            skipWhitespace()
            guard let c = peek() else { throw error("Unterminated array") }
            if c == UInt8(ascii: ",") {
                pos += 1
                skipWhitespace()
                if peek() == UInt8(ascii: "]") {
                    if options.allowTrailingCommas { pos += 1; return .array(array) }
                    throw error("Trailing comma in array")
                }
            } else if c == UInt8(ascii: "]") {
                pos += 1
                return .array(array)
            } else {
                throw error("Expected ',' or ']' in array")
            }
        }
    }

    private mutating func parseString(quote: UInt8) throws -> String {
        let start = pos
        pos += 1 // opening quote
        var out = [UInt8]()
        out.reserveCapacity(16)
        while pos < bytes.count {
            let c = bytes[pos]
            if c == quote {
                pos += 1
                return String(decoding: out, as: UTF8.self)
            }
            if c == UInt8(ascii: "\\") {
                pos += 1
                guard pos < bytes.count else { break }
                let e = bytes[pos]
                pos += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "'"): out.append(0x27)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var scalarValue = try parseHex4()
                    if (0xD800...0xDBFF).contains(scalarValue) {
                        // High surrogate; expect a low surrogate.
                        if pos + 1 < bytes.count, bytes[pos] == UInt8(ascii: "\\"), bytes[pos + 1] == UInt8(ascii: "u") {
                            let save = pos
                            pos += 2
                            let low = try parseHex4()
                            if (0xDC00...0xDFFF).contains(low) {
                                scalarValue = 0x10000 + ((scalarValue - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                pos = save
                                scalarValue = 0xFFFD
                            }
                        } else {
                            scalarValue = 0xFFFD
                        }
                    } else if (0xDC00...0xDFFF).contains(scalarValue) {
                        scalarValue = 0xFFFD
                    }
                    let scalar = UnicodeScalar(scalarValue) ?? "\u{FFFD}"
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                case UInt8(ascii: "\n") where options.allowSingleQuotes:
                    // JSON5-style line continuation.
                    break
                default:
                    pos -= 1
                    throw error("Invalid escape sequence '\\\(Character(UnicodeScalar(e)))'")
                }
                continue
            }
            if c < 0x20 {
                if c == 0x0A || c == 0x0D {
                    throw error("Unterminated string (newline inside string)")
                }
                throw error("Control character in string")
            }
            out.append(c)
            pos += 1
        }
        pos = start
        throw error("Unterminated string")
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard pos + 4 <= bytes.count else { throw error("Incomplete unicode escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let c = bytes[pos]
            let digit: UInt32
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(c - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(c - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(c - UInt8(ascii: "A") + 10)
            default: throw error("Invalid unicode escape")
            }
            value = value * 16 + digit
            pos += 1
        }
        return value
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = pos
        if options.allowNonStandardNumbers {
            var sign = ""
            if peek() == UInt8(ascii: "-") || peek() == UInt8(ascii: "+") {
                sign = peek() == UInt8(ascii: "-") ? "-" : ""
                pos += 1
            }
            if matchesLiteral("NaN") {
                pos += 3
                return .number(JSONNumber(literal: "NaN"))
            }
            if matchesLiteral("Infinity") {
                pos += 8
                return .number(JSONNumber(literal: sign + "Infinity"))
            }
            pos = start
        }

        if peek() == UInt8(ascii: "-") {
            pos += 1
        } else if peek() == UInt8(ascii: "+") {
            guard options.allowNonStandardNumbers else { throw error("Unexpected '+'") }
            pos += 1
        }

        var sawDigits = false
        if peek() == UInt8(ascii: "0") {
            pos += 1
            sawDigits = true
            if let c = peek(), isDigit(c) {
                throw error("Leading zeros are not allowed")
            }
        } else {
            while let c = peek(), isDigit(c) { pos += 1; sawDigits = true }
        }

        if peek() == UInt8(ascii: ".") {
            pos += 1
            var fracDigits = false
            while let c = peek(), isDigit(c) { pos += 1; fracDigits = true }
            if !fracDigits && !options.allowNonStandardNumbers {
                throw error("Expected digits after decimal point")
            }
            if !sawDigits && !fracDigits { throw error("Invalid number") }
            sawDigits = sawDigits || fracDigits
        }

        guard sawDigits else { throw error("Invalid number") }

        if let c = peek(), c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
            pos += 1
            if let s = peek(), s == UInt8(ascii: "+") || s == UInt8(ascii: "-") { pos += 1 }
            var expDigits = false
            while let c = peek(), isDigit(c) { pos += 1; expDigits = true }
            guard expDigits else { throw error("Expected digits in exponent") }
        }

        var literal = String(decoding: bytes[start..<pos], as: UTF8.self)
        if literal.hasPrefix("+") { literal.removeFirst() }
        if literal.hasPrefix(".") { literal = "0" + literal }
        if literal.hasPrefix("-.") { literal = "-0" + literal.dropFirst() }
        if literal.hasSuffix(".") { literal += "0" }
        return .number(JSONNumber(literal: literal))
    }

    // MARK: Helpers

    private mutating func enter() throws {
        depth += 1
        if depth > maxDepth { throw error("Nesting too deep") }
    }

    private func peek() -> UInt8? {
        pos < bytes.count ? bytes[pos] : nil
    }

    private func isDigit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }

    private func isIdentifierStart(_ c: UInt8) -> Bool {
        (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z")) || c == UInt8(ascii: "_") || c == UInt8(ascii: "$") || c >= 0x80
    }

    private func isIdentifierPart(_ c: UInt8) -> Bool { isIdentifierStart(c) || isDigit(c) }

    private func matchesLiteral(_ literal: String) -> Bool {
        let l = Array(literal.utf8)
        guard pos + l.count <= bytes.count else { return false }
        return Array(bytes[pos..<pos + l.count]) == l
    }

    private mutating func expectLiteral(_ literal: String) throws {
        guard matchesLiteral(literal) else { throw error("Unexpected token") }
        pos += literal.utf8.count
        if let c = peek(), isIdentifierPart(c) { throw error("Unexpected token") }
    }

    private mutating func skipWhitespace() {
        while pos < bytes.count {
            let c = bytes[pos]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                pos += 1
            } else if options.allowComments, c == UInt8(ascii: "/"), pos + 1 < bytes.count {
                let n = bytes[pos + 1]
                if n == UInt8(ascii: "/") {
                    pos += 2
                    while pos < bytes.count, bytes[pos] != 0x0A { pos += 1 }
                } else if n == UInt8(ascii: "*") {
                    pos += 2
                    while pos + 1 < bytes.count, !(bytes[pos] == UInt8(ascii: "*") && bytes[pos + 1] == UInt8(ascii: "/")) { pos += 1 }
                    pos = min(pos + 2, bytes.count)
                } else {
                    return
                }
            } else if c == 0xC2, pos + 1 < bytes.count, bytes[pos + 1] == 0xA0 {
                pos += 2 // non-breaking space, common in pasted text
            } else if c == 0xE2, pos + 2 < bytes.count, bytes[pos + 1] == 0x80, (bytes[pos + 2] == 0xA8 || bytes[pos + 2] == 0xA9) {
                pos += 3 // line/paragraph separator
            } else {
                return
            }
        }
    }

    private func error(_ message: String) -> JSONParseError {
        var line = 1
        var column = 1
        var i = 0
        let end = min(pos, bytes.count)
        while i < end {
            if bytes[i] == 0x0A { line += 1; column = 1 } else { column += 1 }
            i += 1
        }
        return JSONParseError(message: message, line: line, column: column, offset: end)
    }
}
