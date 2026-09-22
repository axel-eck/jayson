import Foundation
import JaysonCore

private func json(_ text: String) throws -> JSONValue { try JSONParser.parse(text) }

/// Options without `$schema`, so sub-structure can be compared directly.
private var plain: SchemaInferenceOptions {
    var o = SchemaInferenceOptions()
    o.addSchemaKeyword = false
    return o
}

private func expectJSON(_ actual: JSONValue, _ expected: JSONValue, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    if !actual.isJSONEqual(to: expected) {
        fail("\(message.isEmpty ? "" : message + ": ")expected \(JSONFormatter.minify(expected)), got \(JSONFormatter.minify(actual))", file: file, line: line)
    }
}

func runSchemaInferenceChecks() {
    check("scalar types: string, integer, number, boolean, null") {
        expectJSON(SchemaInferrer.schema(for: "hi"), ["type": "string"])
        expectJSON(SchemaInferrer.schema(for: 42), ["type": "integer"])
        expectJSON(SchemaInferrer.schema(for: try json("1.0")), ["type": "integer"], "1.0 has no fractional part")
        expectJSON(SchemaInferrer.schema(for: 2.5), ["type": "number"])
        expectJSON(SchemaInferrer.schema(for: try json("1e3")), ["type": "integer"])
        expectJSON(SchemaInferrer.schema(for: true), ["type": "boolean"])
        expectJSON(SchemaInferrer.schema(for: nil), ["type": "null"])
    }

    check("scalar schemas never carry min/max/length constraints") {
        for value in [JSONValue.string("abc"), 7, -3.5, true] {
            guard let object = SchemaInferrer.schema(for: value).objectValue else { fail("not an object"); continue }
            for key in ["minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems"] {
                expect(!object.contains(key), "unexpected \(key)")
            }
        }
    }

    check("format detection for all supported formats") {
        let cases: [(String, String)] = [
            ("2024-03-05T12:30:00Z", "date-time"),
            ("2024-03-05T12:30:00.123+02:00", "date-time"),
            ("2024-03-05", "date"),
            ("12:30:00Z", "time"),
            ("alice@example.com", "email"),
            ("https://example.com/path?q=1", "uri"),
            ("mailto:alice@example.com", "uri"),
            ("123e4567-e89b-12d3-a456-426614174000", "uuid"),
            ("192.168.0.1", "ipv4"),
        ]
        for (sample, format) in cases {
            expectJSON(SchemaInferrer.schema(for: .string(sample)), ["type": "string", "format": .string(format)], sample)
        }
    }

    check("no format for ordinary strings and near misses") {
        for sample in ["hello", "", "2024-13-45", "999.1.1.1", "not@email", "12:30", "http//nope", "abc:def"] {
            expectJSON(SchemaInferrer.schema(for: .string(sample)), ["type": "string"], sample)
        }
        var options = plain
        options.detectFormats = false
        expectJSON(SchemaInferrer.schema(for: "alice@example.com", options: options), ["type": "string"], "detection disabled")
    }

    check("format kept only when every sample matches") {
        let all = SchemaInferrer.infer(fromSamples: ["a@x.com", "b@y.org"], options: plain)
        expectJSON(all, ["type": "string", "format": "email"])
        let mixed = SchemaInferrer.infer(fromSamples: ["a@x.com", "not an email"], options: plain)
        expectJSON(mixed, ["type": "string"])
        let differing = SchemaInferrer.infer(fromSamples: ["a@x.com", "2024-01-01"], options: plain)
        expectJSON(differing, ["type": "string"], "two different formats drop the keyword")
        let inArray = SchemaInferrer.schema(for: ["https://a.com", "https://b.com"])
        expectJSON(inArray, ["type": "array", "items": ["type": "string", "format": "uri"]])
    }

    check("single object: properties in key order, all keys required") {
        let value = try json(#"{"name":"Ann","age":30,"tags":["x"],"meta":{"ok":true}}"#)
        let schema = SchemaInferrer.schema(for: value)
        expectJSON(schema, [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
                "age": ["type": "integer"],
                "tags": ["type": "array", "items": ["type": "string"]],
                "meta": ["type": "object", "properties": ["ok": ["type": "boolean"]], "required": ["ok"]],
            ],
            "required": ["name", "age", "tags", "meta"],
        ])
        expectEqual(schema["properties"]?.objectValue?.keys, ["name", "age", "tags", "meta"], "property order")
        expectJSON(SchemaInferrer.schema(for: try json("{}")), ["type": "object", "properties": [:]], "empty object omits required")
    }

    check("nested object samples: required intersection, property union") {
        let samples = [
            try json(#"{"id":1,"user":{"name":"a","email":"a@x.com"},"extra":true}"#),
            try json(#"{"id":2,"user":{"name":"b","age":3}}"#),
        ]
        let schema = SchemaInferrer.infer(fromSamples: samples, options: plain)
        expectJSON(schema["required"] ?? .null, ["id", "user"])
        expectEqual(schema["properties"]?.objectValue?.keys, ["id", "user", "extra"])
        let user = schema["properties"]?["user"] ?? .null
        expectEqual(user["properties"]?.objectValue?.keys, ["name", "email", "age"])
        expectJSON(user["required"] ?? .null, ["name"])
        expectJSON(user["properties"]?["email"] ?? .null, ["type": "string", "format": "email"])
    }

    check("required policy none and all") {
        let samples = [try json(#"{"a":1,"b":2}"#), try json(#"{"a":3}"#)]
        var none = plain
        none.requiredPolicy = .none
        let noneSchema = SchemaInferrer.infer(fromSamples: samples, options: none)
        expectNil(noneSchema["required"], "policy none never emits required")
        expectNil(SchemaInferrer.schema(for: ["x": ["y": 1]], options: none)["properties"]?["x"]?["required"])

        var all = plain
        all.requiredPolicy = .all
        expectJSON(SchemaInferrer.infer(fromSamples: samples, options: all)["required"] ?? .null, ["a", "b"])
    }

    check("array of heterogeneous objects merges element schemas") {
        let value = try json(#"[{"id":1,"name":"a"},{"id":2.5,"tags":[]},{"id":3,"name":null}]"#)
        let schema = SchemaInferrer.schema(for: value)
        expectJSON(schema, [
            "type": "array",
            "items": [
                "type": "object",
                "properties": [
                    "id": ["type": "number"],
                    "name": ["type": ["string", "null"]],
                    "tags": ["type": "array"],
                ],
                "required": ["id"],
            ],
        ])
    }

    check("empty array has no items; empty array merged with populated array keeps items") {
        expectJSON(SchemaInferrer.schema(for: []), ["type": "array"])
        let merged = SchemaInferrer.infer(fromSamples: [[], [1, 2]], options: plain)
        expectJSON(merged, ["type": "array", "items": ["type": "integer"]])
        let reversed = SchemaInferrer.infer(fromSamples: [[1, 2], []], options: plain)
        expectJSON(reversed, ["type": "array", "items": ["type": "integer"]])
    }

    check("integer + number widens to number") {
        expectJSON(SchemaInferrer.merge(["type": "integer"], ["type": "number"]), ["type": "number"])
        expectJSON(SchemaInferrer.merge(["type": "number"], ["type": "integer"]), ["type": "number"])
        expectJSON(SchemaInferrer.schema(for: [1, 2.5, 3]), ["type": "array", "items": ["type": "number"]])
        expectJSON(SchemaInferrer.merge(["type": ["integer", "null"]], ["type": "number"]), ["type": ["number", "null"]])
    }

    check("mixed scalar types become a sorted type array with null last") {
        let schema = SchemaInferrer.schema(for: [nil, "s", true, 1])
        expectJSON(schema["items"] ?? .null, ["type": ["boolean", "integer", "string", "null"]])
        expectJSON(SchemaInferrer.merge(["type": "null"], ["type": "string"]), ["type": ["string", "null"]])
        expectJSON(SchemaInferrer.merge(["type": "string", "format": "email"], ["type": "null"]), ["type": ["string", "null"]], "format dropped when sides disagree")
        expectJSON(SchemaInferrer.merge(["type": "string"], ["type": "string"]), ["type": "string"], "same type stays a string")
    }

    check("object merged with scalar produces anyOf") {
        let schema = SchemaInferrer.schema(for: [["a": 1], "text"])
        expectJSON(schema["items"] ?? .null, [
            "anyOf": [
                ["type": "object", "properties": ["a": ["type": "integer"]], "required": ["a"]],
                ["type": "string"],
            ],
        ])
        let arrayAndObject = SchemaInferrer.merge(["type": "array"], ["type": "object", "properties": [:]])
        expectJSON(arrayAndObject, ["anyOf": [["type": "array"], ["type": "object", "properties": [:]]]])
    }

    check("anyOf extends alternatives, merges compatible ones and dedupes") {
        let schema = SchemaInferrer.schema(for: [["a": 1], "text", ["b": true], "more", 3, nil, ["a": 1]])
        expectJSON(schema["items"] ?? .null, [
            "anyOf": [
                ["type": "object", "properties": ["a": ["type": "integer"], "b": ["type": "boolean"]]],
                ["type": ["integer", "string", "null"]],
            ],
        ])
        let existing: JSONValue = ["anyOf": [["type": "string"], ["type": "array"]]]
        expectJSON(SchemaInferrer.merge(existing, ["type": "string"]), existing, "duplicate alternative is not added")
        expectJSON(SchemaInferrer.merge(existing, ["type": "object", "properties": [:]]), [
            "anyOf": [["type": "string"], ["type": "array"], ["type": "object", "properties": [:]]],
        ])
        let nested = SchemaInferrer.merge(existing, ["anyOf": [["type": "array"], ["type": "boolean"]]])
        expectJSON(nested, ["anyOf": [["type": ["boolean", "string"]], ["type": "array"]]], "anyOf + anyOf")
    }

    check("merging with {} or a boolean schema yields the other side") {
        let schema: JSONValue = ["type": "object", "properties": ["a": ["type": "integer"]], "required": ["a"]]
        expectJSON(SchemaInferrer.merge([:], schema), schema)
        expectJSON(SchemaInferrer.merge(schema, [:]), schema)
        expectJSON(SchemaInferrer.merge(true, schema), schema)
        expectJSON(SchemaInferrer.merge([:], [:]), [:])
    }

    check("infer(fromSamples: []) yields an empty schema") {
        expectJSON(SchemaInferrer.infer(fromSamples: []), ["$schema": .string(SchemaInferrer.schemaKeywordValue)])
        expectJSON(SchemaInferrer.infer(fromSamples: [], options: plain), [:])
    }

    check("infer(fromSamples:) with a single sample equals infer(from:)") {
        let value = try json(#"{"a":[1,{"b":"x"}]}"#)
        expectJSON(SchemaInferrer.infer(fromSamples: [value]), SchemaInferrer.infer(from: value))
    }

    check("deterministic key order in output") {
        let value = try json(#"{"when":"2024-01-01","list":[1,"a"]}"#)
        let root = SchemaInferrer.infer(from: value)
        expectEqual(root.objectValue?.keys, ["$schema", "type", "properties", "required"])
        let when = root["properties"]?["when"]
        expectEqual(when?.objectValue?.keys, ["type", "format"])
        let list = root["properties"]?["list"]
        expectEqual(list?.objectValue?.keys, ["type", "items"])

        var examples = SchemaInferenceOptions()
        examples.includeExamples = true
        let scalar = SchemaInferrer.infer(from: "a@b.co", options: examples)
        expectEqual(scalar.objectValue?.keys, ["$schema", "type", "format", "examples"])
        let anyOf = SchemaInferrer.merge(["type": "string"], ["type": "object", "properties": [:]])
        expectEqual(anyOf.objectValue?.keys, ["anyOf"])
    }

    check("$schema presence toggled by option, never in sub-schemas") {
        let value: JSONValue = ["a": [1]]
        let with = SchemaInferrer.infer(from: value)
        expectEqual(with["$schema"], .string("https://json-schema.org/draft/2020-12/schema"))
        expectEqual(with.objectValue?.keys.first, "$schema")
        expectNil(with["properties"]?["a"]?["$schema"])
        expectNil(with["properties"]?["a"]?["items"]?["$schema"])
        expectNil(SchemaInferrer.infer(from: value, options: plain)["$schema"])
        expectNil(SchemaInferrer.schema(for: value)["$schema"], "schema(for:) never adds $schema")
        expectEqual(SchemaInferrer.infer(fromSamples: [value, value])["$schema"], .string(SchemaInferrer.schemaKeywordValue))
    }

    check("includeExamples adds first sample to scalars only") {
        var options = plain
        options.includeExamples = true
        let value = try json(#"{"n":3,"s":"x","b":false,"z":null,"arr":[1,2],"obj":{}}"#)
        let schema = SchemaInferrer.schema(for: value, options: options)
        let props = schema["properties"] ?? .null
        expectJSON(props["n"] ?? .null, ["type": "integer", "examples": [3]])
        expectJSON(props["s"] ?? .null, ["type": "string", "examples": ["x"]])
        expectJSON(props["b"] ?? .null, ["type": "boolean", "examples": [false]])
        expectJSON(props["z"] ?? .null, ["type": "null"], "null has no examples")
        expectNil(schema["examples"], "objects have no examples")
        expectNil(props["arr"]?["examples"], "arrays have no examples")
        expectJSON(props["arr"]?["items"] ?? .null, ["type": "integer", "examples": [1, 2]], "merged examples are unioned")
        expectJSON(SchemaInferrer.schema(for: [5, 5, 5], options: options)["items"] ?? .null, ["type": "integer", "examples": [5]], "examples deduped")
        expectNil(SchemaInferrer.schema(for: 3)["examples"], "off by default")
    }

    check("deeply nested structure round-trips through the formatter") {
        let value = try json(#"{"a":{"b":{"c":[{"d":[[1]]}]}}}"#)
        let schema = SchemaInferrer.infer(from: value, options: plain)
        let text = JSONFormatter.minify(schema)
        expectEqual(text, #"{"type":"object","properties":{"a":{"type":"object","properties":{"b":{"type":"object","properties":{"c":{"type":"array","items":{"type":"object","properties":{"d":{"type":"array","items":{"type":"array","items":{"type":"integer"}}}},"required":["d"]}}},"required":["c"]}},"required":["b"]}},"required":["a"]}"#)
    }
}
