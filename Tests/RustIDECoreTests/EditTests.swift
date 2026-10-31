import Foundation
import Testing
@testable import RustIDECore

@Suite struct EditTests {
    private func edit(_ l1: Int, _ c1: Int, _ l2: Int, _ c2: Int, _ text: String) -> TextEdit {
        TextEdit(start: TextPosition(line: l1, character: c1), end: TextPosition(line: l2, character: c2), newText: text)
    }

    @Test func appliesEditsBackToFront() {
        let text = "package main\nfunc  main(){\n}\n"
        let result = TextEdit.apply([
            edit(1, 4, 1, 6, " "),       // "func  main" -> "func main"
            edit(1, 12, 1, 12, " "),     // "(){" -> "() {"
            edit(0, 0, 0, 0, "// x\n"),  // insert at top
        ], to: text)
        #expect(result == "// x\npackage main\nfunc main() {\n}\n")
    }

    @Test func parsesWorkspaceEditForms() {
        let range: JSONValue = ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 3]]
        let changes = WorkspaceEdit.parse(["changes": ["file:///a.go": [["range": range, "newText": "x"]]]])
        #expect(changes.changes["file:///a.go"]?.first?.newText == "x")
        let documentChanges = WorkspaceEdit.parse(["documentChanges": [
            ["textDocument": ["uri": "file:///b.go", "version": 3], "edits": [["range": range, "newText": "y"]]],
            ["kind": "create", "uri": "file:///c.go"],
        ]])
        #expect(documentChanges.changes.keys.sorted() == ["file:///b.go"])
        #expect(documentChanges.creates == ["file:///c.go"])
    }

    @Test func parsesCodeActionsAndCommands() {
        let actions = CodeAction.parseAll([
            ["title": "Organize Imports", "kind": "source.organizeImports",
             "edit": ["changes": ["file:///a.go": []]]],
            ["title": "Run test", "command": "gopls.test", "arguments": []],
        ])
        #expect(actions.map(\.title) == ["Organize Imports", "Run test"])
        #expect(actions[0].edit != nil && actions[0].command == nil)
        #expect(actions[1].command?["command"]?.stringValue == "gopls.test")
    }

    @Test func computesMinimalReplacement() {
        let r = TextDiff.replacement(from: "func  main() {}", to: "func main() {}")
        #expect(r?.range == NSRange(location: 5, length: 1) && r?.text == "")
        #expect(TextDiff.replacement(from: "same", to: "same") == nil)
        let tail = TextDiff.replacement(from: "a", to: "ab")
        #expect(tail?.range == NSRange(location: 1, length: 0) && tail?.text == "b")
        let emoji = TextDiff.replacement(from: "x😀", to: "x😃")
        #expect(emoji?.range == NSRange(location: 1, length: 2))
    }
}

@Suite struct GoplsFormattingTests {
    @Test(.enabled(if: ToolLocator.find("gopls") != nil), .timeLimit(.minutes(1)))
    func organizesImportsAndFormats() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goide-fmt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "module example.com/t\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        let source = "package main\n\nimport \"os\"\n\nfunc main(){\nfmt.Println( strings.ToUpper(\"x\") )\n}\n"
        let file = dir.appendingPathComponent("main.go")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let uri = JSONValue.string(file.absoluteString)

        let client = LSPClient()
        try client.start(executable: try #require(ToolLocator.find("gopls")),
                         environment: ToolLocator.environment(), currentDirectory: dir)
        _ = try await client.request("initialize", params: [
            "processId": .int(Int(getpid())), "rootUri": .string(dir.absoluteString),
            "capabilities": ["textDocument": ["codeAction": ["codeActionLiteralSupport": [
                "codeActionKind": ["valueSet": ["source.organizeImports"]]]]]],
        ])
        try client.notify("initialized", params: [:])
        try client.notify("textDocument/didOpen", params: [
            "textDocument": ["uri": uri, "languageId": "go", "version": 1, "text": .string(source)],
        ])

        let actions = CodeAction.parseAll(try await client.request("textDocument/codeAction", params: [
            "textDocument": ["uri": uri],
            "range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 0]],
            "context": ["diagnostics": [], "only": ["source.organizeImports"]],
        ]))
        let organize = try #require(actions.first { $0.kind == "source.organizeImports" })
        let organized = TextEdit.apply(organize.edit?.changes[file.absoluteString] ?? [], to: source)
        #expect(organized.contains("\"fmt\"") && organized.contains("\"strings\"") && !organized.contains("\"os\""))

        try client.notify("textDocument/didChange", params: [
            "textDocument": ["uri": uri, "version": 2], "contentChanges": [["text": .string(organized)]],
        ])
        let formatEdits = (try await client.request("textDocument/formatting", params: [
            "textDocument": ["uri": uri], "options": ["tabSize": 4, "insertSpaces": false],
        ])).arrayValue?.compactMap(TextEdit.parse) ?? []
        let formatted = TextEdit.apply(formatEdits, to: organized)
        #expect(formatted.contains("func main() {\n\tfmt.Println(strings.ToUpper(\"x\"))\n}"))
        await client.shutdown()
    }
}
