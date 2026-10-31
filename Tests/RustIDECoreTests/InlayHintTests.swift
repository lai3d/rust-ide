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

    @Test(.enabled(if: RustAnalyzerHarness.available), .timeLimit(.minutes(2)))
    func rustAnalyzerReturnsParameterAndTypeHints() async throws {
        let source = "fn greet(name: &str, times: u32) {}\n\nfn main() {\n    let n = 3u32;\n    let s = String::new();\n    greet(&s, n);\n}\n"
        let ra = try await RustAnalyzerHarness(files: ["src/main.rs": source], textDocument: ["inlayHint": [:]])
        try await ra.open("src/main.rs")
        let hints = InlayHint.parseAll(try await ra.request("textDocument/inlayHint", [
            "textDocument": ["uri": ra.uri("src/main.rs")],
            "range": ["start": ["line": 0, "character": 0], "end": ["line": 7, "character": 0]],
        ]))
        #expect(hints.contains { $0.label.contains("name") && $0.position.line == 5 }, "\(hints)")
        #expect(hints.contains { $0.label.contains("String") && $0.position.line == 4 })
        await ra.shutdown()
    }
}
