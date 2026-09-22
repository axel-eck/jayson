import Foundation

/// Builds the value to insert when the user adds a new element to an array.
///
/// Preference order: the loaded schema's `items` for that array, then a schema inferred
/// from the existing elements ("auto-detect the shape"), then an empty object.
public enum ArrayItemTemplate {
    public enum Source: Equatable, Sendable {
        case schema
        case inferredFromSiblings(count: Int)
        case empty
    }

    public struct Result: Equatable, Sendable {
        public let value: JSONValue
        public let source: Source
        /// The schema the template was generated from (nil for `.empty`).
        public let schema: JSONValue?
    }

    public static func make(forArrayAt arrayPath: ValuePath, elements: [JSONValue], schema: JSONValue?) -> Result {
        var instanceOptions = SchemaInstanceOptions()
        instanceOptions.useSampleValues = false

        if let schema, let itemSchema = SchemaLocator.newItemSchema(forArrayAt: arrayPath, in: schema) {
            let value = SchemaInstanceGenerator.makeInstance(from: itemSchema, root: schema, options: instanceOptions)
            return Result(value: value, source: .schema, schema: itemSchema)
        }

        guard !elements.isEmpty else {
            return Result(value: .object(JSONObject()), source: .empty, schema: nil)
        }

        var inferenceOptions = SchemaInferenceOptions()
        inferenceOptions.addSchemaKeyword = false
        inferenceOptions.detectFormats = true
        let inferred = SchemaInferrer.infer(fromSamples: elements, options: inferenceOptions)
        let value = SchemaInstanceGenerator.makeInstance(from: inferred, options: instanceOptions)
        return Result(value: value, source: .inferredFromSiblings(count: elements.count), schema: inferred)
    }
}
