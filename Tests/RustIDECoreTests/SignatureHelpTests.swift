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

    @Test(.enabled(if: RustAnalyzerHarness.available), .timeLimit(.minutes(2)))
    func rustAnalyzerSignatureHelp() async throws {
        let source = "fn add(first: i32, second: i32) -> i32 { first + second }\n\nfn main() {\n    add(1, 2);\n}\n"
        let ra = try await RustAnalyzerHarness(files: ["src/main.rs": source], textDocument: ["signatureHelp": ["signatureInformation": [
            "parameterInformation": ["labelOffsetSupport": true]]]])
        try await ra.open("src/main.rs")
        func help(_ character: Int) async throws -> SignatureHelp? {
            let raw = try await ra.request("textDocument/signatureHelp", ra.at("src/main.rs", 3, character))
            let parsed = SignatureHelp.parse(raw)
            if parsed == nil { Issue.record("raw signatureHelp at \(character): \(raw)") }
            return parsed
        }
        // `    add(1|, 2|);`
        let first = try #require(try await help(9))
        #expect(first.active?.label.contains("first: i32") == true)
        let firstLabel = first.active!.label as NSString
        #expect(firstLabel.substring(with: try #require(first.activeParameterRange)).hasPrefix("first"))
        let second = try #require(try await help(12))
        let secondLabel = second.active!.label as NSString
        #expect(secondLabel.substring(with: try #require(second.activeParameterRange)).hasPrefix("second"))
        await ra.shutdown()
    }
}
