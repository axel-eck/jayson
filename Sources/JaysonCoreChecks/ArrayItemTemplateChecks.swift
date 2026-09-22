import Foundation
import JaysonCore

func runArrayItemTemplateChecks() {
    let books: JSONValue = [
        ["title": "A", "price": 8.95, "tags": ["x"]],
        ["title": "B", "price": 12, "isbn": "1"],
    ]
    let root: JSONValue = ["store": ["book": books]]
    let path = ValuePath([.key("store"), .key("book")])

    check("template is inferred from siblings when no schema is loaded") {
        let result = ArrayItemTemplate.make(forArrayAt: path, elements: books.arrayValue!, schema: nil)
        expectEqual(result.source, .inferredFromSiblings(count: 2))
        let object = result.value.objectValue
        expectEqual(object?.keys, ["title", "price", "tags", "isbn"])
        expectEqual(object?["title"], "")
        expectEqual(object?["price"], 0)
        expectEqual(object?["tags"], [])
        expectEqual(object?["isbn"], "")
    }

    check("template comes from the loaded schema when it describes the array") {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "store": [
                    "type": "object",
                    "properties": [
                        "book": ["type": "array", "items": ["$ref": "#/$defs/book"]],
                    ],
                ],
            ],
            "$defs": [
                "book": [
                    "type": "object",
                    "properties": ["title": ["type": "string"], "year": ["type": "integer", "minimum": 1900]],
                    "required": ["title"],
                ],
            ],
        ]
        let result = ArrayItemTemplate.make(forArrayAt: path, elements: books.arrayValue!, schema: schema)
        expectEqual(result.source, .schema)
        expectEqual(result.value, ["title": "", "year": 1900])
        let validation = SchemaValidator.validate(result.value, against: result.schema!)
        expect(validation.isValid, "template should satisfy its own schema: \(validation.errors)")
    }

    check("empty array without schema gets an empty object") {
        let result = ArrayItemTemplate.make(forArrayAt: path, elements: [], schema: nil)
        expectEqual(result.source, .empty)
        expectEqual(result.value, [:])
    }

    check("scalar arrays infer a scalar template") {
        let result = ArrayItemTemplate.make(forArrayAt: ValuePath([.key("tags")]), elements: ["a", "b"], schema: nil)
        expectEqual(result.value, "")
    }

    check("inserting the template keeps the document valid against the inferred schema") {
        var doc = root
        let inferred = SchemaInferrer.infer(from: doc)
        let result = ArrayItemTemplate.make(forArrayAt: path, elements: books.arrayValue!, schema: inferred)
        expectEqual(result.source, .schema)
        try doc.insert(result.value, intoArrayAt: path)
        expectEqual(doc.value(at: path)?.childCount, 3)
        expect(SchemaValidator.validate(doc, against: inferred).isValid)
    }
}

func runSchemaLocatorChecks() {
    let schema: JSONValue = [
        "type": "object",
        "properties": [
            "users": [
                "type": "array",
                "items": ["$ref": "#/$defs/user"],
            ],
            "matrix": ["type": "array", "prefixItems": [["type": "integer"]], "items": ["type": "number"]],
            "legacy": ["type": "array", "items": [["type": "string"]], "additionalItems": ["type": "boolean"]],
        ],
        "patternProperties": ["^x-": ["type": "string"]],
        "additionalProperties": ["type": "null"],
        "$defs": [
            "user": [
                "type": "object",
                "properties": ["name": ["type": "string"], "address": ["$ref": "#address"]],
            ],
            "address": ["$anchor": "address", "type": "object", "properties": ["city": ["type": "string"]]],
        ],
    ]

    check("subschema follows properties, items and $ref") {
        let path = ValuePath([.key("users"), .index(3), .key("address"), .key("city")])
        expectEqual(SchemaLocator.subschema(at: path, in: schema), ["type": "string"])
    }

    check("subschema resolves patternProperties and additionalProperties") {
        expectEqual(SchemaLocator.subschema(at: ValuePath([.key("x-trace")]), in: schema), ["type": "string"])
        expectEqual(SchemaLocator.subschema(at: ValuePath([.key("other")]), in: schema), ["type": "null"])
    }

    check("newItemSchema handles items, prefixItems and draft-4 tuple forms") {
        expectEqual(SchemaLocator.newItemSchema(forArrayAt: ValuePath([.key("users")]), in: schema)?["type"], "object")
        expectEqual(SchemaLocator.newItemSchema(forArrayAt: ValuePath([.key("matrix")]), in: schema), ["type": "number"])
        expectEqual(SchemaLocator.newItemSchema(forArrayAt: ValuePath([.key("legacy")]), in: schema), ["type": "boolean"])
        expectNil(SchemaLocator.newItemSchema(forArrayAt: ValuePath([.key("missing")]), in: schema))
    }

    check("external refs and dangling pointers resolve to nil") {
        expectNil(SchemaLocator.resolveLocalRef("https://example.com/s.json#/a", in: schema))
        expectNil(SchemaLocator.resolveLocalRef("#/$defs/nope", in: schema))
        expectEqual(SchemaLocator.resolveLocalRef("#", in: schema), schema)
    }
}
