import Foundation
import Testing
@testable import RustIDECore

@Suite struct CompletionParsingTests {
    @Test func parsesCompletionListSortedBySortText() {
        let result: JSONValue = ["isIncomplete": false, "items": [
            ["label": "Printf", "kind": 3, "sortText": "00001", "detail": "func(format string, a ...any)"],
            ["label": "Println", "kind": 3, "sortText": "00000",
             "textEdit": ["range": ["start": ["line": 8, "character": 5], "end": ["line": 8, "character": 8]],
                          "newText": "Println"],
             "documentation": ["kind": "markdown", "value": "Println formats…"]],
        ]]
        let items = CompletionItem.parseList(result)
        #expect(items.map(\.label) == ["Println", "Printf"])
        #expect(items[0].kind == .function)
        #expect(items[0].documentation == "Println formats…")
        #expect(items[1].detail == "func(format string, a ...any)")
    }

    @Test func parsesBareArrayAndAdditionalEdits() {
        let result: JSONValue = [[
            "label": "strings", "kind": 9, "insertText": "strings",
            "additionalTextEdits": [["range": ["start": ["line": 2, "character": 0], "end": ["line": 2, "character": 0]],
                                     "newText": "import \"strings\"\n"]],
        ]]
        let item = try! #require(CompletionItem.parseList(result).first)
        #expect(item.kind == .module)
        #expect(item.additionalEdits == [TextEdit(start: TextPosition(line: 2, character: 0),
                                                  end: TextPosition(line: 2, character: 0),
                                                  newText: "import \"strings\"\n")])
    }

    @Test func stripsSnippets() {
        #expect(CompletionItem.stripSnippet("Foo(${1:a}, ${2:b})$0") == "Foo(a, b)")
        let item = CompletionItem.parse(["label": "x", "insertText": "x($1)", "insertTextFormat": 2])
        #expect(item?.insertText == "x()" && item?.snippet == "x($1)")
    }

    @Test func fuzzyMatches() {
        #expect(FuzzyMatch.matches("", "anything"))
        #expect(FuzzyMatch.matches("prl", "Println"))
        #expect(FuzzyMatch.matches("Pri", "Printf"))
        #expect(!FuzzyMatch.matches("ln", "Println"))  // first letter must match
        #expect(!FuzzyMatch.matches("Pz", "Println"))
    }
}

@Suite struct HoverAndLocationTests {
    @Test func parsesMarkupHover() {
        let result: JSONValue = ["contents": ["kind": "markdown", "value": "```go\nfunc Println(a ...any)\n```\n\nPrintln formats."]]
        let markdown = HoverContent.parse(result)
        #expect(markdown?.hasPrefix("```go") == true)
        let blocks = MarkdownBlock.parse(markdown!)
        #expect(blocks == [MarkdownBlock(kind: .code, text: "func Println(a ...any)"),
                           MarkdownBlock(kind: .text, text: "Println formats.")])
    }

    @Test func treatsHorizontalRulesAsSeparators() {
        let blocks = MarkdownBlock.parse("```go\nfunc F()\n```\n\n---\n\nDocs here.\n\n---\n\n[link](https://pkg.go.dev)")
        #expect(blocks.map(\.text) == ["func F()", "Docs here.", "[link](https://pkg.go.dev)"])
    }

    @Test func parsesMarkedStringArrays() {
        let result: JSONValue = ["contents": [["language": "go", "value": "var x int"], "doc"]]
        #expect(HoverContent.parse(result) == "```go\nvar x int\n```\n\ndoc")
        #expect(HoverContent.parse(["contents": ""]) == nil)
    }

    @Test func parsesLocationsAndLinks() {
        let range: JSONValue = ["start": ["line": 4, "character": 5], "end": ["line": 4, "character": 11]]
        #expect(Location.parseAll(["uri": "file:///a.go", "range": range]).map(\.uri) == ["file:///a.go"])
        let links = Location.parseAll([["targetUri": "file:///b.go", "targetRange": range, "targetSelectionRange": range]])
        #expect(links == [Location(uri: "file:///b.go", start: TextPosition(line: 4, character: 5),
                                   end: TextPosition(line: 4, character: 11))])
        #expect(Location.parseAll(.null).isEmpty)
    }
}

@Suite struct GoIdentifierTests {
    @Test func findsCallStart() {
        let text = "\tfmt.Printf(\"%d\", len(xs), " as NSString
        #expect(GoIdentifier.callStart(in: text, before: text.length) == 1)  // fmt.Printf, skipping len(xs)
        let inner = "x := strings.ToUpper(s.Trim(" as NSString
        #expect(GoIdentifier.callStart(in: inner, before: inner.length) == 21)  // s.Trim
        #expect(GoIdentifier.callStart(in: "a + b" as NSString, before: 5) == nil)
    }

    @Test func findsPrefixAndWords() {
        let text = "\tfmt.Prin x1 42" as NSString
        #expect(GoIdentifier.prefixStart(in: text, before: 9) == 5)  // "Prin"
        #expect(GoIdentifier.prefixStart(in: text, before: 5) == 5)  // right after "."
        #expect(GoIdentifier.wordRange(in: text, at: 2) == NSRange(location: 1, length: 3))  // "fmt"
        #expect(GoIdentifier.wordRange(in: text, at: 4) == nil)  // "."
        #expect(GoIdentifier.wordRange(in: text, at: 11) == NSRange(location: 10, length: 2))  // "x1"
        #expect(GoIdentifier.wordRange(in: text, at: 13) == nil)  // number literal
    }
}

/// End-to-end checks against a real gopls (skipped when gopls isn't installed).
@Suite struct GoplsLanguageFeatureTests {
    static let source = """
        package main

        import "fmt"

        func helper() int { return 1 }

        func main() {
        \tfmt.Println(helper())
        \tfmt.Pri
        }

        """

    @Test(.enabled(if: ToolLocator.find("gopls") != nil), .timeLimit(.minutes(1)))
    func completionHoverAndDefinition() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goide-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "module example.com/t\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        let file = dir.appendingPathComponent("main.go")
        try Self.source.write(to: file, atomically: true, encoding: .utf8)

        let client = LSPClient()
        try client.start(executable: try #require(ToolLocator.find("gopls")),
                         environment: ToolLocator.environment(), currentDirectory: dir)
        _ = try await client.request("initialize", params: [
            "processId": .int(Int(getpid())),
            "rootUri": .string(dir.absoluteString),
            "capabilities": ["textDocument": ["hover": ["contentFormat": ["markdown"]]]],
        ])
        try client.notify("initialized", params: [:])
        try client.notify("textDocument/didOpen", params: [
            "textDocument": ["uri": .string(file.absoluteString), "languageId": "go", "version": 1,
                             "text": .string(Self.source)],
        ])
        func at(_ line: Int, _ character: Int) -> JSONValue {
            ["textDocument": ["uri": .string(file.absoluteString)],
             "position": TextPosition(line: line, character: character).json]
        }

        // `\tfmt.Pri|` on line 8
        let items = CompletionItem.parseList(try await client.request("textDocument/completion", params: at(8, 8)))
        #expect(items.contains { $0.label == "Println" && $0.insertText == "Println" })
        #expect(items.allSatisfy { FuzzyMatch.matches("Pri", $0.filterText) })

        // Hover on `Println` (line 7)
        let hover = HoverContent.parse(try await client.request("textDocument/hover", params: at(7, 7)))
        #expect(hover?.contains("Println(a ...any)") == true, "hover was: \(hover ?? "nil")")

        // Definition of `helper` (line 7, inside the call) -> line 4
        let locations = Location.parseAll(try await client.request("textDocument/definition", params: at(7, 15)))
        #expect(locations.first?.uri.hasSuffix("/main.go") == true)
        #expect(locations.first?.start.line == 4)

        // Definition of `Println` -> the standard library
        let stdlib = Location.parseAll(try await client.request("textDocument/definition", params: at(7, 7)))
        #expect(stdlib.first?.uri.hasSuffix("/fmt/print.go") == true)

        await client.shutdown()
    }
}

@Suite struct ExpressionRangeTests {
    @Test func findsSelectorChains() {
        let text = "x := order.Items[0] + o.p.q" as NSString
        func expr(_ at: Int) -> String? { GoIdentifier.expressionRange(in: text, at: at).map { text.substring(with: $0) } }
        #expect(expr(12) == "order.Items")   // on "Items"
        #expect(expr(6) == "order")          // on "order"
        #expect(expr(26) == "o.p.q")
        #expect(expr(3) == nil)              // ":="
    }
}
