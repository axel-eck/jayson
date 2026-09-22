import Foundation
import JaysonCore

private func json(_ text: String) throws -> JSONValue { try JSONParser.parse(text) }

private var samples: SchemaInstanceOptions {
    var o = SchemaInstanceOptions()
    o.useSampleValues = true
    return o
}

private var requiredOnly: SchemaInstanceOptions {
    var o = SchemaInstanceOptions()
    o.includeOptionalProperties = false
    return o
}

private func expectJSON(_ actual: JSONValue, _ expected: JSONValue, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    if !actual.isJSONEqual(to: expected) {
        fail("\(message.isEmpty ? "" : message + ": ")expected \(JSONFormatter.minify(expected)), got \(JSONFormatter.minify(actual))", file: file, line: line)
    }
}

private func instance(_ schema: JSONValue, root: JSONValue? = nil, options: SchemaInstanceOptions = .init()) -> JSONValue {
    SchemaInstanceGenerator.makeInstance(from: schema, root: root, options: options)
}

func runSchemaInstanceChecks() {
    check("boolean schemas and unknown schemas give null") {
        expectJSON(instance(true), nil)
        expectJSON(instance(false), nil)
        expectJSON(instance([:]), nil)
        expectJSON(instance(["description": "nothing structural"]), nil)
        expectJSON(instance(["type": "weird"]), nil)
    }

    check("default > const > examples[0] > enum[0]") {
        expectJSON(instance(["type": "string", "default": "d", "const": "c", "examples": ["e"], "enum": ["n"]]), "d")
        expectJSON(instance(["type": "string", "const": "c", "examples": ["e"], "enum": ["n"]]), "c")
        expectJSON(instance(["type": "string", "examples": ["e", "e2"], "enum": ["n"]]), "e")
        expectJSON(instance(["type": "string", "enum": ["n", "m"]]), "n")
        expectJSON(instance(["type": "integer", "default": nil]), nil, "an explicit null default is honoured")
        expectJSON(instance(["type": "string", "examples": [], "enum": []]), "", "empty lists fall through to type")
        expectJSON(instance(["const": ["x": 1]]), ["x": 1], "const without type")
    }

    check("plain scalars: empty string, 0, false, null") {
        expectJSON(instance(["type": "string"]), "")
        expectJSON(instance(["type": "number"]), 0)
        expectJSON(instance(["type": "integer"]), 0)
        expectJSON(instance(["type": "boolean"]), false)
        expectJSON(instance(["type": "null"]), nil)
        expectJSON(instance(["type": "string", "format": "email"]), "", "formats ignored without sample values")
    }

    check("object with all properties, in properties order") {
        let schema = try json(##"{"type":"object","properties":{"name":{"type":"string"},"age":{"type":"integer"},"tags":{"type":"array","items":{"type":"string"}},"nested":{"type":"object","properties":{"ok":{"type":"boolean"}}}},"required":["name"]}"##)
        let value = instance(schema)
        expectJSON(value, ["name": "", "age": 0, "tags": [], "nested": ["ok": false]])
        expectEqual(value.objectValue?.keys, ["name", "age", "tags", "nested"])
    }

    check("object with required-only option") {
        let schema = try json(##"{"type":"object","properties":{"a":{"type":"string"},"b":{"type":"integer"},"c":{"type":"boolean"}},"required":["c","a"]}"##)
        let value = instance(schema, options: requiredOnly)
        expectJSON(value, ["a": "", "c": false])
        expectEqual(value.objectValue?.keys, ["a", "c"], "properties order wins over required order")
        expectJSON(instance(["type": "object", "properties": ["a": ["type": "string"]]], options: requiredOnly), [:], "no required means empty object")
        let nested = try json(##"{"type":"object","properties":{"inner":{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"}},"required":["y"]}},"required":["inner"]}"##)
        expectJSON(instance(nested, options: requiredOnly), ["inner": ["y": 0]], "option applies recursively")
    }

    check("required properties missing from properties become null") {
        let schema: JSONValue = ["type": "object", "properties": ["a": ["type": "integer"]], "required": ["a", "b", "c"]]
        expectJSON(instance(schema), ["a": 0, "b": nil, "c": nil])
        expectJSON(instance(["required": ["only"]]), nil, "required alone does not imply object")
        expectJSON(instance(["type": "object", "required": ["only"]]), ["only": nil])
    }

    check("arrays: empty by default, items repeated to minItems, prefixItems first") {
        expectJSON(instance(["type": "array", "items": ["type": "string"]]), [])
        expectJSON(instance(["type": "array", "items": ["type": "integer"], "minItems": 1]), [0])
        expectJSON(instance(["type": "array", "items": ["type": "boolean"], "minItems": 3]), [false, false, false])
        expectJSON(instance(["type": "array", "minItems": 2]), [nil, nil], "no items schema pads with null")
        let tuple: JSONValue = ["type": "array", "prefixItems": [["type": "string"], ["type": "integer"]], "items": ["type": "boolean"], "minItems": 3]
        expectJSON(instance(tuple), ["", 0, false])
        expectJSON(instance(["type": "array", "prefixItems": [["const": 1]]]), [1], "prefixItems present without minItems")
    }

    check("nested arrays with minItems") {
        let schema = try json(##"{"type":"array","minItems":2,"items":{"type":"array","minItems":1,"items":{"type":"object","properties":{"v":{"type":"number","minimum":1.5}},"required":["v"]}}}"##)
        expectJSON(instance(schema), [[["v": 1.5]], [["v": 1.5]]])
        let huge: JSONValue = ["type": "array", "items": ["type": "integer"], "minItems": 100_000]
        expectEqual(instance(huge).arrayValue?.count, 100, "minItems is capped")
    }

    check("$ref to $defs, definitions and #") {
        let schema = try json(##"{"$defs":{"name":{"type":"string","default":"Ann"}},"definitions":{"legacy":{"type":"integer","const":7}},"type":"object","properties":{"n":{"$ref":"#/$defs/name"},"l":{"$ref":"#/definitions/legacy"},"missing":{"$ref":"#/$defs/nope"},"remote":{"$ref":"https://example.com/s.json#/x"}}}"##)
        expectJSON(instance(schema), ["n": "Ann", "l": 7, "missing": nil, "remote": nil])

        let selfRef = try json(##"{"type":"object","properties":{"child":{"$ref":"#"},"leaf":{"type":"integer"}}}"##)
        expectJSON(instance(selfRef), ["child": ["child": nil, "leaf": 0], "leaf": 0], "# resolves to root once, then the cycle guard stops")
    }

    check("$ref with explicit root, anchors and escaped pointers") {
        let root = try json(##"{"$defs":{"a~b/c":{"type":"boolean","default":true},"anch":{"$anchor":"here","type":"string","default":"anchored"}}}"##)
        expectJSON(instance(["$ref": "#/$defs/a~0b~1c"], root: root), true)
        expectJSON(instance(["$ref": "#/$defs/a~0b~1c"]), nil, "without root there is nothing to resolve against")
        expectJSON(instance(["$ref": "#here"], root: root), "anchored")
        expectJSON(instance(["$ref": "#nowhere"], root: root), nil)
        expectJSON(instance(["$ref": "#/%24defs/anch"], root: root), "anchored", "percent-encoded pointer")
    }

    check("recursive schemas terminate") {
        let tree = try json(##"{"$defs":{"node":{"type":"object","properties":{"value":{"type":"integer"},"children":{"type":"array","minItems":1,"items":{"$ref":"#/$defs/node"}}},"required":["value","children"]}},"$ref":"#/$defs/node"}"##)
        let value = instance(tree)
        expectJSON(value, ["value": 0, "children": [nil]], "re-entering the ref on the stack yields null")

        let mutual = try json(##"{"$defs":{"a":{"type":"object","properties":{"b":{"$ref":"#/$defs/b"}}},"b":{"type":"object","properties":{"a":{"$ref":"#/$defs/a"}}}},"$ref":"#/$defs/a"}"##)
        expectJSON(instance(mutual), ["b": ["a": nil]])

        let direct = try json(##"{"$defs":{"loop":{"$ref":"#/$defs/loop"}},"$ref":"#/$defs/loop"}"##)
        expectJSON(instance(direct), nil)
    }

    check("allOf merges branch instances key-wise") {
        let schema = try json(##"{"allOf":[{"type":"object","properties":{"a":{"type":"string"}},"required":["a"]},{"type":"object","properties":{"b":{"type":"integer","default":5}}},{"properties":{"c":{"type":"boolean"}}}]}"##)
        expectJSON(instance(schema), ["a": "", "b": 5, "c": false])

        let withInline = try json(##"{"type":"object","properties":{"own":{"const":1}},"allOf":[{"properties":{"own":{"const":2},"extra":{"const":3}}}]}"##)
        expectJSON(instance(withInline), ["own": 1, "extra": 3], "inline properties win over allOf branches")

        let deep = try json(##"{"allOf":[{"properties":{"o":{"properties":{"x":{"const":1}}}}},{"properties":{"o":{"properties":{"y":{"const":2}}}}}]}"##)
        expectJSON(instance(deep), ["o": ["x": 1, "y": 2]], "nested objects merge recursively")

        expectJSON(instance(["allOf": [["type": "string", "minLength": 2]]]), "aa", "scalar allOf")
    }

    check("anyOf and oneOf use the first branch") {
        expectJSON(instance(["anyOf": [["type": "integer", "minimum": 3], ["type": "string"]]]), 3)
        expectJSON(instance(["oneOf": [["const": "first"], ["const": "second"]]]), "first")
        let mixed = try json(##"{"type":"object","properties":{"kind":{"type":"string"}},"oneOf":[{"properties":{"kind":{"const":"a"},"detail":{"type":"integer"}}},{"properties":{"kind":{"const":"b"}}}]}"##)
        expectJSON(instance(mixed), ["kind": "", "detail": 0], "inline object combined with first oneOf branch")
    }

    check("type arrays pick the first non-null entry") {
        expectJSON(instance(["type": ["null", "string"]]), "")
        expectJSON(instance(["type": ["integer", "string"], "minimum": 2]), 2)
        expectJSON(instance(["type": ["null"]]), nil)
        expectJSON(instance(["type": ["null", "object"], "properties": ["a": ["type": "boolean"]]]), ["a": false])
    }

    check("missing type is inferred from properties or items") {
        expectJSON(instance(["properties": ["a": ["type": "integer"]]]), ["a": 0])
        expectJSON(instance(["items": ["type": "integer"], "minItems": 2]), [0, 0])
        expectJSON(instance(["prefixItems": [["type": "string"]]]), [""])
        expectJSON(instance(["minimum": 4]), nil, "numeric keywords alone do not imply a type")
    }

    check("sample values per format") {
        let cases: [(String?, String)] = [
            ("date-time", "2024-01-01T00:00:00Z"),
            ("date", "2024-01-01"),
            ("time", "00:00:00Z"),
            ("email", "user@example.com"),
            ("uri", "https://example.com"),
            ("uuid", "00000000-0000-4000-8000-000000000000"),
            ("ipv4", "127.0.0.1"),
            (nil, "text"),
            ("unknown-format", "text"),
        ]
        for (format, expected) in cases {
            var schema: JSONValue = ["type": "string"]
            if let format { schema = ["type": "string", "format": .string(format)] }
            expectJSON(instance(schema, options: samples), .string(expected), format ?? "plain")
        }
        let object = try json(##"{"type":"object","properties":{"id":{"type":"string","format":"uuid"},"n":{"type":"integer"},"flag":{"type":"boolean"}}}"##)
        expectJSON(instance(object, options: samples), ["id": "00000000-0000-4000-8000-000000000000", "n": 0, "flag": false], "numbers and booleans are unchanged by sample mode")
    }

    check("numbers honour minimum, exclusiveMinimum and multipleOf") {
        expectJSON(instance(["type": "number", "minimum": 2.5]), 2.5)
        expectJSON(instance(["type": "integer", "minimum": -3]), -3)
        expectJSON(instance(["type": "integer", "minimum": 2.5]), 3, "integer rounds a fractional minimum up")
        expectJSON(instance(["type": "integer", "exclusiveMinimum": 10]), 11)
        expectJSON(instance(["type": "number", "exclusiveMinimum": 10]), 11)
        expectJSON(instance(["type": "number", "exclusiveMinimum": 10, "multipleOf": 0.5]), 10.5)
        expectJSON(instance(["type": "number", "minimum": 7, "multipleOf": 5]), 10)
        expectJSON(instance(["type": "number", "minimum": 10, "multipleOf": 5]), 10, "already a multiple")
        expectJSON(instance(["type": "integer", "minimum": 1, "multipleOf": 2.5]), 5, "integer multiple of a fractional step")
        expectJSON(instance(["type": "number", "multipleOf": 3]), 0, "zero is a multiple of anything")
        expectJSON(instance(["type": "integer", "minimum": 7, "multipleOf": 5, "maximum": 9]), 5, "maximum pulls the value back down")
        expectJSON(instance(["type": "number", "minimum": 0.1]), 0.1)
        expectEqual(instance(["type": "number", "minimum": try json("1.50")]).numberValue?.literal, "1.50", "author's literal preserved")
    }

    check("strings honour minLength") {
        expectJSON(instance(["type": "string", "minLength": 3]), "aaa")
        expectJSON(instance(["type": "string", "minLength": 0]), "")
        expectJSON(instance(["type": "string", "minLength": 6], options: samples), "textaa", "sample padded to minLength")
        expectJSON(instance(["type": "string", "minLength": 2], options: samples), "text", "sample already long enough")
        expectJSON(instance(["type": "string", "format": "date", "minLength": 12], options: samples), "2024-01-01aa")
    }

    check("generated instance for an inferred schema mirrors the source shape") {
        let source = try json(##"{"id":"123e4567-e89b-12d3-a456-426614174000","count":3,"ratio":0.5,"tags":["a"],"meta":{"ok":true,"none":null}}"##)
        let schema = SchemaInferrer.infer(from: source)
        let value = instance(schema)
        expectJSON(value, ["id": "", "count": 0, "ratio": 0, "tags": [], "meta": ["ok": false, "none": nil]])
        expectEqual(value.objectValue?.keys, source.objectValue?.keys)
        let rich = instance(schema, options: samples)
        expectJSON(rich["id"] ?? .null, "00000000-0000-4000-8000-000000000000")
    }
}
