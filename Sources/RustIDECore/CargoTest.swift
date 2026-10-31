import Foundation

public struct TestResult: Sendable, Hashable, Identifiable {
    public enum Status: Sendable, Hashable { case running, passed, failed, skipped }

    /// The test binary: "unittests src/lib.rs", "tests/api.rs", "doc-tests mycrate".
    public let suite: String
    /// Module path of the test (`tests::adds`).
    public let name: String
    public var status: Status
    public var output: String

    public var id: String { suite + "|" + name }
    /// Nesting depth from the module path (`a::b::c` → 2).
    public var depth: Int { max(0, name.components(separatedBy: "::").count - 1) }
    public var shortName: String { name.components(separatedBy: "::").last ?? name }
}

/// Aggregates `cargo test` (libtest) text output into per-test results, line by line.
///
///          Running unittests src/main.rs (target/debug/deps/hello-1a2b)
///     test tests::adds ... ok
///     test tests::fails ... FAILED
///     ---- tests::fails stdout ----
///     thread 'tests::fails' panicked at src/main.rs:20:9: …
///     test result: FAILED. 1 passed; 1 failed; 0 ignored; …
public struct CargoTestReport: Sendable {
    public private(set) var tests: [TestResult] = []
    /// Compiler output and anything outside a test binary's run.
    public private(set) var buildOutput = ""
    private var index: [String: Int] = [:]
    private var suite = ""
    /// Test whose captured stdout is being read (`---- name stdout ----`).
    private var capturing: Int?

    public init() {}

    public var passed: Int { tests.filter { $0.status == .passed }.count }
    public var failed: Int { tests.filter { $0.status == .failed }.count }
    public var skipped: Int { tests.filter { $0.status == .skipped }.count }

    private static let resultLine = try! NSRegularExpression(pattern: #"^test (.+?) \.\.\. (ok|FAILED|ignored(?:, .*)?)$"#)
    private static let runningLine = try! NSRegularExpression(pattern: #"^\s*Running (.+?)(?: \(.*\))?$"#)

    public mutating func consume(line: String) {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let match = Self.runningLine.firstMatch(in: line, range: full) {
            suite = ns.substring(with: match.range(at: 1))
            capturing = nil
            return
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("Doc-tests ") {
            suite = "doc-tests " + trimmed.dropFirst("Doc-tests ".count)
            capturing = nil
            return
        }
        if let match = Self.resultLine.firstMatch(in: line, range: full) {
            let name = ns.substring(with: match.range(at: 1))
            let verdict = ns.substring(with: match.range(at: 2))
            let status: TestResult.Status = verdict == "ok" ? .passed : verdict == "FAILED" ? .failed : .skipped
            record(name).map { tests[$0].status = status }
            return
        }
        if line.hasPrefix("---- "), line.hasSuffix(" stdout ----") {
            let name = String(line.dropFirst(5).dropLast(" stdout ----".count))
            capturing = record(name)
            return
        }
        if line == "failures:" || line.hasPrefix("test result: ") {
            capturing = nil
            return
        }
        if let i = capturing {
            tests[i].output += line + "\n"
        } else if suite.isEmpty {
            buildOutput += line + "\n"
        }
    }

    /// Index of `name` in the current suite, added as running if new.
    private mutating func record(_ name: String) -> Int? {
        guard !name.isEmpty else { return nil }
        let key = suite + "|" + name
        if let i = index[key] { return i }
        tests.append(TestResult(suite: suite, name: name, status: .running, output: ""))
        index[key] = tests.count - 1
        return tests.count - 1
    }
}

/// Finds `#[test]` functions in Rust source and their module paths.
public enum RustTestFinder {
    public struct TestFunction: Sendable, Hashable {
        /// Path within the file (`tests::adds`), without the file's own module path.
        public let path: String
        public let name: String
        /// Zero-based line of the `fn`.
        public let line: Int
        /// UTF-16 range from the attribute through the end of the body (best effort).
        public let range: NSRange
    }

    /// Test functions: `fn` items preceded by an attribute ending in `test` (`#[test]`,
    /// `#[tokio::test]`, `#[test_case(…)]` …), with enclosing inline `mod` names.
    public static func testFunctions(in text: String) -> [TestFunction] {
        let ns = text as NSString
        let lineIndex = LineIndex(text)
        // Blank out comments and strings so braces and keywords inside them don't count.
        var chars = Array(text.utf16)
        var attributes: [NSRange] = []
        for token in RustHighlighter.tokenize(text) {
            switch token.kind {
            case .comment, .string:
                for i in token.range.location..<NSMaxRange(token.range) where chars[i] != 0x0A { chars[i] = 0x20 }
            case .attribute:
                attributes.append(token.range)
            default:
                break
            }
        }
        let clean = String(utf16CodeUnits: chars, count: chars.count) as NSString

        let item = try! NSRegularExpression(pattern: #"\b(mod|fn)\s+(r#)?([A-Za-z_][A-Za-z0-9_]*)"#)
        var modules: [(name: String, depth: Int)] = []
        var results: [TestFunction] = []
        var depth = 0
        var pendingMod: String?
        var pendingTest: (name: String, start: Int, line: Int, path: String)?
        var openTest: (fn: (name: String, start: Int, line: Int, path: String), depth: Int)?
        var i = 0
        let matches = item.matches(in: clean as String, range: NSRange(location: 0, length: clean.length))
        var nextMatch = 0
        while i < clean.length {
            if nextMatch < matches.count, matches[nextMatch].range.location == i {
                let match = matches[nextMatch]
                nextMatch += 1
                let keyword = clean.substring(with: match.range(at: 1))
                let name = clean.substring(with: match.range(at: 3))
                if keyword == "mod" {
                    pendingMod = name
                } else if openTest == nil, isTest(before: match.range.location, attributes: attributes, in: ns) {
                    let start = attributeStart(before: match.range.location, attributes: attributes, in: ns)
                    let path = (modules.map(\.name) + [name]).joined(separator: "::")
                    pendingTest = (name, start, lineIndex.position(of: match.range.location).line, path)
                }
                i = NSMaxRange(match.range)
                continue
            }
            let c = clean.character(at: i)
            if c == 0x7B {  // {
                depth += 1
                if let name = pendingMod { modules.append((name, depth)); pendingMod = nil }
                if let test = pendingTest { openTest = (test, depth); pendingTest = nil }
            } else if c == 0x7D {  // }
                if let open = openTest, open.depth == depth {
                    results.append(TestFunction(path: open.fn.path, name: open.fn.name, line: open.fn.line,
                                                range: NSRange(location: open.fn.start, length: i + 1 - open.fn.start)))
                    openTest = nil
                }
                if modules.last?.depth == depth { modules.removeLast() }
                depth -= 1
            } else if c == 0x3B {  // ; — `mod foo;` declares a file module, not an inline one
                pendingMod = nil
            }
            i += 1
        }
        return results
    }

    /// The test function containing `offset`, if any.
    public static func enclosingTest(in text: String, at offset: Int) -> TestFunction? {
        testFunctions(in: text).first { NSLocationInRange(offset, $0.range) || NSMaxRange($0.range) == offset }
    }

    /// Module path of a file within its crate: `src/net/http.rs` → `net::http`,
    /// `src/net/mod.rs` → `net`, crate roots (`lib.rs`, `main.rs`, `src/bin/x.rs`, `tests/x.rs`) → "".
    public static func modulePath(ofFile path: String, packageRoot: String) -> String {
        guard path.hasPrefix(packageRoot + "/") else { return "" }
        var parts = String(path.dropFirst(packageRoot.count + 1)).components(separatedBy: "/")
        guard let first = parts.first else { return "" }
        if first == "tests" || first == "examples" || first == "benches" { return "" }  // own crate roots (single-file)
        guard first == "src" else { return "" }
        parts.removeFirst()
        if parts.first == "bin" { return "" }
        guard var last = parts.popLast() else { return "" }
        last = (last as NSString).deletingPathExtension
        if parts.isEmpty, last == "lib" || last == "main" { return "" }
        if last != "mod" { parts.append(last) }
        return parts.joined(separator: "::")
    }

    /// Joins a file's module path and a path inside the file.
    public static func join(_ modulePath: String, _ path: String) -> String {
        modulePath.isEmpty ? path : modulePath + "::" + path
    }

    /// `cargo test` flags selecting the test target a file belongs to.
    public static func targetArguments(forFile path: String, in metadata: CargoMetadata) -> [String] {
        guard let package = metadata.package(containing: path) else { return [] }
        let root = (package.manifestPath as NSString).deletingLastPathComponent
        var args = ["-p", package.name]
        // A target whose crate root is this very file (tests/x.rs, src/bin/x.rs, src/main.rs …).
        if let target = package.targets.first(where: { $0.srcPath == path }) {
            switch target.kind {
            case .test: args += ["--test", target.name]
            case .bin: args += ["--bin", target.name]
            case .example: args += ["--example", target.name]
            case .bench: args += ["--bench", target.name]
            case .lib: args.append("--lib")
            default: break
            }
            return args
        }
        let relative = String(path.dropFirst(root.count + 1))
        if relative.hasPrefix("tests/"), let first = relative.split(separator: "/").dropFirst().first,
           let target = package.targets.first(where: { $0.kind == .test && $0.name == first }) {
            args += ["--test", target.name]  // tests/<name>/main.rs modules
        } else if package.targets.contains(where: { $0.kind == .lib }) {
            args.append("--lib")
        } else if let bin = package.targets.first(where: { $0.kind == .bin }) {
            args += ["--bin", bin.name]
        }
        return args
    }

    private static func isTest(before location: Int, attributes: [NSRange], in ns: NSString) -> Bool {
        precedingAttributes(before: location, attributes: attributes, in: ns).contains { range in
            let text = ns.substring(with: range)
            guard let open = text.firstIndex(of: "[") else { return false }
            let body = text[text.index(after: open)...]
            let name = body.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == ":" }
            return name == "test" || name.hasSuffix("::test") || name == "test_case" || name == "rstest"
        }
    }

    private static func attributeStart(before location: Int, attributes: [NSRange], in ns: NSString) -> Int {
        precedingAttributes(before: location, attributes: attributes, in: ns).map(\.location).min() ?? location
    }

    /// Attributes directly above an item: only whitespace, other attributes, and
    /// modifiers (`pub`, `async`, `unsafe`) between them and the `fn`.
    private static func precedingAttributes(before location: Int, attributes: [NSRange], in ns: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var cursor = location
        for attribute in attributes.reversed() where NSMaxRange(attribute) <= cursor {
            let gap = ns.substring(with: NSRange(location: NSMaxRange(attribute), length: cursor - NSMaxRange(attribute)))
            let words = gap.split(whereSeparator: { $0.isWhitespace })
            guard words.allSatisfy({ ["pub", "async", "unsafe", "const", "extern", "pub(crate)"].contains($0) }) else { break }
            result.append(attribute)
            cursor = attribute.location
        }
        return result
    }
}

public extension CargoMetadata {
    /// The package whose directory most specifically contains `path`.
    func package(containing path: String) -> CargoPackage? {
        packages
            .filter { path.hasPrefix(($0.manifestPath as NSString).deletingLastPathComponent + "/") }
            .max { $0.manifestPath.count < $1.manifestPath.count }
    }
}
