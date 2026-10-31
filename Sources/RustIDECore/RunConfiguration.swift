import Foundation

/// How to run/debug a main package: which one, with what arguments and environment.
public struct RunConfiguration: Codable, Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var name: String
    /// Package directory relative to the project root ("." for the root).
    public var package: String
    /// Program arguments, shell-style (quotes group words).
    public var arguments: String
    /// Extra environment, one `KEY=value` per line.
    public var environment: String

    public init(name: String, package: String, arguments: String = "", environment: String = "") {
        self.name = name
        self.package = package
        self.arguments = arguments
        self.environment = environment
    }

    public var argumentList: [String] { ShellWords.split(arguments) }

    public var environmentVariables: [String: String] {
        var result: [String: String] = [:]
        for line in environment.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            result[String(trimmed[..<eq])] = String(trimmed[trimmed.index(after: eq)...])
        }
        return result
    }

    /// `go run` / `dlv` package pattern: "./cmd/server" or ".".
    public var packagePattern: String { package == "." || package.isEmpty ? "." : "./" + package }
}

public enum ShellWords {
    /// Splits like a shell: whitespace separates words; '…' and "…" group; backslash escapes.
    public static func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for c in line {
            if escaped {
                current.append(c)
                escaped = false
            } else if c == "\\" && quote != "'" {
                escaped = true
                inWord = true
            } else if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c
                inWord = true
            } else if c.isWhitespace {
                if inWord { words.append(current); current = ""; inWord = false }
            } else {
                current.append(c)
                inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }
}

public enum GoPackages {
    /// Directories (relative to `root`, "." for the root) whose non-test files declare `package main`.
    public static func mainPackages(under root: URL) -> [String] {
        let rootPath = root.canonicalFileURL.path
        var found = Set<String>()
        for path in ProjectSearch.files(under: root) where path.hasSuffix(".go") && !path.hasSuffix("_test.go") {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  text.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "package main" })
            else { continue }
            let dir = (path as NSString).deletingLastPathComponent
            let relative = dir == rootPath ? "." : String(dir.dropFirst(rootPath.count + 1))
            found.insert(relative)
        }
        return found.sorted { $0 == "." || ($1 != "." && $0.localizedStandardCompare($1) == .orderedAscending) }
    }
}
