import Foundation

/// Options for `TextSearch.search`.
public struct TextSearchOptions: Sendable, Equatable {
    /// Match letter case exactly. Off by default.
    public var caseSensitive = false
    /// Consider object keys.
    public var matchKeys = true
    /// Consider scalar values (string content, number literal, `true`/`false`/`null`).
    public var matchValues = true
    /// Only match when the hit is not directly preceded or followed by a word character.
    public var wholeWord = false
    /// Treat the query as a regular expression (ICU syntax). An invalid pattern yields no matches.
    public var regex = false

    public init() {}
}

/// A node whose key or scalar value matched a text search.
public struct TextSearchMatch: Hashable {
    /// What matched: the object key that addresses the node, or the node's scalar value.
    public enum Kind: Hashable {
        case key, value
    }

    /// Path of the value. For `.key` matches this is the path of the member whose key matched.
    public let path: ValuePath
    public let kind: Kind

    public init(path: ValuePath, kind: Kind) {
        self.path = path
        self.kind = kind
    }
}

/// Plain text search over the keys and scalar values of a document.
public enum TextSearch {
    /// Finds every object key and scalar value that contains `query`, in document order. A
    /// node whose key and value both match produces two results (key first). An empty query
    /// returns no matches.
    public static func search(_ query: String, in root: JSONValue, options: TextSearchOptions = .init()) -> [TextSearchMatch] {
        guard !query.isEmpty, options.matchKeys || options.matchValues,
              let matcher = TextMatcher(query: query, options: options) else { return [] }
        var results: [TextSearchMatch] = []
        root.walk { path, value in
            if options.matchKeys, case .key(let key)? = path.last, matcher.matches(key) {
                results.append(TextSearchMatch(path: path, kind: .key))
            }
            if options.matchValues, let text = searchableText(of: value), matcher.matches(text) {
                results.append(TextSearchMatch(path: path, kind: .value))
            }
        }
        return results
    }

    /// The text a scalar is searched by; containers have none.
    static func searchableText(of value: JSONValue) -> String? {
        switch value {
        case .string(let s): return s
        case .number(let n): return n.literal
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array, .object: return nil
        }
    }
}

private struct TextMatcher {
    private enum Mode {
        case substring(String, String.CompareOptions)
        case regex(NSRegularExpression)
    }

    private let mode: Mode

    init?(query: String, options: TextSearchOptions) {
        if options.regex || options.wholeWord {
            var pattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
            if options.wholeWord { pattern = "(?<!\\w)(?:\(pattern))(?!\\w)" }
            var regexOptions: NSRegularExpression.Options = []
            if !options.caseSensitive { regexOptions.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: regexOptions) else { return nil }
            mode = .regex(regex)
        } else {
            mode = .substring(query, options.caseSensitive ? [] : [.caseInsensitive])
        }
    }

    func matches(_ text: String) -> Bool {
        switch mode {
        case .substring(let query, let compareOptions):
            return text.range(of: query, options: compareOptions) != nil
        case .regex(let regex):
            return regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
        }
    }
}
