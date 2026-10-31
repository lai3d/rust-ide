import Foundation
import Testing
@testable import RustIDECore

@Suite struct SymbolTests {
    @Test func parsesHierarchicalAndFlatSymbols() {
        let range: JSONValue = ["start": ["line": 4, "character": 5], "end": ["line": 4, "character": 9]]
        let tree = SymbolNode.parseAll([[
            "name": "Server", "kind": 23, "detail": "struct{...}", "range": range, "selectionRange": range,
            "children": [["name": "Addr", "kind": 8, "range": range, "selectionRange": range]],
        ]])
        #expect(tree.first?.children?.first?.name == "Addr")
        let full: JSONValue = ["start": ["line": 4, "character": 0], "end": ["line": 9, "character": 1]]
        let nested = SymbolNode.parseAll([[
            "name": "Server", "kind": 23, "range": full, "selectionRange": range,
            "children": [["name": "Addr", "kind": 8, "range": ["start": ["line": 6, "character": 1], "end": ["line": 6, "character": 12]], "selectionRange": range]],
        ]])
        #expect(SymbolNode.path(in: nested, at: TextPosition(line: 6, character: 4)).map(\.name) == ["Server", "Addr"])
        #expect(SymbolNode.path(in: nested, at: TextPosition(line: 8, character: 0)).map(\.name) == ["Server"])
        #expect(SymbolNode.path(in: nested, at: TextPosition(line: 12, character: 0)).isEmpty)
        #expect(tree.first?.position == TextPosition(line: 4, character: 5))

        let flat = SymbolNode.parseAll([["name": "Run", "kind": 12, "containerName": "main",
                                         "location": ["uri": "file:///a.go", "range": range]]])
        #expect(flat.first?.uri == "file:///a.go" && flat.first?.detail == "main" && flat.first?.children == nil)
    }

    @Test func fuzzyScoresPreferWordStartsAndFileNames() throws {
        #expect(FuzzyMatch.score("xyz", "greet.go") == nil)
        let camel = try #require(FuzzyMatch.score("hs", "HTTPServer"))
        let middle = try #require(FuzzyMatch.score("hs", "pushes"))
        #expect(camel > middle)
        let paths = ["internal/progress/report.go", "greet.go", "cmd/agreement.go"]
        let ranked = paths.compactMap { p in FuzzyMatch.scorePath("gre", p).map { (p, $0) } }.sorted { $0.1 > $1.1 }
        #expect(ranked.first?.0 == "greet.go")
    }

    @Test(.enabled(if: RustAnalyzerHarness.available), .timeLimit(.minutes(2)))
    func rustAnalyzerDocumentAndWorkspaceSymbols() async throws {
        let source = "struct Server {\n    addr: String,\n}\n\nimpl Server {\n    fn start(&self) {}\n}\n\nfn main() {}\n"
        let ra = try await RustAnalyzerHarness(files: ["src/main.rs": source],
                                               textDocument: ["documentSymbol": ["hierarchicalDocumentSymbolSupport": true]])
        try await ra.open("src/main.rs")
        let outline = SymbolNode.parseAll(try await ra.request("textDocument/documentSymbol", [
            "textDocument": ["uri": ra.uri("src/main.rs")],
        ]))
        #expect(outline.map(\.name).contains("Server"))
        #expect(outline.first { $0.name == "Server" }?.children?.map(\.name) == ["addr"])

        let symbols = SymbolNode.parseAll(try await ra.request("workspace/symbol", ["query": "start"]))
        #expect(symbols.contains { $0.name.contains("start") && $0.uri?.hasSuffix("/src/main.rs") == true }, "\(symbols)")
        await ra.shutdown()
    }
}
