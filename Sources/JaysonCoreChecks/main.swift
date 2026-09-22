import Foundation

suite("JSONValue") { runJSONValueChecks() }
suite("JSONPath") { runJSONPathChecks() }
suite("TextSearch") { runTextSearchChecks() }
suite("SchemaValidator") { runSchemaValidatorChecks() }
suite("SchemaInference") { runSchemaInferenceChecks() }
suite("SchemaInstance") { runSchemaInstanceChecks() }
suite("SchemaLocator") { runSchemaLocatorChecks() }
suite("ArrayItemTemplate") { runArrayItemTemplateChecks() }

print("")
if checkFailures.isEmpty {
    print("All \(checkPasses) checks passed.")
    exit(0)
} else {
    print("\(checkFailures.count) failure(s), \(checkPasses) passed:")
    for failure in checkFailures { print("  \(failure)") }
    exit(1)
}
