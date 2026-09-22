import Foundation

public struct JSONFormatOptions: Sendable, Equatable {
    public enum Indent: Sendable, Equatable {
        case spaces(Int)
        case tab

        var string: String {
            switch self {
            case .spaces(let n): return String(repeating: " ", count: n)
            case .tab: return "\t"
            }
        }
    }

    public var indent: Indent = .spaces(2)
    public var sortKeys = false
    /// Escape `/` as `\/` (some legacy consumers expect it).
    public var escapeSlashes = false
    /// Escape all non-ASCII characters as `\uXXXX`.
    public var asciiOnly = false

    public init(indent: Indent = .spaces(2), sortKeys: Bool = false) {
        self.indent = indent
        self.sortKeys = sortKeys
    }

    public static let pretty = JSONFormatOptions()
}

public enum JSONFormatter {
    /// Pretty-prints a value with newlines and indentation.
    public static func format(_ value: JSONValue, options: JSONFormatOptions = .pretty) -> String {
        var out = ""
        out.reserveCapacity(1024)
        write(options.sortKeys ? value.sortingKeys() : value, to: &out, depth: 0, options: options, pretty: true)
        return out
    }

    /// Minified single-line output.
    public static func minify(_ value: JSONValue, sortKeys: Bool = false) -> String {
        var out = ""
        var options = JSONFormatOptions()
        options.sortKeys = sortKeys
        write(sortKeys ? value.sortingKeys() : value, to: &out, depth: 0, options: options, pretty: false)
        return out
    }

    /// A short single-line preview for tree rows and lists (`{3 keys}`, `[12]`, `"abc…"`).
    public static func preview(_ value: JSONValue, maxLength: Int = 80) -> String {
        switch value {
        case .object(let o):
            return o.isEmpty ? "{}" : "{ \(o.count) \(o.count == 1 ? "key" : "keys") }"
        case .array(let a):
            return a.isEmpty ? "[]" : "[ \(a.count) \(a.count == 1 ? "item" : "items") ]"
        default:
            let s = minify(value)
            if s.count > maxLength {
                return String(s.prefix(maxLength - 1)) + "…"
            }
            return s
        }
    }

    public static func escape(_ string: String, options: JSONFormatOptions = .pretty) -> String {
        var out = "\""
        escape(string, into: &out, options: options)
        out += "\""
        return out
    }

    private static func write(_ value: JSONValue, to out: inout String, depth: Int, options: JSONFormatOptions, pretty: Bool) {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += numberLiteral(n)
        case .string(let s):
            out += "\""
            escape(s, into: &out, options: options)
            out += "\""
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            out += "["
            for (i, element) in a.enumerated() {
                if i > 0 { out += "," }
                if pretty { newline(&out, depth: depth + 1, options: options) }
                write(element, to: &out, depth: depth + 1, options: options, pretty: pretty)
            }
            if pretty { newline(&out, depth: depth, options: options) }
            out += "]"
        case .object(let o):
            if o.isEmpty { out += "{}"; return }
            out += "{"
            for (i, member) in o.members.enumerated() {
                if i > 0 { out += "," }
                if pretty { newline(&out, depth: depth + 1, options: options) }
                out += "\""
                escape(member.key, into: &out, options: options)
                out += pretty ? "\": " : "\":"
                write(member.value, to: &out, depth: depth + 1, options: options, pretty: pretty)
            }
            if pretty { newline(&out, depth: depth, options: options) }
            out += "}"
        }
    }

    private static func numberLiteral(_ n: JSONNumber) -> String {
        // Non-finite numbers are not valid JSON; emit null like JSON.stringify does.
        if !n.doubleValue.isFinite, Double(n.literal) == nil || !n.doubleValue.isFinite {
            if n.literal == "NaN" || n.literal.hasSuffix("Infinity") { return "null" }
        }
        return n.literal
    }

    private static func newline(_ out: inout String, depth: Int, options: JSONFormatOptions) {
        out += "\n"
        for _ in 0..<depth { out += options.indent.string }
    }

    private static let hex = Array("0123456789abcdef")

    private static func escape(_ string: String, into out: inout String, options: JSONFormatOptions) {
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "/" where options.escapeSlashes: out += "\\/"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    appendUnicodeEscape(scalar.value, to: &out)
                } else if options.asciiOnly && scalar.value > 0x7E {
                    if scalar.value > 0xFFFF {
                        let v = scalar.value - 0x10000
                        appendUnicodeEscape(0xD800 + (v >> 10), to: &out)
                        appendUnicodeEscape(0xDC00 + (v & 0x3FF), to: &out)
                    } else {
                        appendUnicodeEscape(scalar.value, to: &out)
                    }
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
    }

    private static func appendUnicodeEscape(_ value: UInt32, to out: inout String) {
        out += "\\u"
        out.append(hex[Int((value >> 12) & 0xF)])
        out.append(hex[Int((value >> 8) & 0xF)])
        out.append(hex[Int((value >> 4) & 0xF)])
        out.append(hex[Int(value & 0xF)])
    }
}

// MARK: - Cleaning

/// "Clean" turns messy pasted text into valid, formatted JSON: strips code fences,
/// comments and trailing commas, normalises quotes, and unwraps double-encoded JSON.
public enum JSONCleaner {
    public struct Result: Equatable {
        public var value: JSONValue
        public var notes: [String]
    }

    public static func clean(_ text: String) throws -> Result {
        var notes: [String] = []
        var working = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code fences.
        if working.hasPrefix("```") {
            var lines = working.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
            working = lines.joined(separator: "\n")
            notes.append("Removed code fence")
        }

        // Some tools prefix JSON with a security guard like `)]}'`.
        if working.hasPrefix(")]}'") {
            working = String(working.dropFirst(4))
            notes.append("Removed XSSI prefix")
        }

        var value: JSONValue
        do {
            value = try JSONParser.parse(working, options: .strict)
        } catch {
            value = try JSONParser.parse(working, options: .lenient)
            notes.append("Repaired non-standard JSON (comments, trailing commas or quotes)")
        }

        // Unwrap double-encoded JSON: a string whose content is itself an object or array.
        var unwrapDepth = 0
        while case .string(let inner) = value, unwrapDepth < 5 {
            let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { break }
            guard let innerValue = try? JSONParser.parse(trimmed, options: .lenient) else { break }
            value = innerValue
            unwrapDepth += 1
        }
        if unwrapDepth > 0 { notes.append("Unwrapped string-encoded JSON (\(unwrapDepth)×)") }

        return Result(value: value, notes: notes)
    }
}
