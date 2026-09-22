import Foundation
import JaysonCore

func runJSONValueChecks() {
    check("parse round-trip preserves order and literals") {
        let text = #"{"b":1,"a":[1.0,2e3,"x\n"],"c":{"z":null,"y":true}}"#
        let value = try JSONParser.parse(text)
        expectEqual(JSONFormatter.minify(value), text)
        expectEqual(value.objectValue?.keys, ["b", "a", "c"])
    }

    check("strict rejects and lenient accepts comments/quotes/trailing commas") {
        let text = "{ // hi\n 'a': 1, b: 2, }"
        expectThrows { _ = try JSONParser.parse(text) }
        let value = try JSONParser.parse(text, options: .lenient)
        expectEqual(value, ["a": 1, "b": 2])
    }

    check("parse error carries line and column") {
        do {
            _ = try JSONParser.parse("{\n  \"a\": tru\n}")
            fail("expected failure")
        } catch let e as JSONParseError {
            expectEqual(e.line, 2)
            expectEqual(e.column, 8)
        }
    }

    check("unicode escapes and surrogate pairs") {
        let value = try JSONParser.parse(#""é😀""#)
        expectEqual(value, "é😀")
        expectEqual(JSONFormatter.minify(.string("tab\there\u{1}")), #""tab\there\u0001""#)
    }

    check("path mutation: insert, remove, set, rename") {
        var value: JSONValue = ["users": [["name": "a"], ["name": "b"]]]
        let users = ValuePath([.key("users")])
        try value.insert(["name": "c"], intoArrayAt: users)
        expectEqual(value.value(at: users.appending(index: 2).appending(key: "name")), "c")
        try value.remove(at: users.appending(index: 0))
        expectEqual(value["users"]?.childCount, 2)
        try value.set("B", at: users.appending(index: 0).appending(key: "name"))
        expectEqual(value["users"]?[0]?["name"], "B")
        try value.renameKey(at: users.appending(index: 0).appending(key: "name"), to: "title")
        expectEqual(value["users"]?[0]?.objectValue?.keys, ["title"])
        expectThrows { try value.remove(at: .root) }
        expectThrows { try value.insert(1, intoArrayAt: users.appending(index: 0)) }
    }

    check("path rendering") {
        expectEqual(ValuePath([.key("users"), .index(0), .key("odd key")]).jsonPathString, "$.users[0]['odd key']")
        expectEqual(ValuePath([.key("a/b"), .index(0)]).jsonPointer, "/a~1b/0")
        expectEqual(ValuePath.root.jsonPathString, "$")
        expectEqual(ValuePath.fromJSONPointer("/a~1b/0"), ["a/b", "0"])
    }

    check("cleaner unwraps double-encoded JSON and repairs") {
        let result = try JSONCleaner.clean("```json\n\"{\\\"a\\\": [1,2,],}\"\n```")
        expectEqual(result.value, ["a": [1, 2]])
    }

    check("semantic equality ignores key order") {
        let a: JSONValue = ["x": 1, "y": 2]
        let b: JSONValue = ["y": 2.0, "x": 1]
        expect(a.isJSONEqual(to: b))
        expect(a != b)
    }

    check("pretty format") {
        let value: JSONValue = ["a": [1, ["b": nil]], "c": "d"]
        expectEqual(JSONFormatter.format(value), "{\n  \"a\": [\n    1,\n    {\n      \"b\": null\n    }\n  ],\n  \"c\": \"d\"\n}")
        expectEqual(JSONFormatter.format(value.sortingKeys(), options: JSONFormatOptions(indent: .tab)), "{\n\t\"a\": [\n\t\t1,\n\t\t{\n\t\t\t\"b\": null\n\t\t}\n\t],\n\t\"c\": \"d\"\n}")
    }
}
