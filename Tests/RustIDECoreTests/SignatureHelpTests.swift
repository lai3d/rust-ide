import Foundation
import Testing
@testable import RustIDECore

@Suite struct SignatureHelpTests {
    @Test func parsesStringAndOffsetLabels() throws {
        let help = try #require(SignatureHelp.parse([
            "signatures": [[
                "label": "Printf(format string, a ...any) (n int, err error)",
                "documentation": ["kind": "markdown", "value": "Printf formats."],
                "parameters": [["label": "format string"], ["label": [22, 30]]],
            ]],
            "activeSignature": 0, "activeParameter": 1,
        ]))
        let label = help.active!.label as NSString
        #expect(label.substring(with: help.active!.parameters[0]) == "format string")
        #expect(label.substring(with: try #require(help.activeParameterRange)) == "a ...any")
        #expect(help.active?.documentation == "Printf formats.")
    }

    @Test func perSignatureActiveParameterWins() throws {
        let help = try #require(SignatureHelp.parse([
            "signatures": [["label": "f(a, b)", "parameters": [["label": "a"], ["label": "b"]], "activeParameter": 1]],
            "activeParameter": 0,
        ]))
        #expect(help.activeParameterRange == NSRange(location: 5, length: 1))
        #expect(SignatureHelp.parse(["signatures": []]) == nil)
    }

    @Test(.enabled(if: ToolLocator.find("gopls") != nil), .timeLimit(.minutes(1)))
    func goplsSignatureHelp() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goide-sig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "module example.com/t\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        let source = "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Printf(\"%d\", 1)\n}\n"
        let file = dir.appendingPathComponent("main.go")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let uri = JSONValue.string(file.absoluteString)

        let client = LSPClient()
        try client.start(executable: try #require(ToolLocator.find("gopls")),
                         environment: ToolLocator.environment(), currentDirectory: dir)
        _ = try await client.request("initialize", params: [
            "processId": .int(Int(getpid())), "rootUri": .string(dir.absoluteString),
            "capabilities": ["textDocument": ["signatureHelp": ["signatureInformation": [
                "parameterInformation": ["labelOffsetSupport": true]]]]],
        ])
        try client.notify("initialized", params: [:])
        try client.notify("textDocument/didOpen", params: [
            "textDocument": ["uri": uri, "languageId": "go", "version": 1, "text": .string(source)],
        ])
        func help(_ character: Int) async throws -> SignatureHelp? {
            let raw = try await client.request("textDocument/signatureHelp", params: [
                "textDocument": ["uri": uri], "position": TextPosition(line: 5, character: character).json,
            ])
            let parsed = SignatureHelp.parse(raw)
            if parsed == nil { Issue.record("raw signatureHelp at \(character): \(raw)") }
            return parsed
        }
        // `\tfmt.Printf("%d"|, |1)` (gopls gives no help inside string literals)
        let first = try #require(try await help(16))
        #expect(first.active?.label.contains("format string") == true)
        let firstLabel = first.active!.label as NSString
        #expect(firstLabel.substring(with: try #require(first.activeParameterRange)).hasPrefix("format"))
        let second = try #require(try await help(18))
        let secondLabel = second.active!.label as NSString
        #expect(secondLabel.substring(with: try #require(second.activeParameterRange)).hasPrefix("a "))
        await client.shutdown()
    }
}
