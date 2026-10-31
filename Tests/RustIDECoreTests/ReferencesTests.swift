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

    @Test(.enabled(if: RustAnalyzerHarness.available), .timeLimit(.minutes(2)))
    func rustAnalyzerFindsReferences() async throws {
        let ra = try await RustAnalyzerHarness(files: [
            "src/helper.rs": "pub fn helper() -> i32 {\n    1\n}\n",
            "src/main.rs": "mod helper;\nuse helper::helper;\n\nfn main() {\n    let _ = helper() + helper();\n}\n",
        ])
        try await ra.open("src/main.rs")
        let locations = Location.parseAll(try await ra.request("textDocument/references", [
            "textDocument": ["uri": ra.uri("src/main.rs")],
            "position": TextPosition(line: 4, character: 13).json,
            "context": ["includeDeclaration": true],
        ]))
        #expect(locations.contains { $0.uri.hasSuffix("/src/helper.rs") && $0.start.line == 0 }, "\(locations)")
        #expect(locations.filter { $0.uri.hasSuffix("/src/main.rs") && $0.start.line == 4 }.count == 2)
        await ra.shutdown()
    }
}
