import Foundation
import Testing
@testable import RustIDECore

@Suite struct ReferencesTests {
    @Test func groupsLocationsWithPreviews() {
        func loc(_ uri: String, _ line: Int, _ c1: Int, _ c2: Int) -> Location {
            Location(uri: uri, start: TextPosition(line: line, character: c1), end: TextPosition(line: line, character: c2))
        }
        let files = [
            "/p/a.go": "package p\n\nfunc Foo() {}\n",
            "/p/b.go": "package p\n\nfunc bar() {\n\tFoo()\n\tFoo()\n}\n",
        ]
        let results = ProjectSearch.results(
            for: [loc("file:///p/b.go", 4, 1, 4), loc("file:///p/a.go", 2, 5, 8), loc("file:///p/b.go", 3, 1, 4)],
            text: { files[$0] })
        #expect(results.map(\.path) == ["/p/a.go", "/p/b.go"])
        #expect(results[1].matches.map(\.line) == [3, 4])
        #expect(results[1].matches[0].preview == "Foo()")
        #expect(results[1].matches[0].previewRange == NSRange(location: 0, length: 3))
    }

    @Test(.enabled(if: ToolLocator.find("gopls") != nil), .timeLimit(.minutes(1)))
    func goplsFindsReferences() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goide-refs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "module example.com/t\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        try "package main\n\nfunc helper() int { return 1 }\n".write(to: dir.appendingPathComponent("helper.go"), atomically: true, encoding: .utf8)
        let source = "package main\n\nfunc main() {\n\t_ = helper() + helper()\n}\n"
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
        let result = try await client.request("textDocument/references", params: [
            "textDocument": ["uri": .string(file.absoluteString)],
            "position": TextPosition(line: 3, character: 6).json,
            "context": ["includeDeclaration": true],
        ])
        let locations = Location.parseAll(result)
        #expect(locations.count == 3)  // declaration + two calls
        #expect(locations.contains { $0.uri.hasSuffix("/helper.go") && $0.start.line == 2 })
        await client.shutdown()
    }
}
