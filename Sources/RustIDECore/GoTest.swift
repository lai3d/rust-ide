import Foundation

/// One line of `go test -json` output (test2json).
public struct GoTestEvent: Decodable, Sendable {
    public let action: String
    public let package: String?
    public let test: String?
    public let elapsed: Double?
    public let output: String?

    enum CodingKeys: String, CodingKey {
        case action = "Action", package = "Package", test = "Test", elapsed = "Elapsed", output = "Output"
    }
}

public struct GoTestResult: Sendable, Hashable, Identifiable {
    public enum Status: Sendable, Hashable { case running, passed, failed, skipped }

    public let package: String
    /// Test name (`TestX` or `TestX/sub`); nil for the package itself.
    public let name: String?
    public var status: Status
    public var elapsed: Double?
    public var output: String

    public var id: String { package + "|" + (name ?? "") }
    /// Nesting depth for subtests (`TestX/a/b` → 2).
    public var depth: Int { max(0, (name?.split(separator: "/").count ?? 1) - 1) }
    public var shortName: String { name.map { String($0.split(separator: "/").last ?? Substring($0)) } ?? package }
}

/// Aggregates a `go test -json` stream into per-test results.
public struct GoTestReport: Sendable {
    public private(set) var tests: [GoTestResult] = []
    public private(set) var packages: [GoTestResult] = []
    /// Build errors and any non-JSON output.
    public private(set) var buildOutput = ""
    private var testIndex: [String: Int] = [:]
    private var packageIndex: [String: Int] = [:]

    public init() {}

    public var passed: Int { tests.filter { $0.status == .passed }.count }
    public var failed: Int { tests.filter { $0.status == .failed }.count }
    public var skipped: Int { tests.filter { $0.status == .skipped }.count }
    public var anyPackageFailed: Bool { packages.contains { $0.status == .failed } }

    public mutating func consume(line: String) {
        guard line.hasPrefix("{"), let data = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(GoTestEvent.self, from: data)
        else {
            if !line.isEmpty { buildOutput += line + "\n" }
            return
        }
        switch event.action {
        case "build-output":
            buildOutput += event.output ?? ""
            return
        case "build-fail":
            return
        default:
            break
        }
        guard let package = event.package else { return }
        if let test = event.test {
            Self.update(&tests, &testIndex, key: package + "|" + test, package: package, name: test, event: event)
        } else {
            Self.update(&packages, &packageIndex, key: package, package: package, name: nil, event: event)
        }
    }

    private static func status(for action: String) -> GoTestResult.Status? {
        switch action {
        case "run", "start", "cont": .running
        case "pass": .passed
        case "fail": .failed
        case "skip": .skipped
        default: nil
        }
    }

    private static func update(_ list: inout [GoTestResult], _ index: inout [String: Int],
                                 key: String, package: String, name: String?, event: GoTestEvent) {
        let i: Int
        if let existing = index[key] {
            i = existing
        } else {
            list.append(GoTestResult(package: package, name: name, status: .running, elapsed: nil, output: ""))
            i = list.count - 1
            index[key] = i
        }
        if let output = event.output { list[i].output += output }
        if let status = status(for: event.action), event.action != "start" || list[i].status == .running {
            list[i].status = status
        }
        if let elapsed = event.elapsed { list[i].elapsed = elapsed }
    }
}

/// Finds Go test functions in source text.
public enum GoTestFinder {
    private static let declaration = try! NSRegularExpression(
        pattern: #"^func\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)\s*[\[(]"#, options: .anchorsMatchLines)

    /// `TestX`, `BenchmarkX`, `FuzzX`, `ExampleX` — the suffix must not start lowercase.
    public static func isTestName(_ name: String) -> Bool {
        for prefix in ["Test", "Benchmark", "Fuzz", "Example"] where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            return rest.first.map { !$0.isLowercase } ?? true
        }
        return false
    }

    /// Top-level test functions with their zero-based declaration lines.
    public static func testFunctions(in text: String) -> [(name: String, line: Int)] {
        let ns = text as NSString
        let index = LineIndex(text)
        return declaration.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let name = ns.substring(with: match.range(at: 1))
            // Methods (func (r T) TestX) aren't tests.
            guard isTestName(name), !ns.substring(with: match.range).hasPrefix("func (") else { return nil }
            return (name, index.position(of: match.range.location).line)
        }
    }

    /// The test function whose body contains `offset` (the nearest top-level func above it).
    public static func enclosingTest(in text: String, at offset: Int) -> String? {
        let ns = text as NSString
        var last: (name: String, isTest: Bool)?
        for match in declaration.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard match.range.location <= offset else { break }
            let name = ns.substring(with: match.range(at: 1))
            let isMethod = ns.substring(with: match.range).hasPrefix("func (")
            last = (name, !isMethod && isTestName(name))
        }
        return last?.isTest == true ? last?.name : nil
    }

    /// `file.go:12` references in test output, with their ranges in `line`.
    public static func fileReferences(in line: String) -> [(range: NSRange, file: String, line: Int)] {
        let regex = try! NSRegularExpression(pattern: #"([\w./-]+\.go):(\d+)"#)
        let ns = line as NSString
        return regex.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let number = Int(ns.substring(with: match.range(at: 2))) else { return nil }
            return (match.range, ns.substring(with: match.range(at: 1)), number)
        }
    }
}
