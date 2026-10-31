import Foundation
import Testing
@testable import RustIDECore

@Suite struct FoldingTests {
    @Test func computesHiddenRanges() throws {
        let text = "func f() {\n\tx := 1\n}\n"
        let index = LineIndex(text)
        let withChars = FoldRegion(startLine: 0, startCharacter: 10, endLine: 2, endCharacter: 0)
        let hidden = try #require(withChars.hiddenRange(in: index))
        #expect((text as NSString).replacingCharacters(in: hidden, with: "⋯") == "func f() {⋯}\n")
        let linesOnly = FoldRegion(startLine: 0, endLine: 1)
        #expect((text as NSString).replacingCharacters(in: try #require(linesOnly.hiddenRange(in: index)), with: "⋯") == "func f() {⋯\n}\n")
        #expect(FoldRegion.parseAll([["startLine": 3, "endLine": 3]]).isEmpty)
    }

    @Test(.enabled(if: ToolLocator.find("gopls") != nil), .timeLimit(.minutes(1)))
    func goplsFoldingRanges() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goide-fold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "module example.com/t\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        let source = "package main\n\nimport (\n\t\"fmt\"\n\t\"os\"\n)\n\nfunc main() {\n\tfmt.Println(os.Args)\n\tif true {\n\t\tfmt.Println()\n\t}\n}\n"
        let file = dir.appendingPathComponent("main.go")
        try source.write(to: file, atomically: true, encoding: .utf8)

        let client = LSPClient()
        try client.start(executable: try #require(ToolLocator.find("gopls")),
                         environment: ToolLocator.environment(), currentDirectory: dir)
        _ = try await client.request("initialize", params: [
            "processId": .int(Int(getpid())), "rootUri": .string(dir.absoluteString),
            "capabilities": ["textDocument": ["foldingRange": ["lineFoldingOnly": false]]],
        ])
        try client.notify("initialized", params: [:])
        try client.notify("textDocument/didOpen", params: [
            "textDocument": ["uri": .string(file.absoluteString), "languageId": "go", "version": 1, "text": .string(source)],
        ])
        let regions = FoldRegion.parseAll(try await client.request("textDocument/foldingRange", params: [
            "textDocument": ["uri": .string(file.absoluteString)],
        ]))
        let index = LineIndex(source)
        let folded = regions.compactMap { $0.hiddenRange(in: index) }.map { (source as NSString).replacingCharacters(in: $0, with: "⋯") }
        #expect(regions.contains { $0.startLine == 2 })  // import block
        #expect(regions.contains { $0.startLine == 7 })  // func body
        #expect(regions.contains { $0.startLine == 9 })  // if block
        #expect(folded.contains { $0.contains("func main() {⋯}") })
        await client.shutdown()
    }
}
