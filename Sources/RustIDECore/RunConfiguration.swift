import Foundation

/// How to run/debug a Cargo binary or example: which target, profile, features, arguments, environment.
public struct RunConfiguration: Codable, Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var name: String
    /// Cargo package name (`-p`); empty for a single-package project.
    public var package: String
    /// Binary or example name.
    public var target: String
    public var kind: CargoTarget.Kind
    /// Space- or comma-separated features (`--features`).
    public var features: String
    public var release: Bool
    /// Program arguments, shell-style (quotes group words).
    public var arguments: String
    /// Extra environment, one `KEY=value` per line.
    public var environment: String

    public init(name: String, package: String = "", target: String, kind: CargoTarget.Kind = .bin,
                features: String = "", release: Bool = false, arguments: String = "", environment: String = "") {
        self.name = name
        self.package = package
        self.target = target
        self.kind = kind
        self.features = features
        self.release = release
        self.arguments = arguments
        self.environment = environment
    }

    public init(target: CargoTarget) {
        self.init(name: target.kind == .example ? "\(target.name) (example)" : target.name,
                  package: target.package, target: target.name, kind: target.kind,
                  features: target.requiredFeatures.joined(separator: " "))
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

    /// Target selection flags shared by `cargo run` and `cargo build`.
    public var cargoTargetArguments: [String] {
        var args: [String] = []
        if !package.isEmpty { args += ["-p", package] }
        if !target.isEmpty { args += [kind == .example ? "--example" : "--bin", target] }
        let featureList = features.split(whereSeparator: { $0 == " " || $0 == "," }).joined(separator: ",")
        if !featureList.isEmpty { args += ["--features", featureList] }
        if release { args.append("--release") }
        return args
    }

    /// `cargo run …  -- <args>`.
    public var cargoRunArguments: [String] {
        let program = argumentList
        return ["run"] + cargoTargetArguments + (program.isEmpty ? [] : ["--"] + program)
    }

    /// Where `cargo build` puts the executable.
    public func executablePath(targetDirectory: String) -> String {
        let profile = release ? "release" : "debug"
        return kind == .example ? "\(targetDirectory)/\(profile)/examples/\(target)" : "\(targetDirectory)/\(profile)/\(target)"
    }
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
