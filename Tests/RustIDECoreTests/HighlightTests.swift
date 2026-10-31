import Foundation
import Testing
@testable import RustIDECore

@Suite struct DocumentHighlightTests {
    @Test(.enabled(if: RustAnalyzerHarness.available), .timeLimit(.minutes(2)))
    func rustAnalyzerHighlightsReadsAndWrites() async throws {
        let source = "fn main() {\n    let mut total = 1;\n    total = total + 2;\n    println!(\"{}\", total);\n}\n"
        let ra = try await RustAnalyzerHarness(files: ["src/main.rs": source])
        try await ra.open("src/main.rs")
        let highlights = DocumentHighlight.parseAll(try await ra.request("textDocument/documentHighlight", ra.at("src/main.rs", 2, 13)))
        #expect(highlights.count == 4, "\(highlights)")
        #expect(highlights.contains { $0.start.line == 2 && $0.start.character == 4 && $0.kind == .write })
        #expect(highlights.contains { $0.start.line == 3 && $0.kind == .read })
        await ra.shutdown()
    }
}
