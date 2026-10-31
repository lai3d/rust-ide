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

@Suite struct RustAnalyzerFormattingTests {
    @Test(.enabled(if: RustAnalyzerHarness.available), .timeLimit(.minutes(2)))
    func formatsWithRustfmt() async throws {
        let source = "fn main(){\nlet x=vec![1,2 ,3];\nprintln!( \"{:?}\" ,x );\n}\n"
        let ra = try await RustAnalyzerHarness(files: ["src/main.rs": source])
        try await ra.open("src/main.rs")
        let edits = (try await ra.request("textDocument/formatting", [
            "textDocument": ["uri": ra.uri("src/main.rs")], "options": ["tabSize": 4, "insertSpaces": true],
        ])).arrayValue?.compactMap(TextEdit.parse) ?? []
        let formatted = TextEdit.apply(edits, to: source)
        #expect(formatted == "fn main() {\n    let x = vec![1, 2, 3];\n    println!(\"{:?}\", x);\n}\n", "\(formatted)")
        await ra.shutdown()
    }
}
