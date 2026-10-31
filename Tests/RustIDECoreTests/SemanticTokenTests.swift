import Foundation
import Testing
@testable import RustIDECore

@Suite struct SemanticTokenTests {
    @Test func decodesRelativeEncoding() {
        let legend = SemanticTokenLegend(types: ["namespace", "type", "parameter"], modifiers: ["definition", "readonly"])
        // (0,8) len 3 namespace; same line +5 len 4 type [definition]; next line col 2 len 1 parameter [readonly]
        let tokens = legend.decode(["data": [0, 8, 3, 0, 0, 0, 5, 4, 1, 1, 1, 2, 1, 2, 2]])
        #expect(tokens == [
            SemanticToken(line: 0, start: 8, length: 3, type: "namespace"),
            SemanticToken(line: 0, start: 13, length: 4, type: "type", modifiers: ["definition"]),
            SemanticToken(line: 1, start: 2, length: 1, type: "parameter", modifiers: ["readonly"]),
        ])
    }

    @Test(.enabled(if: RustAnalyzerHarness.available), .timeLimit(.minutes(2)))
    func rustAnalyzerSemanticTokens() async throws {
        let source = "struct Order { id: u32 }\n\nconst MAX: u32 = 3;\n\nfn show(o: Order) { println!(\"{}\", o.id + MAX); }\n\nfn main() { show(Order { id: 1 }); std::process::exit(0); }\n"
        let ra = try await RustAnalyzerHarness(files: ["src/main.rs": source], textDocument: ["semanticTokens": [
            "requests": ["full": true], "formats": ["relative"],
            "tokenTypes": .array(SemanticTokenLegend.clientTypes.map(JSONValue.string)),
            "tokenModifiers": .array(SemanticTokenLegend.clientModifiers.map(JSONValue.string)),
        ]])
        try await ra.open("src/main.rs")
        let legend = try #require(ra.semanticLegend)
        let tokens = legend.decode(try await ra.request("textDocument/semanticTokens/full", [
            "textDocument": ["uri": ra.uri("src/main.rs")],
        ]))
        let lines = source.components(separatedBy: "\n")
        func text(_ t: SemanticToken) -> String {
            let line = lines[t.line] as NSString
            return line.substring(with: NSRange(location: t.start, length: t.length))
        }
        let byText = Dictionary(tokens.map { (text($0) + "@\($0.line)", $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byText["Order@4"]?.type == "struct", "\(byText["Order@4"].map { "\($0)" } ?? "nil")")
        #expect(byText["o@4"]?.type == "parameter")
        #expect(byText["MAX@4"]?.type == "const")
        #expect(byText["println@4"]?.type == "macro")
        #expect(byText["std@6"]?.type == "namespace")
        await ra.shutdown()
    }
}
