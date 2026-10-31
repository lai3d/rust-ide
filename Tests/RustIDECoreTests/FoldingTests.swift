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

    @Test(.enabled(if: RustAnalyzerHarness.available), .timeLimit(.minutes(2)))
    func rustAnalyzerFoldingRanges() async throws {
        let source = "use std::{\n    env,\n    fs,\n};\n\nfn main() {\n    println!(\"{:?}\", env::args());\n    if true {\n        let _ = fs::read(\"x\");\n    }\n}\n"
        let ra = try await RustAnalyzerHarness(files: ["src/main.rs": source],
                                               textDocument: ["foldingRange": ["lineFoldingOnly": false]])
        try await ra.open("src/main.rs")
        let regions = FoldRegion.parseAll(try await ra.request("textDocument/foldingRange", [
            "textDocument": ["uri": ra.uri("src/main.rs")],
        ]))
        let index = LineIndex(source)
        let folded = regions.compactMap { $0.hiddenRange(in: index, text: source as NSString) }.map { (source as NSString).replacingCharacters(in: $0, with: "⋯") }
        #expect(regions.contains { $0.startLine == 0 })  // use block
        #expect(regions.contains { $0.startLine == 5 })  // fn body
        #expect(regions.contains { $0.startLine == 7 })  // if block
        #expect(folded.contains { $0.contains("fn main() {⋯}") }, "\(folded)")
        #expect(folded.contains { $0.hasPrefix("use std::{⋯};") })
        await ra.shutdown()
    }
}
