import Foundation
import Testing
@testable import RustIDECore

@Suite struct CallHierarchyTests {
    @Test(.enabled(if: RustAnalyzerHarness.available), .timeLimit(.minutes(2)))
    func rustAnalyzerIncomingAndOutgoingCalls() async throws {
        let source = "fn leaf() {}\n\nfn middle() {\n    leaf();\n    leaf();\n}\n\nfn main() {\n    middle();\n}\n"
        let ra = try await RustAnalyzerHarness(files: ["src/main.rs": source])
        try await ra.open("src/main.rs")
        let items = CallHierarchyItem.parseAll(try await ra.request("textDocument/prepareCallHierarchy", ra.at("src/main.rs", 2, 4)))
        let middle = try #require(items.first)
        #expect(middle.name == "middle" && middle.position.line == 2)

        let incoming = CallHierarchyCall.parseAll(try await ra.request("callHierarchy/incomingCalls", ["item": middle.raw]))
        #expect(incoming.map(\.item.name) == ["main"])
        #expect(incoming.first?.callSites == [TextPosition(line: 8, character: 4)])

        let outgoing = CallHierarchyCall.parseAll(try await ra.request("callHierarchy/outgoingCalls", ["item": middle.raw]))
        #expect(outgoing.map(\.item.name) == ["leaf"])
        #expect(outgoing.first?.callSites.count == 2)
        await ra.shutdown()
    }
}
