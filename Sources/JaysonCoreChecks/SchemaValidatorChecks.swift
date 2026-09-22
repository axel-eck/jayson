import Foundation
import JaysonCore

// MARK: - Helpers

private func schema(_ text: String) throws -> JSONValue {
    try JSONParser.parse(text)
}

private func errors(_ schema: JSONValue, _ instance: JSONValue, file: StaticString = #filePath, line: UInt = #line) -> [SchemaValidationError] {
    do {
        return try SchemaValidator(schema: schema).validate(instance).errors
    } catch {
        fail("schema failed to compile: \(error)", file: file, line: line)
        return []
    }
}

private func expectValid(_ schema: JSONValue, _ instance: JSONValue, file: StaticString = #filePath, line: UInt = #line) {
    let found = errors(schema, instance, file: file, line: line)
    if !found.isEmpty {
        fail("expected valid, got \(found.map(\.description))", file: file, line: line)
    }
}

/// Asserts the instance is invalid and that some error's message contains `fragment`.
private func expectError(_ schema: JSONValue, _ instance: JSONValue, _ fragment: String, keyword: String? = nil, path: String? = nil,
                         file: StaticString = #filePath, line: UInt = #line) {
    let found = errors(schema, instance, file: file, line: line)
    guard let match = found.first(where: { $0.message.contains(fragment) }) else {
        fail("expected error containing '\(fragment)', got \(found.map(\.description))", file: file, line: line)
        return
    }
    if let keyword { expectEqual(match.keyword, keyword, "keyword", file: file, line: line) }
    if let path { expectEqual(match.instancePath.jsonPathString, path, "instance path", file: file, line: line) }
}

func runSchemaValidatorChecks() {
    check("boolean schemas and type keyword") {
        expectValid(true, ["anything": 1])
        expectError(false, 1, "Value is not allowed", keyword: "false")

        let string = try schema(#"{"type": "string"}"#)
        expectValid(string, "hi")
        expectError(string, 5, "Expected string, got number", keyword: "type", path: "$")

        let multi = try schema(#"{"type": ["string", "null"]}"#)
        expectValid(multi, nil)
        expectError(multi, true, "Expected string or null, got boolean")

        let integer = try schema(#"{"type": "integer"}"#)
        expectValid(integer, try JSONParser.parse("1.0"))
        expectValid(integer, 7)
        expectError(integer, 1.5, "Expected integer, got number")
        expectEqual(errors(string, 5).first?.schemaPath, "#/type")
    }

    check("enum and const use semantic JSON equality") {
        let colors = try schema(#"{"enum": ["a", "b", 1, {"x": 1, "y": 2}]}"#)
        expectValid(colors, "a")
        expectValid(colors, try JSONParser.parse("1.0"))
        expectValid(colors, try JSONParser.parse(#"{"y": 2, "x": 1}"#))
        expectError(colors, "c", #"Must be one of: "a", "b", 1, {"x":1,"y":2}"#, keyword: "enum")

        let constant = try schema(#"{"const": {"n": 10}}"#)
        expectValid(constant, try JSONParser.parse(#"{"n": 1e1}"#))
        expectError(constant, ["n": 11], #"Must be equal to {"n":10}"#, keyword: "const")
    }

    check("numeric bounds (draft 6+ numeric exclusives)") {
        let bounds = try schema(#"{"minimum": 3, "maximum": 10}"#)
        expectValid(bounds, 3)
        expectValid(bounds, 10)
        expectError(bounds, 12, "Value 12 exceeds maximum 10", keyword: "maximum")
        expectError(bounds, 1, "Value 1 is less than minimum 3", keyword: "minimum")

        let exclusive = try schema(#"{"exclusiveMinimum": 3, "exclusiveMaximum": 10}"#)
        expectValid(exclusive, 5)
        expectError(exclusive, 3, "Value 3 must be greater than 3", keyword: "exclusiveMinimum")
        expectError(exclusive, 10, "Value 10 must be less than 10", keyword: "exclusiveMaximum")
        expectValid(exclusive, "not a number")
    }

    check("draft-4 boolean exclusiveMinimum/exclusiveMaximum") {
        let draft4 = try schema(#"{"$schema": "http://json-schema.org/draft-04/schema#", "minimum": 3, "exclusiveMinimum": true, "maximum": 10, "exclusiveMaximum": true}"#)
        expectValid(draft4, 4)
        expectError(draft4, 3, "Value 3 must be greater than 3", keyword: "minimum")
        expectError(draft4, 10, "Value 10 must be less than 10", keyword: "maximum")
        let inclusive = try schema(#"{"minimum": 3, "exclusiveMinimum": false}"#)
        expectValid(inclusive, 3)
    }

    check("multipleOf tolerates floating point") {
        let tenth = try schema(#"{"multipleOf": 0.1}"#)
        expectValid(tenth, 0.3)
        expectValid(tenth, 1.7)
        expectValid(tenth, 0)
        expectError(tenth, 0.35, "Value 0.35 is not a multiple of 0.1", keyword: "multipleOf")

        let two = try schema(#"{"multipleOf": 2}"#)
        expectValid(two, 8)
        expectError(two, 7, "Value 7 is not a multiple of 2")
        let hundredth = try schema(#"{"multipleOf": 0.01}"#)
        expectValid(hundredth, 12.34)
        expectError(hundredth, 12.345, "not a multiple")
    }

    check("string length counts unicode scalars and pattern is unanchored") {
        let length = try schema(#"{"minLength": 3, "maxLength": 4}"#)
        expectValid(length, "😀😀😀")
        expectValid(length, "日本語")
        expectError(length, "😀😀", "String length 2 is less than minimum 3", keyword: "minLength")
        expectError(length, "abcde", "String length 5 exceeds maximum 4", keyword: "maxLength")

        let pattern = try schema(#"{"pattern": "^[a-z]+$"}"#)
        expectValid(pattern, "abc")
        expectError(pattern, "abc1", "Does not match pattern '^[a-z]+$'", keyword: "pattern")
        let unanchored = try schema(#"{"pattern": "[0-9]"}"#)
        expectValid(unanchored, "abc5def")
    }

    check("formats: date-time, date, time, email, uuid") {
        let dateTime = try schema(#"{"format": "date-time"}"#)
        expectValid(dateTime, "2024-02-29T12:30:00Z")
        expectValid(dateTime, "2024-01-01t23:59:60.123+05:30")
        expectError(dateTime, "2023-02-29T12:30:00Z", "Not a valid date-time", keyword: "format")
        expectError(dateTime, "2024-01-01 12:30:00Z", "Not a valid date-time")
        expectError(dateTime, "2024-01-01T25:00:00Z", "Not a valid date-time")

        let date = try schema(#"{"format": "date"}"#)
        expectValid(date, "2024-12-31")
        expectError(date, "2024-13-01", "Not a valid date")
        let time = try schema(#"{"format": "time"}"#)
        expectValid(time, "08:30:06Z")
        expectError(time, "08:30:06", "Not a valid time")

        let email = try schema(#"{"format": "email"}"#)
        expectValid(email, "joe.bloggs@example.com")
        expectError(email, "joe.bloggs", "Not a valid email address", keyword: "format")
        expectError(email, "joe@", "Not a valid email address")

        let uuid = try schema(#"{"format": "uuid"}"#)
        expectValid(uuid, "2EB8AA08-AA98-11EA-B4AA-73B441D16380")
        expectError(uuid, "2eb8aa08aa9811eab4aa73b441d16380", "Not a valid UUID")
    }

    check("formats: ipv4, ipv6, hostname, uri, uri-reference, regex, unknown") {
        let ipv4 = try schema(#"{"format": "ipv4"}"#)
        expectValid(ipv4, "192.168.0.1")
        expectError(ipv4, "256.1.1.1", "Not a valid IPv4 address")
        expectError(ipv4, "1.1.1", "Not a valid IPv4 address")
        expectError(ipv4, "01.1.1.1", "Not a valid IPv4 address")

        let ipv6 = try schema(#"{"format": "ipv6"}"#)
        expectValid(ipv6, "::1")
        expectValid(ipv6, "2001:db8::ff00:42:8329")
        expectValid(ipv6, "::ffff:192.168.0.1")
        expectError(ipv6, "12345::", "Not a valid IPv6 address")
        expectError(ipv6, "1:2:3:4:5:6:7:8:9", "Not a valid IPv6 address")
        expectError(ipv6, "1:::2", "Not a valid IPv6 address")

        let hostname = try schema(#"{"format": "hostname"}"#)
        expectValid(hostname, "www.example.com")
        expectValid(hostname, "localhost")
        expectError(hostname, "-bad.example.com", "Not a valid hostname")
        expectError(hostname, "under_score.example", "Not a valid hostname")

        let uri = try schema(#"{"format": "uri"}"#)
        expectValid(uri, "https://example.com/a?b=c#d")
        expectValid(uri, "urn:isbn:0451450523")
        expectError(uri, "/relative/path", "Not a valid URI")
        expectError(uri, "http://example.com/has space", "Not a valid URI")
        let uriReference = try schema(#"{"format": "uri-reference"}"#)
        expectValid(uriReference, "/relative/path")
        expectValid(uriReference, "#frag")
        expectError(uriReference, "\\\\WINDOWS\\share", "Not a valid URI reference")

        let regex = try schema(#"{"format": "regex"}"#)
        expectValid(regex, "^a+$")
        expectError(regex, "([a-z", "Not a valid regular expression")

        let unknown = try schema(#"{"format": "made-up-format"}"#)
        expectValid(unknown, "anything goes")
        expectValid(try schema(#"{"format": "email"}"#), 42)
    }

    check("arrays: items schema, tuple items, additionalItems, prefixItems, min/maxItems") {
        let numbers = try schema(#"{"type": "array", "items": {"type": "number"}, "minItems": 1, "maxItems": 3}"#)
        expectValid(numbers, [1, 2, 3])
        expectError(numbers, [1, "two", 3], "Expected number, got string", keyword: "type", path: "$[1]")
        expectError(numbers, [], "Array has 0 items, expected at least 1", keyword: "minItems")
        expectError(numbers, [1, 2, 3, 4], "Array has 4 items, expected at most 3", keyword: "maxItems")

        let tuple = try schema(#"{"items": [{"type": "string"}, {"type": "number"}], "additionalItems": false}"#)
        expectValid(tuple, ["a", 1])
        expectValid(tuple, ["a"])
        expectError(tuple, [1, 1], "Expected string, got number", path: "$[0]")
        expectError(tuple, ["a", 1, true], "Unexpected item at index 2", keyword: "additionalItems", path: "$[2]")
        let tupleExtra = try schema(#"{"items": [{"type": "string"}], "additionalItems": {"type": "boolean"}}"#)
        expectValid(tupleExtra, ["a", true, false])
        expectError(tupleExtra, ["a", 1], "Expected boolean, got number", path: "$[1]")

        let prefix = try schema(#"{"prefixItems": [{"type": "string"}, {"type": "number"}], "items": false}"#)
        expectValid(prefix, ["a", 1])
        expectError(prefix, ["a", 1, 2], "Unexpected item at index 2", keyword: "items", path: "$[2]")
        let prefixRest = try schema(#"{"prefixItems": [{"type": "string"}], "items": {"type": "integer"}}"#)
        expectValid(prefixRest, ["a", 1, 2])
        expectError(prefixRest, ["a", 1.5], "Expected integer, got number", path: "$[1]")
    }

    check("contains with minContains and maxContains") {
        let contains = try schema(#"{"contains": {"type": "string"}}"#)
        expectValid(contains, [1, "a"])
        expectError(contains, [1, 2], "No items match 'contains' schema", keyword: "contains", path: "$")

        let bounded = try schema(#"{"contains": {"type": "string"}, "minContains": 2, "maxContains": 3}"#)
        expectValid(bounded, ["a", "b", 1])
        expectError(bounded, ["a", 1], "Found 1 item matching 'contains', expected at least 2", keyword: "minContains")
        expectError(bounded, ["a", "b", "c", "d"], "Found 4 items matching 'contains', expected at most 3", keyword: "maxContains")
        let zero = try schema(#"{"contains": {"type": "string"}, "minContains": 0}"#)
        expectValid(zero, [1, 2])
    }

    check("uniqueItems uses semantic equality") {
        let unique = try schema(#"{"uniqueItems": true}"#)
        expectValid(unique, [1, "1", true, [1], ["a": 1]])
        let duplicates = try JSONParser.parse(#"[{"a": 1, "b": 2}, 5, {"b": 2.0, "a": 1}]"#)
        expectError(unique, duplicates, "Array has duplicate items at indices 0 and 2", keyword: "uniqueItems", path: "$")
        expectError(unique, try JSONParser.parse("[1, 1.0]"), "duplicate items at indices 0 and 1")
        expectValid(try schema(#"{"uniqueItems": false}"#), [1, 1])
    }

    check("objects: properties, required, additionalProperties, patternProperties") {
        let person = try schema(#"""
        {
          "type": "object",
          "properties": {"name": {"type": "string"}, "age": {"type": "integer", "minimum": 0}},
          "patternProperties": {"^x-": {"type": "boolean"}},
          "additionalProperties": false,
          "required": ["name", "age"]
        }
        """#)
        expectValid(person, ["name": "Ann", "age": 30, "x-flag": true])

        let missing = errors(person, ["name": "Ann"])
        expectEqual(missing.count, 1)
        expectEqual(missing.first?.message, "Missing required property 'age'")
        expectEqual(missing.first?.instancePath, .root)
        expectEqual(missing.first?.keyword, "required")
        expectEqual(missing.first?.schemaPath, "#/required")

        let extra = errors(person, ["name": "Ann", "age": 1, "email": "a@b.co"])
        expectEqual(extra.count, 1)
        expectEqual(extra.first?.message, "Unexpected property 'email'")
        expectEqual(extra.first?.instancePath.jsonPathString, "$.email")
        expectEqual(extra.first?.keyword, "additionalProperties")
        expectEqual(extra.first?.schemaPath, "#/additionalProperties")

        expectError(person, ["name": "Ann", "age": -1], "Value -1 is less than minimum 0", path: "$.age")
        expectEqual(errors(person, ["name": "Ann", "age": -1]).first?.schemaPath, "#/properties/age/minimum")
        expectError(person, ["name": "Ann", "age": 1, "x-flag": "yes"], "Expected boolean, got string", path: "$['x-flag']")

        let typedExtra = try schema(#"{"properties": {"a": true}, "additionalProperties": {"type": "number"}}"#)
        expectValid(typedExtra, ["a": "s", "b": 1])
        expectError(typedExtra, ["b": "s"], "Expected number, got string", path: "$.b")
    }

    check("objects: propertyNames, minProperties, maxProperties") {
        let names = try schema(#"{"propertyNames": {"pattern": "^[a-z]+$", "maxLength": 3}}"#)
        expectValid(names, ["ab": 1, "c": 2])
        expectError(names, ["AB": 1], "Does not match pattern '^[a-z]+$'", keyword: "pattern", path: "$.AB")
        expectError(names, ["abcd": 1], "String length 4 exceeds maximum 3", path: "$.abcd")

        let sized = try schema(#"{"minProperties": 1, "maxProperties": 2}"#)
        expectValid(sized, ["a": 1])
        expectError(sized, [:], "Object has 0 properties, expected at least 1", keyword: "minProperties")
        expectError(sized, ["a": 1, "b": 2, "c": 3], "Object has 3 properties, expected at most 2", keyword: "maxProperties")
        let one = errors(try schema(#"{"maxProperties": 0}"#), ["a": 1])
        expectEqual(one.first?.message, "Object has 1 property, expected at most 0")
    }

    check("dependentRequired, dependentSchemas and draft-7 dependencies") {
        let dependentRequired = try schema(#"{"dependentRequired": {"card": ["cvv", "expiry"]}}"#)
        expectValid(dependentRequired, ["card": "1", "cvv": "2", "expiry": "3"])
        expectValid(dependentRequired, ["other": 1])
        expectError(dependentRequired, ["card": "1", "cvv": "2"], "Property 'expiry' is required when 'card' is present", keyword: "dependentRequired", path: "$")

        let dependentSchemas = try schema(#"{"dependentSchemas": {"card": {"properties": {"cvv": {"type": "string"}}, "required": ["cvv"]}}}"#)
        expectValid(dependentSchemas, ["card": 1, "cvv": "123"])
        expectError(dependentSchemas, ["card": 1], "Missing required property 'cvv'")
        expectError(dependentSchemas, ["card": 1, "cvv": 123], "Expected string, got number", path: "$.cvv")

        let dependencies = try schema(#"{"dependencies": {"a": ["b"], "c": {"required": ["d"]}}}"#)
        expectValid(dependencies, ["a": 1, "b": 2, "c": 3, "d": 4])
        expectError(dependencies, ["a": 1], "Property 'b' is required when 'a' is present", keyword: "dependencies")
        expectError(dependencies, ["c": 1], "Missing required property 'd'", keyword: "required")
        expectEqual(errors(dependencies, ["c": 1]).first?.schemaPath, "#/dependencies/c/required")
    }

    check("allOf, anyOf, oneOf summaries with nested errors, and not") {
        let all = try schema(#"{"allOf": [{"type": "string"}, {"minLength": 3}]}"#)
        expectValid(all, "abc")
        expectError(all, "ab", "String length 2 is less than minimum 3")
        expectEqual(errors(all, 5).map(\.schemaPath), ["#/allOf/0/type"])

        let any = try schema(#"{"anyOf": [{"type": "string"}, {"type": "number", "minimum": 0}, {"type": "boolean"}]}"#)
        expectValid(any, "s")
        expectValid(any, 3)
        let anyErrors = errors(any, -1)
        expectEqual(anyErrors.count, 2)
        expectEqual(anyErrors[0].message, "Does not match any of 3 schemas")
        expectEqual(anyErrors[0].keyword, "anyOf")
        expectEqual(anyErrors[0].schemaPath, "#/anyOf")
        expectEqual(anyErrors[1].message, "Value -1 is less than minimum 0")
        expectEqual(anyErrors[1].schemaPath, "#/anyOf/1/minimum")

        let one = try schema(#"""
        {"oneOf": [
          {"type": "object", "required": ["cat"], "properties": {"cat": {"type": "string"}}},
          {"type": "object", "required": ["dog", "breed"]},
          {"type": "number"}
        ]}
        """#)
        expectValid(one, ["cat": "tom"])
        expectValid(one, 5)
        let none = errors(one, ["cat": 1])
        expectEqual(none.count, 2)
        expectEqual(none[0].message, "Does not match any of 3 schemas")
        expectEqual(none[0].keyword, "oneOf")
        expectEqual(none[1].message, "Expected string, got number")
        expectEqual(none[1].instancePath.jsonPathString, "$.cat")
        expectEqual(none[1].schemaPath, "#/oneOf/0/properties/cat/type")
        let several = errors(one, ["cat": "tom", "dog": "rex", "breed": "lab"])
        expectEqual(several.count, 1)
        expectEqual(several[0].message, "Matches 2 of 3 schemas, expected exactly one")

        let not = try schema(#"{"not": {"type": "string"}}"#)
        expectValid(not, 1)
        expectError(not, "s", "Must not match schema", keyword: "not", path: "$")
    }

    check("if/then/else") {
        let conditional = try schema(#"""
        {"if": {"properties": {"country": {"const": "US"}}, "required": ["country"]},
         "then": {"required": ["zip"]},
         "else": {"required": ["postcode"]}}
        """#)
        expectValid(conditional, ["country": "US", "zip": "12345"])
        expectValid(conditional, ["country": "UK", "postcode": "SW1"])
        expectError(conditional, ["country": "US"], "Missing required property 'zip'")
        expectError(conditional, ["country": "UK"], "Missing required property 'postcode'")
        expectEqual(errors(conditional, ["country": "UK"]).first?.schemaPath, "#/else/required")
        let thenOnly = try schema(#"{"if": {"type": "string"}, "then": {"minLength": 2}}"#)
        expectValid(thenOnly, 1)
        expectError(thenOnly, "a", "String length 1 is less than minimum 2")
    }

    check("$ref to $defs, definitions, anchors, escaped and percent-encoded pointers") {
        let defs = try schema(#"""
        {
          "$defs": {"positive": {"type": "number", "exclusiveMinimum": 0}, "a/b": {"type": "string"}, "sp ace": {"const": 1},
                    "anchored": {"$anchor": "pos", "type": "integer"}},
          "definitions": {"name": {"type": "string", "minLength": 1}},
          "properties": {
            "n": {"$ref": "#/$defs/positive"},
            "name": {"$ref": "#/definitions/name"},
            "slash": {"$ref": "#/$defs/a~1b"},
            "space": {"$ref": "#/$defs/sp%20ace"},
            "anch": {"$ref": "#pos"},
            "old": {"$ref": "#legacy"},
            "root": {"$ref": "#/properties/n"}
          },
          "allOf": [{"$defs": {"legacy": {"$id": "#legacy", "type": "boolean"}}}]
        }
        """#)
        expectValid(defs, ["n": 5, "name": "x", "slash": "s", "space": 1, "anch": 3, "old": true, "root": 1])
        expectError(defs, ["n": 0], "Value 0 must be greater than 0", path: "$.n")
        expectEqual(errors(defs, ["n": 0]).first?.schemaPath, "#/$defs/positive/exclusiveMinimum")
        expectError(defs, ["name": ""], "String length 0 is less than minimum 1", path: "$.name")
        expectError(defs, ["slash": 1], "Expected string, got number", path: "$.slash")
        expectError(defs, ["space": 2], "Must be equal to 1", path: "$.space")
        expectError(defs, ["anch": 1.5], "Expected integer, got number", path: "$.anch")
        expectError(defs, ["old": "no"], "Expected boolean, got string", path: "$.old")
        expectError(defs, ["root": -1], "must be greater than 0", path: "$.root")

        let missing = try schema(##"{"$ref": "#/$defs/nope"}"##)
        expectError(missing, 1, "Cannot resolve $ref '#/$defs/nope'", keyword: "$ref")
    }

    check("$ref beside other keywords applies both, and $id-based resolution") {
        let sibling = try schema(##"{"$defs": {"s": {"type": "string"}}, "$ref": "#/$defs/s", "minLength": 3}"##)
        expectValid(sibling, "abc")
        expectError(sibling, "ab", "String length 2 is less than minimum 3")
        expectError(sibling, 1, "Expected string, got number")

        let identified = try schema(#"""
        {
          "$id": "https://example.com/schemas/root.json",
          "$defs": {
            "item": {"$id": "item.json", "type": "object", "properties": {"n": {"$ref": "#/$defs/inner"}}, "$defs": {"inner": {"type": "integer"}}},
            "other": {"$id": "https://example.com/other", "$anchor": "tag", "type": "string"}
          },
          "properties": {
            "a": {"$ref": "https://example.com/schemas/item.json"},
            "b": {"$ref": "item.json#/$defs/inner"},
            "c": {"$ref": "https://example.com/other#tag"},
            "d": {"$ref": "root.json#/$defs/other"}
          }
        }
        """#)
        expectValid(identified, ["a": ["n": 1], "b": 2, "c": "s", "d": "t"])
        expectError(identified, ["a": ["n": 1.5]], "Expected integer, got number", path: "$.a.n")
        expectError(identified, ["b": "x"], "Expected integer, got string", path: "$.b")
        expectError(identified, ["c": 1], "Expected string, got number", path: "$.c")
        expectError(identified, ["d": 1], "Expected string, got number", path: "$.d")
    }

    check("recursive tree schema validates nested valid and invalid trees") {
        let tree = try schema(#"""
        {
          "type": "object",
          "properties": {
            "value": {"type": "integer"},
            "children": {"type": "array", "items": {"$ref": "#"}}
          },
          "required": ["value"],
          "additionalProperties": false
        }
        """#)
        let valid = try JSONParser.parse(#"{"value": 1, "children": [{"value": 2, "children": [{"value": 3}]}, {"value": 4}]}"#)
        expectValid(tree, valid)
        let invalid = try JSONParser.parse(#"{"value": 1, "children": [{"value": 2, "children": [{"value": "three", "extra": true}]}, {"children": []}]}"#)
        let found = errors(tree, invalid)
        expectEqual(found.map(\.message), [
            "Expected integer, got string",
            "Unexpected property 'extra'",
            "Missing required property 'value'",
        ])
        expectEqual(found.map(\.instancePath.jsonPathString), ["$.children[0].children[0].value", "$.children[0].children[0].extra", "$.children[1]"])
        expectEqual(found[0].schemaPath, "#/properties/value/type")
    }

    check("pathological {\"$ref\": \"#\"} root terminates with an error") {
        let loop = try schema(##"{"$ref": "#"}"##)
        let found = errors(loop, ["any": "thing"])
        expectEqual(found.count, 1)
        expectEqual(found.first?.keyword, "$ref")
        expectEqual(found.first?.message, "Circular $ref '#' does not terminate")

        let mutual = try schema(##"{"$defs": {"a": {"$ref": "#/$defs/b"}, "b": {"allOf": [{"$ref": "#/$defs/a"}]}}, "$ref": "#/$defs/a"}"##)
        let mutualErrors = errors(mutual, 1)
        expectEqual(mutualErrors.count, 1)
        expect(mutualErrors.first?.message.hasPrefix("Circular $ref") == true, "expected circular error, got \(mutualErrors)")

        let progressing = try schema(##"{"$defs": {"node": {"anyOf": [{"type": "null"}, {"type": "object", "properties": {"next": {"$ref": "#/$defs/node"}}}]}}, "$ref": "#/$defs/node"}"##)
        expectValid(progressing, ["next": ["next": ["next": nil]]])
        let deep = errors(progressing, ["next": ["next": 5]])
        expectEqual(deep.map(\.instancePath.jsonPathString), ["$", "$.next", "$.next.next", "$.next.next"])
        expectEqual(deep.last?.message, "Expected null, got number")
        expect(deep.allSatisfy { !$0.message.hasPrefix("Circular") }, "progressing recursion is not flagged as circular")
    }

    check("external $ref produces a single error instead of crashing") {
        let external = try schema(#"{"properties": {"a": {"$ref": "https://example.com/other.json#/definitions/x"}, "b": {"$ref": "other.json"}}}"#)
        let found = errors(external, ["a": 1, "b": 2])
        expectEqual(found.count, 2)
        expectEqual(found[0].message, "External $ref 'https://example.com/other.json#/definitions/x' is not supported")
        expectEqual(found[0].keyword, "$ref")
        expectEqual(found[0].instancePath.jsonPathString, "$.a")
        expectEqual(found[0].schemaPath, "#/properties/a/$ref")
        expectEqual(found[1].message, "External $ref 'other.json' is not supported")
        let metaSchema = try schema(#"{"$ref": "http://json-schema.org/draft-07/schema#"}"#)
        expectError(metaSchema, 1, "External $ref 'http://json-schema.org/draft-07/schema#' is not supported")
    }

    check("compile errors: invalid regex and non-schema where a schema is expected") {
        do {
            _ = try SchemaValidator(schema: try schema(#"{"properties": {"a": {"pattern": "([a-"}}}"#))
            fail("expected compile error")
        } catch let error as SchemaCompileError {
            expectEqual(error.message, "Invalid regular expression '([a-'")
            expectEqual(error.schemaPath, "#/properties/a/pattern")
        }
        do {
            _ = try SchemaValidator(schema: try schema(#"{"patternProperties": {"(": true}}"#))
            fail("expected compile error")
        } catch let error as SchemaCompileError {
            expectEqual(error.schemaPath, "#/patternProperties/(")
        }
        do {
            _ = try SchemaValidator(schema: try schema(#"{"items": {"properties": {"x": "string"}}}"#))
            fail("expected compile error")
        } catch let error as SchemaCompileError {
            expectEqual(error.message, "Expected a schema (object or boolean), got string")
            expectEqual(error.schemaPath, "#/items/properties/x")
        }
        expectThrows { _ = try SchemaValidator(schema: "not a schema") }
        expectThrows { _ = try SchemaValidator(schema: try schema(#"{"allOf": {"type": "string"}}"#)) }
        expectThrows { _ = try SchemaValidator(schema: try schema(#"{"properties": [1]}"#)) }
        expectThrows { _ = try SchemaValidator(schema: try schema(#"{"dependencies": {"a": 5}}"#)) }
        // Well-formed schemas compile, including booleans in schema positions and array-form dependencies.
        _ = try SchemaValidator(schema: try schema(#"{"items": false, "not": true, "dependencies": {"a": ["b"]}, "properties": {"pattern": {"type": "string"}}}"#))
        _ = try SchemaValidator(schema: true)

        let convenience = SchemaValidator.validate(1, against: try schema(#"{"pattern": "["}"#))
        expectEqual(convenience.errors.count, 1)
        expectEqual(convenience.errors.first?.keyword, "schema")
        expectEqual(convenience.errors.first?.instancePath, .root)
        expectEqual(convenience.errors.first?.schemaPath, "#/pattern")
        expect(SchemaValidator.validate("x", against: try schema(#"{"type": "string"}"#)).isValid)
        expect(!SchemaValidator.validate(1, against: try schema(#"{"type": "string"}"#)).isValid)
    }

    check("collects all errors in document order, de-duplicated, with stable ids") {
        let combined = try schema(#"""
        {
          "type": "object",
          "required": ["id"],
          "properties": {
            "a": {"type": "string", "minLength": 2},
            "b": {"type": "integer"},
            "c": {"allOf": [{"type": "string"}, {"type": "string"}]}
          }
        }
        """#)
        let instance = try JSONParser.parse(#"{"a": "x", "b": 1.5, "c": 1}"#)
        let result = try SchemaValidator(schema: combined).validate(instance)
        expect(!result.isValid)
        expectEqual(result.errors.map(\.instancePath.jsonPathString), ["$", "$.a", "$.b", "$.c", "$.c"])
        expectEqual(result.errors.map(\.keyword), ["required", "minLength", "type", "type", "type"])
        expectEqual(Set(result.errors.map(\.id)).count, result.errors.count, "ids are unique")
        expectEqual(result.errors[1].id, "/a|#/properties/a/minLength|String length 1 is less than minimum 2")
        expectEqual(result.errors[1].description, "$.a: String length 1 is less than minimum 2")
        expectEqual(result, try SchemaValidator(schema: combined).validate(instance), "results are deterministic")

        let duplicated = try schema(##"{"allOf": [{"$ref": "#/$defs/s"}, {"$ref": "#/$defs/s"}], "$defs": {"s": {"type": "string"}}}"##)
        expectEqual(errors(duplicated, 1).count, 1, "identical errors from the same schema location are de-duplicated")
    }

    check("annotations and unknown keywords are ignored; type-specific keywords ignore other types") {
        let annotated = try schema(#"""
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "$comment": "c", "title": "T", "description": "D", "default": 5, "examples": [1, 2],
          "deprecated": true, "readOnly": true, "writeOnly": false, "x-custom": {"anything": [1]},
          "minimum": 1, "minLength": 5, "minItems": 5, "minProperties": 5, "required": ["a"], "pattern": "^x$"
        }
        """#)
        expectValid(annotated, 3)
        expectValid(annotated, nil)
        expectValid(annotated, true)
        expectError(annotated, "ab", "String length 2 is less than minimum 5")
        expectError(annotated, [1], "Array has 1 item, expected at least 5")
        expectError(annotated, ["b": 1], "Missing required property 'a'")
        let validator = try SchemaValidator(schema: annotated)
        expectEqual(validator.schema, annotated)
    }
}
