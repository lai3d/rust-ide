import Foundation
import Testing
@testable import RustIDECore

@Suite struct SnippetTests {
    private func parts(_ s: Snippet) -> [String] {
        s.stops.map { (s.text as NSString).substring(with: $0) }
    }

    @Test func parsesStopsPlaceholdersAndChoices() {
        let s = Snippet.parse("for ${1:i} := 0; ${1} < ${2:n}; ${3|i++,i--|} {\n\t$0\n}")
        #expect(s.text == "for i := 0;  < n; i++ {\n\t\n}")
        #expect(parts(s) == ["i", "n", "i++", ""])
        #expect(s.stops.last == NSRange(location: 25, length: 0))
    }

    @Test func parsesNestingAndEscapes() {
        let s = Snippet.parse("Printf(${1:\"${2:%v}\\n\"}, ${3:a ...any}) \\$x \\}")
        #expect(s.text == "Printf(\"%v\\n\", a ...any) $x }")
        #expect(parts(s) == ["\"%v\\n\"", "%v", "a ...any", ""])
        #expect(Snippet.parse("plain").stops == [NSRange(location: 5, length: 0)])
    }

    @Test func indentsFollowingLines() {
        let s = Snippet.parse("if err != nil {\n\treturn ${1:err}\n}$0").indented("\t\t")
        #expect(s.text == "if err != nil {\n\t\t\treturn err\n\t\t}")
        #expect(parts(s) == ["err", ""])
        #expect(s.stops.last == NSRange(location: (s.text as NSString).length, length: 0))
    }

    @Test func builtInSnippetsMatchTriggers() {
        #expect(RustSnippets.completions(matching: "iflet").map(\.label) == ["iflet"])
        #expect(RustSnippets.completions(matching: "im").map(\.label).contains("implt"))
        #expect(RustSnippets.completions(matching: "x").isEmpty)
        #expect(RustSnippets.all.allSatisfy { !Snippet.parse($0.body).stops.isEmpty })
        #expect(RustSnippets.all.allSatisfy { !$0.body.contains("\t") })  // rustfmt style: spaces
    }

    @Test func expandsNestedPlaceholders() {
        let fn = Snippet.parse(RustSnippets.all.first { $0.trigger == "fn" }!.body)
        #expect(fn.text == "fn name() -> () {\n    \n}")
        let ns = fn.text as NSString
        #expect(fn.stops.map { ns.substring(with: $0) }.prefix(3) == ["name", "", "-> () "])
    }
}
