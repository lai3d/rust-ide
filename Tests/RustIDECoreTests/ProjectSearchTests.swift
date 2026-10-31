import Foundation
import Testing
@testable import RustIDECore

@Suite struct ProjectSearchTests {
    @Test func literalSearchIsCaseInsensitiveByDefault() throws {
        let regex = try ProjectSearch.makeRegex("println", options: SearchOptions())
        let found = ProjectSearch.matches(of: regex, in: "package main\n\n\tfmt.Println(x) // println\n")
        #expect(found.count == 2)
        #expect(found[0].line == 2 && found[0].column == 5 && found[0].length == 7)
        #expect(found[0].preview == "fmt.Println(x) // println")  // indent trimmed
        #expect(found[0].previewRange == NSRange(location: 4, length: 7))
    }

    @Test func optionsChangeMatching() throws {
        let text = "Foo foo food a.b axb"
        #expect(ProjectSearch.matches(of: try .init(pattern: "x"), in: "").isEmpty)
        #expect(ProjectSearch.matches(of: try ProjectSearch.makeRegex("foo", options: .init(caseSensitive: true)), in: text).count == 2)
        #expect(ProjectSearch.matches(of: try ProjectSearch.makeRegex("foo", options: .init(wholeWord: true)), in: text).count == 2)
        #expect(ProjectSearch.matches(of: try ProjectSearch.makeRegex("a.b", options: .init()), in: text).count == 1)  // literal dot
        #expect(ProjectSearch.matches(of: try ProjectSearch.makeRegex("a.b", options: .init(regex: true)), in: text).count == 2)
        #expect(throws: (any Error).self) { try ProjectSearch.makeRegex("(", options: .init(regex: true)) }
    }

    @Test func columnsAreUTF16() throws {
        let found = ProjectSearch.matches(of: try ProjectSearch.makeRegex("x", options: .init()), in: "😀x")
        #expect(found.first?.column == 2)
    }

    @Test func searchesProjectFilesSkippingIgnoredAndBinary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rustide-search-\(UUID().uuidString)")
        let fm = FileManager.default
        for dir in ["pkg", "target/x", ".git"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }
        try "needle\n".write(to: root.appendingPathComponent("a.rs"), atomically: true, encoding: .utf8)
        try "x\nneedle needle\n".write(to: root.appendingPathComponent("pkg/b.rs"), atomically: true, encoding: .utf8)
        try "needle\n".write(to: root.appendingPathComponent("target/x/c.rs"), atomically: true, encoding: .utf8)
        try "needle\n".write(to: root.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        try Data([0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65, 0x00]).write(to: root.appendingPathComponent("bin"))

        let results = try ProjectSearch.search(root: root, query: "needle", options: .init())
        #expect(results.map { ($0.path as NSString).lastPathComponent } == ["a.rs", "b.rs"])
        #expect(results.last?.matches.count == 2)

        // Unsaved buffers win over disk contents.
        let a = root.appendingPathComponent("a.rs").path
        let overridden = try ProjectSearch.search(root: root, query: "needle", options: .init(), overrides: [a: "nothing"])
        #expect(overridden.map { ($0.path as NSString).lastPathComponent } == ["b.rs"])
    }
}

@Suite struct ReplaceTests {
    @Test func replacesLiteralAndRegex() throws {
        let literal = try ProjectSearch.makeRegex("a.b", options: .init())
        let t1 = ProjectSearch.template(for: "$x", options: .init())
        #expect(ProjectSearch.replaceAll(in: "a.b axb a.b", regex: literal, template: t1) == ("$x axb $x", 2))

        let options = SearchOptions(regex: true)
        let regex = try ProjectSearch.makeRegex(#"get(\w+)\("#, options: options)
        let t2 = ProjectSearch.template(for: "fetch$1(", options: options)
        #expect(ProjectSearch.replaceAll(in: "getUser(1) getName(2)", regex: regex, template: t2).text == "fetchUser(1) fetchName(2)")
        #expect(ProjectSearch.replaceMatch(in: "getUser(1) getName(2)", at: 11, regex: regex, template: t2) == "getUser(1) fetchName(2)")
        #expect(ProjectSearch.replaceMatch(in: "getUser(1)", at: 3, regex: regex, template: t2) == nil)
        #expect(ProjectSearch.preview(of: "getUser(", regex: regex, template: t2) == "fetchUser(")
    }
}
