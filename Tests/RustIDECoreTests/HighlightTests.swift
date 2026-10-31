import Foundation
import Testing
@testable import RustIDECore

@Suite struct DocumentHighlightTests {
    @Test(.enabled(if: ToolLocator.find("gopls") != nil), .timeLimit(.minutes(1)))
    func goplsHighlightsReadsAndWrites() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goide-hl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "module example.com/t\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        let source = "package main\n\nfunc main() {\n\ttotal := 1\n\ttotal = total + 2\n\tprintln(total)\n}\n"
        let file = dir.appendingPathComponent("main.go")
        try source.write(to: file, atomically: true, encoding: .utf8)

        let client = LSPClient()
        try client.start(executable: try #require(ToolLocator.find("gopls")),
                         environment: ToolLocator.environment(), currentDirectory: dir)
        _ = try await client.request("initialize", params: [
            "processId": .int(Int(getpid())), "rootUri": .string(dir.absoluteString), "capabilities": [:],
        ])
        try client.notify("initialized", params: [:])
        try client.notify("textDocument/didOpen", params: [
            "textDocument": ["uri": .string(file.absoluteString), "languageId": "go", "version": 1, "text": .string(source)],
        ])
        let highlights = DocumentHighlight.parseAll(try await client.request("textDocument/documentHighlight", params: [
            "textDocument": ["uri": .string(file.absoluteString)],
            "position": TextPosition(line: 5, character: 10).json,
        ]))
        #expect(highlights.count == 4)
        #expect(highlights.contains { $0.start.line == 4 && $0.start.character == 1 && $0.kind == .write })
        #expect(highlights.contains { $0.start.line == 5 && $0.kind == .read })
        await client.shutdown()
    }
}
