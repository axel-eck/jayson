import Foundation

/// Minimal assertion harness. Each suite is a plain function that calls `check`.
nonisolated(unsafe) var checkPasses = 0
nonisolated(unsafe) var checkFailures: [String] = []
nonisolated(unsafe) private var currentCheck = ""

func check(_ name: String, _ body: () throws -> Void) {
    currentCheck = name
    let before = checkFailures.count
    do {
        try body()
    } catch {
        fail("threw \(error)")
    }
    if checkFailures.count == before {
        checkPasses += 1
        print("  ✓ \(name)")
    } else {
        print("  ✗ \(name)")
    }
}

func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    let location = "\(URL(fileURLWithPath: "\(file)").lastPathComponent):\(line)"
    checkFailures.append("[\(currentCheck)] \(location): \(message)")
    print("      \(location): \(message)")
}

func expect(_ condition: Bool, _ message: String = "expected true", file: StaticString = #filePath, line: UInt = #line) {
    if !condition { fail(message, file: file, line: line) }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    if actual != expected {
        fail("\(message.isEmpty ? "" : message + ": ")expected \(expected), got \(actual)", file: file, line: line)
    }
}

func expectNil<T>(_ value: T?, _ message: String = "expected nil", file: StaticString = #filePath, line: UInt = #line) {
    if let value { fail("\(message), got \(value)", file: file, line: line) }
}

func expectThrows(_ message: String = "expected an error", file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
    do {
        try body()
        fail(message, file: file, line: line)
    } catch {}
}

func suite(_ name: String, _ body: () -> Void) {
    print("\(name)")
    body()
}
