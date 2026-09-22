import Foundation
import JaysonCore

private func search(_ query: String, _ root: JSONValue, _ configure: (inout TextSearchOptions) -> Void = { _ in }) -> [(String, TextSearchMatch.Kind)] {
    var options = TextSearchOptions()
    configure(&options)
    return TextSearch.search(query, in: root, options: options).map { ($0.path.jsonPathString, $0.kind) }
}

private func expectMatches(_ actual: [(String, TextSearchMatch.Kind)], _ expected: [(String, TextSearchMatch.Kind)], _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    let same = actual.count == expected.count && zip(actual, expected).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    if !same {
        fail("\(message.isEmpty ? "" : message + ": ")expected \(expected), got \(actual)", file: file, line: line)
    }
}

func runTextSearchChecks() {
    let people: JSONValue = [
        "name": "Alice",
        "alice_id": 1,
        "nested": ["name": "bob", "Alias": ["ALICE", "malice"]],
    ]

    check("matches keys and values in document order, case-insensitive by default") {
        expectMatches(search("alice", people), [
            ("$.name", .value),
            ("$.alice_id", .key),
            ("$.nested.Alias[0]", .value),
            ("$.nested.Alias[1]", .value),
        ])
    }

    check("matchKeys / matchValues toggles") {
        expectMatches(search("alice", people) { $0.matchKeys = false }, [
            ("$.name", .value), ("$.nested.Alias[0]", .value), ("$.nested.Alias[1]", .value),
        ])
        expectMatches(search("alice", people) { $0.matchValues = false }, [("$.alice_id", .key)])
        expectMatches(search("alice", people) { $0.matchKeys = false; $0.matchValues = false }, [])
        expectMatches(search("name", people), [("$.name", .key), ("$.nested.name", .key)])
    }

    check("case sensitivity") {
        expectMatches(search("alice", people) { $0.caseSensitive = true }, [("$.alice_id", .key), ("$.nested.Alias[1]", .value)])
        expectMatches(search("ALICE", people) { $0.caseSensitive = true }, [("$.nested.Alias[0]", .value)])
        expectMatches(search("Alice", people) { $0.caseSensitive = true }, [("$.name", .value)])
        expectMatches(search("É", ["e": "café"]), [("$.e", .value)], "case folding beyond ASCII")
        expectMatches(search("É", ["e": "café"]) { $0.caseSensitive = true }, [])
    }

    check("a node can match by key and by value") {
        let doc: JSONValue = ["x": "x", "y": ["x": 2]]
        expectMatches(search("x", doc), [("$.x", .key), ("$.x", .value), ("$.y.x", .key)])
        let matches = TextSearch.search("x", in: doc)
        expectEqual(matches.count, 3)
        expectEqual(Set(matches).count, 3, "matches are distinct by kind")
        expectEqual(matches[0], TextSearchMatch(path: ValuePath([.key("x")]), kind: .key))
    }

    check("number literals, booleans and null are searched by their text") {
        let doc = try JSONParser.parse(#"{"price": 12.50, "big": 1e3, "ok": true, "off": false, "nothing": null, "s": "nullable true"}"#)
        expectMatches(search("12.5", doc), [("$.price", .value)])
        expectMatches(search("1e3", doc), [("$.big", .value)])
        expectMatches(search("1000", doc), [], "the source literal is searched, not the numeric value")
        expectMatches(search("true", doc), [("$.ok", .value), ("$.s", .value)])
        expectMatches(search("false", doc), [("$.off", .value)])
        expectMatches(search("null", doc), [("$.nothing", .value), ("$.s", .value)])
        expectMatches(search("null", doc) { $0.wholeWord = true }, [("$.nothing", .value)])
        expectMatches(search("-", ["n": -3, "m": 3]), [("$.n", .value)])
    }

    check("containers are never value matches; keys inside arrays of objects are found") {
        let doc: JSONValue = ["list": [["item": 1], ["item": 2]], "obj": ["list": []]]
        expectMatches(search("list", doc), [("$.list", .key), ("$.obj.list", .key)])
        expectMatches(search("item", doc), [("$.list[0].item", .key), ("$.list[1].item", .key)])
        expectMatches(search("[", doc), [])
        expectMatches(search("{", doc), [])
        expectMatches(search("1", [[1], [[1]], 10]), [("$[0][0]", .value), ("$[1][0][0]", .value), ("$[2]", .value)])
    }

    check("whole word") {
        let doc: JSONValue = ["a": "cat", "b": "concatenate", "c": "the cat sat", "d": "cat-like", "e": "cat_like", "cat": 0, "bobcat": 0]
        expectMatches(search("cat", doc), [
            ("$.a", .value), ("$.b", .value), ("$.c", .value), ("$.d", .value), ("$.e", .value), ("$.cat", .key), ("$.bobcat", .key),
        ])
        expectMatches(search("cat", doc) { $0.wholeWord = true }, [("$.a", .value), ("$.c", .value), ("$.d", .value), ("$.cat", .key)])
        expectMatches(search("CAT", doc) { $0.wholeWord = true }, [("$.a", .value), ("$.c", .value), ("$.d", .value), ("$.cat", .key)])
        expectMatches(search("CAT", doc) { $0.wholeWord = true; $0.caseSensitive = true }, [])
        expectMatches(search("cat sat", doc) { $0.wholeWord = true }, [("$.c", .value)], "multi-word query")
        expectMatches(search("a.b", ["k": "a.b", "j": "axb"]) { $0.wholeWord = true }, [("$.k", .value)], "query is escaped, not a regex")
        expectMatches(search("-1", ["k": "x -1 y", "j": "x-12"]) { $0.wholeWord = true }, [("$.k", .value)])
    }

    check("regular expressions") {
        let doc: JSONValue = ["a": "cat", "b": "concatenate", "c": "the cat sat", "id_42": "abc123", "n": "12 ab"]
        expectMatches(search("^c.*t$", doc) { $0.regex = true }, [("$.a", .value)])
        expectMatches(search("c(at|on)", doc) { $0.regex = true }, [("$.a", .value), ("$.b", .value), ("$.c", .value)])
        expectMatches(search(#"\d+"#, doc) { $0.regex = true }, [("$.id_42", .key), ("$.id_42", .value), ("$.n", .value)])
        expectMatches(search(#"\d+"#, doc) { $0.regex = true; $0.wholeWord = true }, [("$.n", .value)])
        expectMatches(search("^CAT$", doc) { $0.regex = true }, [("$.a", .value)], "regex is case-insensitive by default")
        expectMatches(search("^CAT$", doc) { $0.regex = true; $0.caseSensitive = true }, [])
        expectMatches(search("a|b", doc) { $0.regex = true; $0.wholeWord = true; $0.matchKeys = false }, [], "alternation is grouped before word boundaries are added")
        expectMatches(search("^c.*t$", doc), [], "without the regex option the query is literal text")
    }

    check("invalid regular expression yields no matches and does not crash") {
        let doc: JSONValue = ["a": "[", "b": "(x"]
        expectMatches(search("[", doc) { $0.regex = true }, [])
        expectMatches(search("(x", doc) { $0.regex = true }, [])
        expectMatches(search("*", doc) { $0.regex = true }, [])
        expectMatches(search("[", doc), [("$.a", .value)], "literal search still works")
        expectMatches(search("(x", doc), [("$.b", .value)])
        expectMatches(search("(x", doc) { $0.wholeWord = true }, [("$.b", .value)])
    }

    check("empty query, scalar roots and empty documents") {
        expectMatches(search("", people), [])
        expectMatches(search("", people) { $0.regex = true }, [])
        expectMatches(search("hello", "hello world"), [("$", .value)])
        expectMatches(search("42", 42), [("$", .value)])
        expectMatches(search("x", nil), [])
        expectMatches(search("x", []), [])
        expectMatches(search("x", [:]), [])
        expectMatches(search(" ", ["a": "no space", "b": "nospace"]), [("$.a", .value)])
    }

    check("options are Equatable with the documented defaults") {
        let options = TextSearchOptions()
        expectEqual(options.caseSensitive, false)
        expectEqual(options.matchKeys, true)
        expectEqual(options.matchValues, true)
        expectEqual(options.wholeWord, false)
        expectEqual(options.regex, false)
        var other = TextSearchOptions()
        expectEqual(options, other)
        other.regex = true
        expect(options != other)
    }
}
