import Foundation
import JaysonCore

private let bookstoreText = """
{ "store": {
    "book": [
      { "category": "reference", "author": "Nigel Rees", "title": "Sayings of the Century", "price": 8.95 },
      { "category": "fiction", "author": "Evelyn Waugh", "title": "Sword of Honour", "price": 12.99 },
      { "category": "fiction", "author": "Herman Melville", "title": "Moby Dick", "isbn": "0-553-21311-3", "price": 8.99 },
      { "category": "fiction", "author": "J. R. R. Tolkien", "title": "The Lord of the Rings", "isbn": "0-395-19395-8", "price": 22.99 }
    ],
    "bicycle": { "color": "red", "price": 19.95 }
  }
}
"""

private func query(_ expression: String, _ root: JSONValue) throws -> [JSONPathMatch] {
    try JSONPathQuery.evaluate(expression, on: root)
}

private func values(_ expression: String, _ root: JSONValue) throws -> [JSONValue] {
    try query(expression, root).map(\.value)
}

private func paths(_ expression: String, _ root: JSONValue) throws -> [String] {
    try query(expression, root).map(\.path.jsonPathString)
}

private func authors(_ expression: String, _ root: JSONValue) throws -> [JSONValue] {
    try query(expression, root).compactMap { $0.value["author"] }
}

private func expectError(_ expression: String, position: Int, messagePrefix: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
    do {
        _ = try JSONPathQuery(expression)
        fail("expected \(expression) to fail", file: file, line: line)
    } catch let error as JSONPathError {
        expectEqual(error.position, position, "position for \(expression) (\(error.message))", file: file, line: line)
        if let messagePrefix {
            expect(error.message.hasPrefix(messagePrefix), "message for \(expression): \(error.message)", file: file, line: line)
        }
    } catch {
        fail("wrong error type \(error)", file: file, line: line)
    }
}

func runJSONPathChecks() {
    let store: JSONValue
    do {
        store = try JSONParser.parse(bookstoreText)
    } catch {
        check("bookstore fixture parses") { fail("\(error)") }
        return
    }

    // MARK: Goessner examples

    check("goessner: $.store.book[*].author") {
        expectEqual(try values("$.store.book[*].author", store), ["Nigel Rees", "Evelyn Waugh", "Herman Melville", "J. R. R. Tolkien"])
    }

    check("goessner: $..author with result paths") {
        let matches = try query("$..author", store)
        expectEqual(matches.map(\.value), ["Nigel Rees", "Evelyn Waugh", "Herman Melville", "J. R. R. Tolkien"])
        expectEqual(matches.map(\.path.jsonPathString), [
            "$.store.book[0].author", "$.store.book[1].author", "$.store.book[2].author", "$.store.book[3].author",
        ])
        expectEqual(matches.map(\.path.jsonPointer), ["/store/book/0/author", "/store/book/1/author", "/store/book/2/author", "/store/book/3/author"])
    }

    check("goessner: $.store.* and $.store..price") {
        let all = try query("$.store.*", store)
        expectEqual(all.map(\.path.jsonPathString), ["$.store.book", "$.store.bicycle"])
        expectEqual(all[0].value.childCount, 4)
        expectEqual(try values("$.store..price", store), [8.95, 12.99, 8.99, 22.99, 19.95])
    }

    check("goessner: $..book[2], $..book[-1:], $..book[0,1], $..book[:2]") {
        expectEqual(try authors("$..book[2]", store), ["Herman Melville"])
        expectEqual(try paths("$..book[2]", store), ["$.store.book[2]"])
        expectEqual(try authors("$..book[-1:]", store), ["J. R. R. Tolkien"])
        expectEqual(try authors("$..book[-1]", store), ["J. R. R. Tolkien"])
        expectEqual(try authors("$..book[0,1]", store), ["Nigel Rees", "Evelyn Waugh"])
        expectEqual(try authors("$..book[:2]", store), ["Nigel Rees", "Evelyn Waugh"])
    }

    check("goessner: $..book[?(@.isbn)] and $..book[?(@.price<10)]") {
        expectEqual(try authors("$..book[?(@.isbn)]", store), ["Herman Melville", "J. R. R. Tolkien"])
        expectEqual(try authors("$..book[?(@.price<10)]", store), ["Nigel Rees", "Herman Melville"])
        expectEqual(try authors("$..book[?@.price < 10]", store), ["Nigel Rees", "Herman Melville"], "parenthesis-free filter")
    }

    check("goessner: $..* visits every member (27) and $..[*] agrees") {
        let all = try query("$..*", store)
        expectEqual(all.count, 27)
        expectEqual(Set(all.map(\.path)).count, 27, "paths are unique")
        expectEqual(try query("$..[*]", store).count, 27)
        expectEqual(Array(try paths("$..*", store).prefix(3)), ["$.store", "$.store.book", "$.store.book[0]"], "strict document order")
        expectEqual(try paths("$..*", store).last, "$.store.bicycle.price")
    }

    // MARK: Filters

    check("filters: && || ! and grouping") {
        expectEqual(try authors("$..book[?(@.price > 10 && @.category == 'fiction')]", store), ["Evelyn Waugh", "J. R. R. Tolkien"])
        expectEqual(try authors("$..book[?(@.price < 9 || @.isbn)]", store), ["Nigel Rees", "Herman Melville", "J. R. R. Tolkien"])
        expectEqual(try authors("$..book[?(!@.isbn)]", store), ["Nigel Rees", "Evelyn Waugh"])
        expectEqual(try authors("$..book[?!(@.isbn)]", store), ["Nigel Rees", "Evelyn Waugh"])
        expectEqual(try authors("$..book[?((@.price < 9 || @.price > 20) && @.isbn)]", store), ["Herman Melville", "J. R. R. Tolkien"])
        expectEqual(try authors("$..book[?(@.price < 9 || @.price > 20 && @.isbn)]", store), ["Nigel Rees", "Herman Melville", "J. R. R. Tolkien"], "&& binds tighter than ||")
        expectEqual(try authors(#"$..book[?(@.category == "fiction" && !(@.price >= 12.99))]"#, store), ["Herman Melville"])
    }

    check("filters: comparison operators and literal types") {
        expectEqual(try authors("$..book[?(@.price == 8.95)]", store), ["Nigel Rees"])
        expectEqual(try authors("$..book[?(@.price != 8.95)]", store).count, 3)
        expectEqual(try authors("$..book[?(@.price <= 8.99)]", store), ["Nigel Rees", "Herman Melville"])
        expectEqual(try authors("$..book[?(@.price >= 22.99)]", store), ["J. R. R. Tolkien"])
        expectEqual(try authors("$..book[?(@.price > 1e1)]", store), ["Evelyn Waugh", "J. R. R. Tolkien"])
        expectEqual(try authors("$..book[?(@.author > 'H')]", store), ["Nigel Rees", "Herman Melville", "J. R. R. Tolkien"], "string ordering")
        let mixed: JSONValue = [["x": nil, "f": true], ["x": 1, "f": false], ["y": 2]]
        expectEqual(try paths("$[?(@.x == null)]", mixed), ["$[0]"])
        expectEqual(try paths("$[?(@.f == true)]", mixed), ["$[0]"])
        expectEqual(try paths("$[?(@.f == false)]", mixed), ["$[1]"])
        expectEqual(try paths("$[?(@.x != 1)]", mixed), ["$[0]", "$[2]"], "missing != value is true")
        expectEqual(try paths("$[?(@.x == @.missing)]", mixed), ["$[2]"], "nothing == nothing")
        expectEqual(try paths("$[?(@.f)]", mixed), ["$[0]", "$[1]"], "existence test is true for false values")
    }

    check("filters: ordering across types is false, equality is semantic") {
        expectEqual(try authors("$..book[?(@.author < 10)]", store), [])
        expectEqual(try authors("$..book[?(@.price > 'a')]", store), [])
        expectEqual(try authors("$..book[?(@.price == '8.95')]", store), [])
        let doc: JSONValue = [["n": 1.0], ["n": 1], ["n": "1"], ["o": ["b": 1, "a": 2]]]
        expectEqual(try paths("$[?(@.n == 1)]", doc), ["$[0]", "$[1]"])
        expectEqual(try paths("$[?(@.o == $[3].o)]", doc), ["$[3]"])
        let other: JSONValue = [["o": ["a": 2, "b": 1]]]
        expectEqual(try paths("$[?(@.o == $[0].o)]", other), ["$[0]"], "object equality ignores key order")
    }

    check("filters: $-rooted operands and any-match for multi-node operands") {
        expectEqual(try authors("$..book[?(@.price > $.store.bicycle.price)]", store), ["J. R. R. Tolkien"])
        expectEqual(try authors("$..book[?($.store.bicycle.color == 'red')]", store).count, 4)
        let doc: JSONValue = ["a": [["tags": ["x", "y"]], ["tags": ["z"]], ["tags": []]]]
        expectEqual(try paths("$.a[?(@.tags[*] == 'y')]", doc), ["$.a[0]"])
        expectEqual(try paths("$.a[?(@.tags[*] != 'x')]", doc), ["$.a[0]", "$.a[1]"])
        expectEqual(try paths("$.a[?(@.tags[*] > 'x')]", doc), ["$.a[0]", "$.a[1]"])
        expectEqual(try paths("$.a[?(@.tags[*])]", doc), ["$.a[0]", "$.a[1]"], "empty node list is not truthy")
        expectEqual(try paths("$.a[?(@.tags..* == 'z')]", doc), ["$.a[1]"])
    }

    check("filters: regex with flags, escaped slash and quoted pattern") {
        expectEqual(try authors(#"$..book[?(@.author =~ /^j\. r\. r\./i)]"#, store), ["J. R. R. Tolkien"])
        expectEqual(try authors(#"$..book[?(@.author =~ /^j\. r\. r\./)]"#, store), [])
        expectEqual(try authors("$..book[?(@.title =~ /sword|moby/i)]", store), ["Evelyn Waugh", "Herman Melville"])
        expectEqual(try authors("$..book[?(@.price =~ /9/)]", store), [], "regex only matches strings")
        expectEqual(try authors(#"$..book[?(@.isbn =~ /^\d-\d{3}-\d{5}-\d$/)]"#, store), ["Herman Melville", "J. R. R. Tolkien"])
        let doc: JSONValue = ["a": ["x/y", "xy"]]
        expectEqual(try paths(#"$.a[?(@ =~ /x\/y/)]"#, doc), ["$.a[0]"])
        expectEqual(try paths(#"$.a[?(@ =~ "^xy$")]"#, doc), ["$.a[1]"])
    }

    check("filters: apply to object members, nested filters, scalar children") {
        expectEqual(try paths("$.store[?(@.color)]", store), ["$.store.bicycle"])
        expectEqual(try paths("$.store[?(@[0].price < 9)]", store), ["$.store.book"])
        expectEqual(try paths("$..[?(@.price > 15)]", store), ["$.store.book[3]", "$.store.bicycle"])
        let doc: JSONValue = ["groups": [["items": [["ok": true], ["ok": false]]], ["items": [["ok": false]]]]]
        expectEqual(try paths("$.groups[?(@.items[?(@.ok == true)])]", doc), ["$.groups[0]"])
        expectEqual(try paths("$..items[?(@.ok == false)]", doc), ["$.groups[0].items[1]", "$.groups[1].items[0]"])
        expectEqual(try paths("$[?(@ > 1)]", [1, 2, 3]), ["$[1]", "$[2]"])
        expectEqual(try paths("$[?(@.x)]", [1, "s", nil, true]), [])
    }

    // MARK: Names and brackets

    check("bracket names with spaces, quotes, escapes and unions") {
        let doc = try JSONParser.parse(#"{"odd key": 1, "it's": 2, "q\"uote": 3, "back\\slash": 4, "tab\there": 5, "a": {"b": 6}}"#)
        expectEqual(try values("$['odd key']", doc), [1])
        expectEqual(try paths("$['odd key']", doc), ["$['odd key']"])
        expectEqual(try values(#"$["it's"]"#, doc), [2])
        expectEqual(try values(#"$['it\'s']"#, doc), [2])
        expectEqual(try paths(#"$['it\'s']"#, doc), [#"$['it\'s']"#])
        expectEqual(try values(#"$["q\"uote"]"#, doc), [3])
        expectEqual(try values(#"$['back\\slash']"#, doc), [4])
        expectEqual(try values(#"$['tab\there']"#, doc), [5])
        expectEqual(try values(#"$['tab\u0009here']"#, doc), [5])
        expectEqual(try values("$['odd key', 'a']", doc), [1, ["b": 6]])
        expectEqual(try values("$[ 'a' ][ \"b\" ]", doc), [6])
        expectEqual(try values("$['a'].b", doc), [6])
        expectEqual(try values("$.a['b']", doc), [6])
        expectEqual(try values("$.store.book[0]['author', 'title']", store), ["Nigel Rees", "Sayings of the Century"])
        expectEqual(try values("$.store.book[0]['title', 'author']", store), ["Sayings of the Century", "Nigel Rees"], "union keeps written order")
        expectEqual(try values("$['missing']", doc), [])
    }

    check("dot names: digits, underscores, dashes and non-ASCII; bare expressions") {
        let doc: JSONValue = ["café": 1, "naïve-name": 2, "_x9": 3, "日本": ["語": 4], "store": ["book": [["author": "A"]]]]
        expectEqual(try values("$.café", doc), [1])
        expectEqual(try values("$.naïve-name", doc), [2])
        expectEqual(try values("$._x9", doc), [3])
        expectEqual(try values("$.日本.語", doc), [4])
        expectEqual(try values("store.book[0].author", doc), ["A"], "bare expression")
        expectEqual(try paths("store.book[0].author", doc), ["$.store.book[0].author"])
        expectEqual(try values("café", doc), [1])
        expectEqual(try values("['naïve-name']", doc), [2], "bare bracket")
        expectEqual(try values(".café", doc), [1], "bare leading dot")
        expectEqual(try values("..author", doc), ["A"], "bare descendant")
        expectEqual(try query("*", doc).count, 5)
        expectEqual(try values("[0]", [7, 8]), [7])
        expectEqual(try query("  $  ", doc).map(\.path), [.root], "root with surrounding whitespace")
        expectEqual(try query("$", doc).first?.value, doc)
    }

    // MARK: Indices and slices

    check("indices and slices with omitted parts, negatives and negative step") {
        let arr: JSONValue = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
        expectEqual(try values("$[0]", arr), [0])
        expectEqual(try values("$[-1]", arr), [9])
        expectEqual(try values("$[-10]", arr), [0])
        expectEqual(try values("$[10]", arr), [])
        expectEqual(try values("$[-11]", arr), [])
        expectEqual(try values("$[0, 2, -1]", arr), [0, 2, 9])
        expectEqual(try values("$[2:5]", arr), [2, 3, 4])
        expectEqual(try values("$[7:]", arr), [7, 8, 9])
        expectEqual(try values("$[:3]", arr), [0, 1, 2])
        expectEqual(try values("$[-3:]", arr), [7, 8, 9])
        expectEqual(try values("$[:-7]", arr), [0, 1, 2])
        expectEqual(try values("$[1:8:3]", arr), [1, 4, 7])
        expectEqual(try values("$[::4]", arr), [0, 4, 8])
        expectEqual(try values("$[::-1]", arr), [9, 8, 7, 6, 5, 4, 3, 2, 1, 0])
        expectEqual(try values("$[-1:-4:-1]", arr), [9, 8, 7])
        expectEqual(try values("$[8:1:-3]", arr), [8, 5, 2])
        expectEqual(try values("$[:5:-1]", arr), [9, 8, 7, 6])
        expectEqual(try values("$[3::-1]", arr), [3, 2, 1, 0])
        expectEqual(try values("$[::0]", arr), [])
        expectEqual(try values("$[5:2]", arr), [])
        expectEqual(try values("$[100:200]", arr), [])
        expectEqual(try values("$[-100:2]", arr), [0, 1])
        expectEqual(try values("$[ 1 : 3 ]", arr), [1, 2])
        expectEqual(try paths("$[::-1]", [1, 2]), ["$[1]", "$[0]"], "paths follow the reversed order")
        expectEqual(try values("$[::9223372036854775807]", arr), [0], "huge step does not overflow")
        expectEqual(try values("$[0:5:-9223372036854775807]", arr), [])
        expectEqual(try values("$[-9223372036854775808]", arr), [])
        expectEqual(try values("$[0:1]", ["a": 1]), [], "slice on object")
        expectEqual(try values("$[0]", ["a": 1]), [], "index on object")
        expectEqual(try values("$.a", [1, 2]), [], "name on array")
    }

    // MARK: Recursive descent

    check("recursive descent variants and de-duplication") {
        let doc: JSONValue = ["a": ["a": ["a": 1, "b": [10, 20]], "b": [30]], "b": [40]]
        expectEqual(try paths("$..a", doc), ["$.a", "$.a.a", "$.a.a.a"])
        expectEqual(try paths("$..a..a", doc), ["$.a.a", "$.a.a.a"], "overlapping subtrees are de-duplicated")
        expectEqual(try paths("$..['b']", doc), ["$.a.a.b", "$.a.b", "$.b"], "strict document order")
        expectEqual(try paths("$..[0]", doc), ["$.a.a.b[0]", "$.a.b[0]", "$.b[0]"])
        expectEqual(try values("$..[0]", doc), [10, 30, 40])
        expectEqual(try values("$..b[-1]", doc), [20, 30, 40])
        expectEqual(try values("$..b[-1, 0]", doc), [20, 10, 30, 40], "child-segment unions keep written order")
        expectEqual(try values("$..[1, 0]", doc), [10, 20, 30, 40], "descendant unions are in document order")
        expectEqual(try values("$..b[1:]", doc), [20])
        expectEqual(try paths("$..[*]", doc).count, 10)
        expectEqual(try paths("$..*..*", doc).count, try paths("$..*", doc).count - 2, "$..*..* excludes the root's direct children")
        expectEqual(try paths("$..[?(@ > 15)]", doc), ["$.a.a.b[1]", "$.a.b[0]", "$.b[0]"])
        expectEqual(try query("$..*", doc).count, 10)
        expectEqual(try query("$..*", "scalar").count, 0)
        expectEqual(try query("$..x", 42).count, 0)
    }

    // MARK: length

    check(".length on arrays and strings, real `length` keys win") {
        let doc: JSONValue = ["items": [1, 2, 3], "name": "abcd", "obj": ["length": "real"], "n": 5, "empty": [], "emoji": "a😀"]
        let items = try query("$.items.length", doc)
        expectEqual(items.map(\.value), [3])
        expectEqual(items.map(\.path.jsonPathString), ["$.items.length"])
        expectEqual(try values("$.name.length", doc), [4])
        expectEqual(try values("$.emoji.length", doc), [2])
        expectEqual(try values("$.empty.length", doc), [0])
        expectEqual(try values("$.obj.length", doc), ["real"])
        expectEqual(try values("$.n.length", doc), [])
        expectEqual(try values("$.obj['length']", doc), ["real"])
        expectEqual(try values("$.items['length']", doc), [3])
        expectEqual(try values("$..length", doc), ["real"], "descendant search only finds real keys")
        expectEqual(try paths("$..[?(@.length > 3)]", doc), ["$.name", "$.obj.length"], "the string \"real\" has length 4")
        expectEqual(try paths("$..[?(@.length == 3)]", doc), ["$.items"])
        let tagged: JSONValue = [["tags": ["a", "b", "c"]], ["tags": ["a"]], ["tags": "abc"]]
        expectEqual(try paths("$[?(@.tags.length > 2)]", tagged), ["$[0]", "$[2]"])
        expectEqual(try paths("$[?(@.tags.length <= 1)]", tagged), ["$[1]"])
    }

    // MARK: Errors

    check("errors: positions and messages for malformed expressions") {
        expectError("", position: 0, messagePrefix: "Empty expression")
        expectError("   \n", position: 0, messagePrefix: "Empty expression")
        expectError("$.store]", position: 7, messagePrefix: "Unexpected ']'")
        expectError("$.store.book[0", position: 14, messagePrefix: "Expected ']'")
        expectError("$.store.book[", position: 13, messagePrefix: "Unexpected end")
        expectError("$..", position: 3, messagePrefix: "Unexpected end")
        expectError("$.", position: 2, messagePrefix: "Unexpected end")
        expectError("$.a.", position: 4)
        expectError("$.a.]", position: 4, messagePrefix: "Unexpected ']'")
        expectError("$[]", position: 2, messagePrefix: "Unexpected ']'")
        expectError("$[,]", position: 2, messagePrefix: "Unexpected ','")
        expectError("$[0,]", position: 4, messagePrefix: "Unexpected ']'")
        expectError("$['unterminated", position: 2, messagePrefix: "Unterminated string")
        expectError("$['bad\\q']", position: 6, messagePrefix: "Invalid escape")
        expectError("$[1.5]", position: 3, messagePrefix: "Unexpected '.'")
        expectError("$[--1]", position: 2, messagePrefix: "Invalid integer")
        expectError("$[-]", position: 2, messagePrefix: "Invalid integer")
        expectError("$[99999999999999999999]", position: 2, messagePrefix: "Invalid integer")
        expectError("$[1:2:3:4]", position: 7, messagePrefix: "Unexpected ':'")
        expectError("$[0]x", position: 4, messagePrefix: "Unexpected 'x'")
        expectError("$.a b", position: 4, messagePrefix: "Unexpected 'b'")
        expectError("$$", position: 1, messagePrefix: "Unexpected '$'")
        expectError("$.a[?(@.b == )]", position: 13, messagePrefix: "Unexpected ')'")
        expectError("$.a[?(@.b <)]", position: 11, messagePrefix: "Unexpected ')'")
        expectError("$.a[?(@.b == 1]", position: 14, messagePrefix: "Unexpected ']'")
        expectError("$.a[?(@.b == 1", position: 14, messagePrefix: "Expected ')'")
        expectError("$.a[?(@.b =~ /[/)]", position: 13, messagePrefix: "Invalid regular expression")
        expectError("$.a[?(@.b =~ /abc)]", position: 13, messagePrefix: "Unterminated regular expression")
        expectError("$.a[?(@.b =~ /abc/q)]", position: 18, messagePrefix: "Unknown regular expression flag")
        expectError("$.a[?(@.b =~ 5)]", position: 13, messagePrefix: "Unexpected '5'")
        expectError("$.a[?(@.b == yes)]", position: 13, messagePrefix: "Unknown identifier 'yes'")
        expectError("$.a[?(@.b === 1)]", position: 12, messagePrefix: "Unexpected '='")
        expectError("$.a[?(@.b = 1)]", position: 10, messagePrefix: "Unexpected '='")
        expectError("$.a[?(@.b & @.c)]", position: 10, messagePrefix: "Unexpected '&'")
        expectError("$.a[?(@.b && )]", position: 13, messagePrefix: "Unexpected ')'")
        expectError("$.a[?]", position: 5, messagePrefix: "Unexpected ']'")
        expectError("$.a[?(@.b == 'x)]", position: 13, messagePrefix: "Unterminated string")
        expectError("$.a[?(@.b == -)]", position: 13, messagePrefix: "Invalid number")
        expectError("$.a[?(@.b == 1e)]", position: 13, messagePrefix: "Invalid number")
        expectError("$.a[?(@.b == 1", position: 14)
        expectError("(((", position: 0, messagePrefix: "Unexpected '('")
        expectError("@.a", position: 0, messagePrefix: "Unexpected '@'")
        expectError("$.a[?" + String(repeating: "(", count: 100) + "@.x" + String(repeating: ")", count: 100) + "]", position: 69, messagePrefix: "Expression is nested too deeply")
    }

    check("errors: description embeds the position; stored expression and static evaluate agree") {
        do {
            _ = try JSONPathQuery("$.store]")
            fail("expected failure")
        } catch let error as JSONPathError {
            expectEqual(error.errorDescription, "Unexpected ']' at position 7")
            expectEqual(error.localizedDescription, "Unexpected ']' at position 7")
            expectEqual(error, JSONPathError(message: "Unexpected ']'", position: 7))
        }
        let parsed = try JSONPathQuery(" $..author ")
        expectEqual(parsed.expression, " $..author ")
        expectEqual(parsed.description, " $..author ")
        expectEqual(parsed.evaluate(store), try JSONPathQuery.evaluate("$..author", on: store))
        expectEqual(parsed, try JSONPathQuery(" $..author "))
        expectThrows { _ = try JSONPathQuery.evaluate("$[", on: store) }
    }

    // MARK: Robustness and performance

    check("evaluation never traps on mismatched shapes") {
        let expressions = [
            "$[0]", "$.a", "$[-1]", "$[1:100]", "$[::-1]", "$[*]", "$..*", "$[?(@.x > 1)]", "$[?(@ =~ /x/)]",
            "$.a.b.c[0][1]['d']", "$..[?(@.length > 0)]", "$[?(@[0] == $[0])]", "$..length", "$.length", "$[?(@.x.y.z)]",
        ]
        let documents: [JSONValue] = [nil, true, 0, "s", [], ["a": 1], [nil, [nil]], ["a": ["b": [["c": nil]]]], [[], [[]]]]
        for expression in expressions {
            let parsed = try JSONPathQuery(expression)
            for document in documents { _ = parsed.evaluate(document) }
        }
        expectEqual(try values("$.length", "hello"), [5])
        expectEqual(try values("$.length", [1, 2]), [2])
        expectEqual(try values("$[0]", nil), [])
    }

    check("large document: descendant queries stay linear") {
        var items: [JSONValue] = []
        items.reserveCapacity(20_000)
        for i in 0..<20_000 {
            items.append(["id": .number(i), "name": .string("item \(i)"), "tags": ["a", "b"]])
        }
        let doc: JSONValue = ["items": .array(items)]
        let started = Date()
        expectEqual(try query("$..id", doc).count, 20_000)
        expectEqual(try query("$..*", doc).count, 1 + 20_000 * 6)
        expectEqual(try paths("$.items[?(@.id > 19995)]", doc), (19_996...19_999).map { "$.items[\($0)]" })
        expectEqual(try query("$..[?(@.tags[*] == 'b')]", doc).count, 20_000)
        expectEqual(try query("$..tags..*", doc).count, 40_000)
        let elapsed = Date().timeIntervalSince(started)
        print("      (large document queries took \(String(format: "%.2f", elapsed))s)")
        expect(elapsed < 20, "expected large document queries to finish quickly, took \(elapsed)s")
    }
}
