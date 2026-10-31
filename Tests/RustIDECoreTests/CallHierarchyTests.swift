import Foundation
import Testing
@testable import RustIDECore

@Suite struct CallHierarchyTests {
    @Test(.enabled(if: ToolLocator.find("gopls") != nil), .timeLimit(.minutes(1)))
    func goplsIncomingAndOutgoingCalls() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goide-calls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "module example.com/t\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        let source = "package main\n\nfunc leaf() {}\n\nfunc middle() {\n\tleaf()\n\tleaf()\n}\n\nfunc main() {\n\tmiddle()\n}\n"
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
        let items = CallHierarchyItem.parseAll(try await client.request("textDocument/prepareCallHierarchy", params: [
            "textDocument": ["uri": .string(file.absoluteString)], "position": TextPosition(line: 4, character: 6).json,
        ]))
        let middle = try #require(items.first)
        #expect(middle.name == "middle" && middle.position.line == 4)

        let incoming = CallHierarchyCall.parseAll(try await client.request("callHierarchy/incomingCalls", params: ["item": middle.raw]))
        #expect(incoming.map(\.item.name) == ["main"])
        #expect(incoming.first?.callSites == [TextPosition(line: 10, character: 1)])

        let outgoing = CallHierarchyCall.parseAll(try await client.request("callHierarchy/outgoingCalls", params: ["item": middle.raw]))
        #expect(outgoing.map(\.item.name) == ["leaf"])
        #expect(outgoing.first?.callSites.count == 2)
        await client.shutdown()
    }
}
