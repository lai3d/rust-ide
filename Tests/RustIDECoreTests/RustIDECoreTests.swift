import Foundation
import Testing
@testable import RustIDECore

@Suite struct LSPFramerTests {
    @Test func roundTripsSingleMessage() {
        var framer = LSPFramer()
        let body = Data(#"{"jsonrpc":"2.0","id":1}"#.utf8)
        #expect(framer.append(LSPFramer.frame(body)) == [body])
    }

    @Test func reassemblesSplitChunks() {
        var framer = LSPFramer()
        let body = Data(#"{"hello":"wörld"}"#.utf8)
        let framed = LSPFramer.frame(body)
        let mid = framed.count / 2
        #expect(framer.append(framed.prefix(mid)).isEmpty)
        #expect(framer.append(framed.suffix(from: mid)) == [body])
    }

    @Test func splitsMultipleMessagesInOneChunk() {
        var framer = LSPFramer()
        let a = Data("{}".utf8), b = Data("[1,2]".utf8)
        #expect(framer.append(LSPFramer.frame(a) + LSPFramer.frame(b)) == [a, b])
    }
}

@Suite struct JSONValueTests {
    @Test func roundTrips() throws {
        let value: JSONValue = ["a": 1, "b": [true, nil, "x"], "c": 1.5]
        let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
        #expect(decoded["a"]?.intValue == 1)
        #expect(decoded["b"]?[2]?.stringValue == "x")
    }
}

@Suite struct LineIndexTests {
    @Test func convertsPositions() {
        let index = LineIndex("ab\ncdef\n\ng")
        #expect(index.lineCount == 4)
        #expect(index.offset(of: TextPosition(line: 1, character: 2)) == 5)
        #expect(index.offset(of: TextPosition(line: 1, character: 99)) == 7)  // clamped before newline
        #expect(index.position(of: 5) == TextPosition(line: 1, character: 2))
        #expect(index.position(of: 9) == TextPosition(line: 3, character: 0))
    }

    @Test func usesUTF16Units() {
        let index = LineIndex("x😀y")  // emoji is 2 UTF-16 units, like LSP's default encoding
        #expect(index.offset(of: TextPosition(line: 0, character: 3)) == 3)
        #expect(index.utf16Count == 4)
    }
}

@Suite struct RustHighlighterTests {
    private func kinds(_ source: String) -> [(String, RustTokenKind)] {
        let ns = source as NSString
        return RustHighlighter.tokenize(source).map { (ns.substring(with: $0.range), $0.kind) }
    }

    @Test func classifiesTokens() {
        let tokens = kinds(#"fn main() { let x: u32 = len("hi // no") + 42; } // done"#)
        #expect(tokens.map(\.0) == ["fn", "main", "let", "u32", "len", #""hi // no""#, "42", "// done"])
        #expect(tokens.map(\.1) == [.keyword, .function, .keyword, .type, .function, .string, .number, .comment])
    }

    @Test func macrosAttributesAndTypes() {
        let tokens = kinds("#[derive(Debug, Clone)]\nstruct Point { x: f64 }\nprintln!(\"{}\", a != b);")
        #expect(tokens.map(\.0) == ["#[derive(Debug, Clone)]", "struct", "Point", "f64", "println!", "\"{}\""])
        #expect(tokens.map(\.1) == [.attribute, .keyword, .type, .type, .macro, .string])
    }

    @Test func lifetimesVersusCharLiterals() {
        let tokens = kinds(#"fn f<'a>(s: &'a str) -> char { 'x' } let n = '\n'; 'outer: loop {}"#)
        #expect(tokens.filter { $0.1 == .lifetime }.map(\.0) == ["'a", "'a", "'outer"])
        #expect(tokens.filter { $0.1 == .string }.map(\.0) == ["'x'", #"'\n'"#])
    }

    @Test func rawAndByteStrings() {
        let source = ##"let a = r#"say "hi""#; let b = b"bytes"; let c = br"raw"; let r#type = 1;"##
        let strings = kinds(source).filter { $0.1 == .string }.map(\.0)
        #expect(strings == [##"r#"say "hi""#"##, #"b"bytes""#, #"br"raw""#])
    }

    @Test func nestedBlockComments() {
        let tokens = kinds("/* a /* b */ still */ fn")
        #expect(tokens.map(\.1) == [.comment, .keyword])
        #expect(kinds("x /* open").last?.1 == .comment)
    }

    @Test func numbersWithSuffixesAndRanges() {
        let numbers = kinds("let v = [0xFF_u8, 1_000i64, 2.5e-3f32]; for i in 0..10 {} t.0").filter { $0.1 == .number }.map(\.0)
        #expect(numbers == ["0xFF_u8", "1_000i64", "2.5e-3f32", "0", "10", "0"])
    }

    @Test func turbofishCallsAndVariants() {
        let tokens = kinds("let v = iter.collect::<Vec<_>>(); Some(1)")
        #expect(tokens.contains { $0 == ("collect", .function) })
        #expect(tokens.contains { $0 == ("Vec", .type) })
        #expect(tokens.contains { $0 == ("Some", .builtin) })
    }
}

@Suite struct DiagnosticTests {
    @Test func parsesPublishDiagnostics() throws {
        let params: JSONValue = [
            "uri": "file:///tmp/main.go",
            "diagnostics": [
                ["range": ["start": ["line": 3, "character": 1], "end": ["line": 3, "character": 5]],
                 "severity": 1, "message": "undefined: foo", "source": "compiler"],
                ["range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]],
                 "severity": 2, "message": "warn"],
            ],
        ]
        let result = try #require(Diagnostic.parsePublish(params))
        #expect(result.uri == "file:///tmp/main.go")
        #expect(result.diagnostics.map(\.message) == ["warn", "undefined: foo"])  // sorted by position
        #expect(result.diagnostics[1].severity == .error)
        #expect(result.diagnostics[1].start == TextPosition(line: 3, character: 1))
    }
}

/// End-to-end check against a real rust-analyzer (skipped when it isn't installed).
@Suite struct RustAnalyzerIntegrationTests {
    @Test(.enabled(if: RustAnalyzerHarness.available), .timeLimit(.minutes(2)))
    func publishesDiagnosticsForBrokenCode() async throws {
        let ra = try await RustAnalyzerHarness(files: ["src/main.rs": "fn main() {\n    let x: i32 = \"no\";\n}\n"])
        try await ra.open("src/main.rs")
        let published = try await ra.waitFor { method, params in
            method == "textDocument/publishDiagnostics"
                && !(Diagnostic.parsePublish(params)?.diagnostics.isEmpty ?? true)
        }
        let diagnostics = try #require(Diagnostic.parsePublish(published)).diagnostics
        #expect(diagnostics.contains { $0.severity == .error && $0.start.line == 1 }, "\(diagnostics)")
        await ra.shutdown()
    }
}
