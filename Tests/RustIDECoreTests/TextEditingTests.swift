import Foundation
import Testing
@testable import RustIDECore

@Suite struct TextEditingTests {
    /// Applies a change and renders the selection as [ ] or | for readable expectations.
    private func run(_ text: String, _ selection: NSRange, _ change: (String, NSRange) -> TextChange?) -> String? {
        guard let c = change(text, selection) else { return nil }
        let result = NSMutableString(string: c.applied(to: text))
        if c.selection.length == 0 {
            result.insert("|", at: c.selection.location)
        } else {
            result.insert("]", at: NSMaxRange(c.selection))
            result.insert("[", at: c.selection.location)
        }
        return result as String
    }

    @Test func togglesComments() {
        let text = "func f() {\n\tx := 1\n\n\ty := 2\n}\n"
        let both = NSRange(location: 11, length: 17)  // lines 2–4
        #expect(run(text, both, TextEditing.toggleComment) == "func f() {\n[\t// x := 1\n\n\t// y := 2]\n}\n")
        let commented = "func f() {\n\t// x := 1\n\n\t// y := 2\n}\n"
        #expect(run(commented, NSRange(location: 11, length: 23), TextEditing.toggleComment) == "func f() {\n[\tx := 1\n\n\ty := 2]\n}\n")
        #expect(run("a := 1\n", NSRange(location: 2, length: 0), TextEditing.toggleComment) == "// a |:= 1\n")
        #expect(run("// a := 1\n", NSRange(location: 5, length: 0), TextEditing.toggleComment) == "a |:= 1\n")
    }

    @Test func indentsAndOutdents() {
        #expect(run("a\nb\n", NSRange(location: 0, length: 3), { TextEditing.shiftLines(in: $0, selection: $1, outdent: false) }) == "[\ta\n\tb]\n")
        #expect(run("\ta\n    b\n", NSRange(location: 0, length: 8), { TextEditing.shiftLines(in: $0, selection: $1, outdent: true) }) == "[a\nb]\n")
        #expect(run("\tx\n", NSRange(location: 2, length: 0), { TextEditing.shiftLines(in: $0, selection: $1, outdent: true) }) == "x|\n")
    }

    @Test func duplicatesLines() {
        #expect(run("a\nb\n", NSRange(location: 0, length: 0), TextEditing.duplicateLines) == "a\n|a\nb\n")
        #expect(run("a\nb", NSRange(location: 3, length: 0), TextEditing.duplicateLines) == "a\nb\nb|")
    }

    @Test func movesLines() {
        let up = { (t: String, s: NSRange) in TextEditing.moveLines(in: t, selection: s, up: true) }
        let down = { (t: String, s: NSRange) in TextEditing.moveLines(in: t, selection: s, up: false) }
        #expect(run("a\nb\nc\n", NSRange(location: 2, length: 0), up) == "|b\na\nc\n")
        #expect(run("a\nb\nc\n", NSRange(location: 2, length: 0), down) == "a\nc\n|b\n")
        #expect(run("a\nb\nc", NSRange(location: 4, length: 0), up) == "a\n|c\nb")          // last line, no newline
        #expect(run("a\nb\nc", NSRange(location: 2, length: 0), down) == "a\nc\n|b")
        #expect(run("a\nb\n", NSRange(location: 0, length: 0), up) == nil)
        #expect(run("a\nb", NSRange(location: 2, length: 0), down) == nil)
    }

    @Test func decidesAutoClosing() {
        let text = "f(x) abc" as NSString
        #expect(TextEditing.shouldAutoClose("(", in: text, at: 8))   // end of text
        #expect(TextEditing.shouldAutoClose("(", in: text, at: 3))   // before ")"
        #expect(!TextEditing.shouldAutoClose("(", in: text, at: 5))  // before "a"
        #expect(!TextEditing.shouldAutoClose("\"", in: text, at: 8)) // after a word: likely closing a string
        #expect(TextEditing.shouldAutoClose("\"", in: "x := " as NSString, at: 5))
    }
}
