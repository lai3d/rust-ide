import Foundation
import Testing
@testable import RustIDECore

@Suite struct InlayHintTests {
    @Test func parsesStringAndPartLabels() {
        let hints = InlayHint.parseAll([
            ["position": ["line": 3, "character": 9], "label": "name:", "kind": 2, "paddingRight": true],
            ["position": ["line": 4, "character": 2], "label": [["value": "int"]], "kind": 1, "paddingLeft": true],
        ])
        #expect(hints.map(\.label) == ["name:", "int"])
        #expect(hints[0].kind == .parameter && hints[0].paddingRight)
        #expect(hints[1].kind == .type && hints[1].paddingLeft)
    }

    @Test(.enabled(if: ToolLocator.find("gopls") != nil), .timeLimit(.minutes(1)))
    func goplsReturnsParameterAndTypeHints() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goide-inlay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "module example.com/t\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        let source = "package main\n\nfunc greet(name string, times int) {}\n\nfunc main() {\n\tn := 3\n\tgreet(\"x\", n)\n}\n"
        let file = dir.appendingPathComponent("main.go")
        try source.write(to: file, atomically: true, encoding: .utf8)

        let client = LSPClient()
        try client.start(executable: try #require(ToolLocator.find("gopls")),
                         environment: ToolLocator.environment(), currentDirectory: dir)
        _ = try await client.request("initialize", params: [
            "processId": .int(Int(getpid())), "rootUri": .string(dir.absoluteString),
            "capabilities": ["textDocument": ["inlayHint": [:]]],
            "initializationOptions": InlayHint.goplsSettings,
        ])
        try client.notify("initialized", params: [:])
        try client.notify("textDocument/didOpen", params: [
            "textDocument": ["uri": .string(file.absoluteString), "languageId": "go", "version": 1, "text": .string(source)],
        ])
        let hints = InlayHint.parseAll(try await client.request("textDocument/inlayHint", params: [
            "textDocument": ["uri": .string(file.absoluteString)],
            "range": ["start": ["line": 0, "character": 0], "end": ["line": 8, "character": 0]],
        ]))
        #expect(hints.contains { $0.label.contains("name") && $0.position.line == 6 })
        #expect(hints.contains { $0.label.contains("times") && $0.position.line == 6 })
        #expect(hints.contains { $0.label.contains("int") && $0.position.line == 5 })
        await client.shutdown()
    }
}
