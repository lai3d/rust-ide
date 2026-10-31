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

    @Test(.enabled(if: ToolLocator.find("gopls") != nil), .timeLimit(.minutes(1)))
    func goplsDocumentAndWorkspaceSymbols() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goide-sym-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "module example.com/t\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        let source = "package main\n\ntype Server struct {\n\tAddr string\n}\n\nfunc (s *Server) Start() {}\n\nfunc main() {}\n"
        let file = dir.appendingPathComponent("main.go")
        try source.write(to: file, atomically: true, encoding: .utf8)

        let client = LSPClient()
        try client.start(executable: try #require(ToolLocator.find("gopls")),
                         environment: ToolLocator.environment(), currentDirectory: dir)
        _ = try await client.request("initialize", params: [
            "processId": .int(Int(getpid())), "rootUri": .string(dir.absoluteString),
            "capabilities": ["textDocument": ["documentSymbol": ["hierarchicalDocumentSymbolSupport": true]]],
        ])
        try client.notify("initialized", params: [:])
        try client.notify("textDocument/didOpen", params: [
            "textDocument": ["uri": .string(file.absoluteString), "languageId": "go", "version": 1, "text": .string(source)],
        ])
        let outline = SymbolNode.parseAll(try await client.request("textDocument/documentSymbol", params: [
            "textDocument": ["uri": .string(file.absoluteString)],
        ]))
        #expect(outline.map(\.name).contains("Server"))
        #expect(outline.first { $0.name == "Server" }?.children?.map(\.name) == ["Addr"])

        let symbols = SymbolNode.parseAll(try await client.request("workspace/symbol", params: ["query": "Start"]))
        #expect(symbols.contains { $0.name.contains("Start") && $0.uri?.hasSuffix("/main.go") == true })
        await client.shutdown()
    }
}
