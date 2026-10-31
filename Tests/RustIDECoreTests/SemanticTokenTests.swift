import Foundation
import Testing
@testable import RustIDECore

@Suite struct SemanticTokenTests {
    @Test func decodesRelativeEncoding() {
        let legend = SemanticTokenLegend(types: ["namespace", "type", "parameter"], modifiers: ["definition", "readonly"])
        // (0,8) len 3 namespace; same line +5 len 4 type [definition]; next line col 2 len 1 parameter [readonly]
        let tokens = legend.decode(["data": [0, 8, 3, 0, 0, 0, 5, 4, 1, 1, 1, 2, 1, 2, 2]])
        #expect(tokens == [
            SemanticToken(line: 0, start: 8, length: 3, type: "namespace"),
            SemanticToken(line: 0, start: 13, length: 4, type: "type", modifiers: ["definition"]),
            SemanticToken(line: 1, start: 2, length: 1, type: "parameter", modifiers: ["readonly"]),
        ])
    }

    @Test(.enabled(if: ToolLocator.find("gopls") != nil), .timeLimit(.minutes(1)))
    func goplsSemanticTokens() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goide-sem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "module example.com/t\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        let source = "package main\n\nimport \"fmt\"\n\ntype Order struct{ ID int }\n\nconst Max = 3\n\nfunc show(o Order) { fmt.Println(o.ID, Max) }\n\nfunc main() { show(Order{}) }\n"
        let file = dir.appendingPathComponent("main.go")
        try source.write(to: file, atomically: true, encoding: .utf8)

        let client = LSPClient()
        try client.start(executable: try #require(ToolLocator.find("gopls")),
                         environment: ToolLocator.environment(), currentDirectory: dir)
        let initialized = try await client.request("initialize", params: [
            "processId": .int(Int(getpid())), "rootUri": .string(dir.absoluteString),
            "capabilities": ["textDocument": ["semanticTokens": [
                "requests": ["full": true], "formats": ["relative"],
                "tokenTypes": .array(SemanticTokenLegend.clientTypes.map(JSONValue.string)),
                "tokenModifiers": .array(SemanticTokenLegend.clientModifiers.map(JSONValue.string)),
            ]]],
            "initializationOptions": GoplsSettings.default,
        ])
        let legend = try #require(SemanticTokenLegend(initializeResult: initialized))
        try client.notify("initialized", params: [:])
        try client.notify("textDocument/didOpen", params: [
            "textDocument": ["uri": .string(file.absoluteString), "languageId": "go", "version": 1, "text": .string(source)],
        ])
        let tokens = legend.decode(try await client.request("textDocument/semanticTokens/full", params: [
            "textDocument": ["uri": .string(file.absoluteString)],
        ]))
        let lines = source.components(separatedBy: "\n")
        func text(_ t: SemanticToken) -> String {
            let line = lines[t.line] as NSString
            return line.substring(with: NSRange(location: t.start, length: t.length))
        }
        let byText = Dictionary(tokens.map { (text($0) + "@\($0.line)", $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byText["fmt@8"]?.type == "namespace")
        #expect(byText["Order@8"]?.type == "type")
        #expect(byText["o@8"]?.type == "parameter")
        #expect(byText["Max@8"]?.modifiers.contains("readonly") == true)
        await client.shutdown()
    }
}
