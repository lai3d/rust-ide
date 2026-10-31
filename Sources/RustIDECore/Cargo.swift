import Foundation

/// A Cargo build target (`cargo metadata` → packages[].targets[]).
public struct CargoTarget: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case bin, example, lib, test, bench, buildScript = "custom-build", other
    }

    public var package: String
    public var name: String
    public var kind: Kind
    public var srcPath: String
    public var requiredFeatures: [String]

    public init(package: String, name: String, kind: Kind, srcPath: String, requiredFeatures: [String] = []) {
        self.package = package
        self.name = name
        self.kind = kind
        self.srcPath = srcPath
        self.requiredFeatures = requiredFeatures
    }

    /// Targets `cargo run` can start.
    public var isRunnable: Bool { kind == .bin || kind == .example }
}

/// A dependency as declared in a manifest (`cargo metadata` → packages[].dependencies[]).
public struct CargoDependency: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case normal, dev, build

        public var title: String {
            switch self {
            case .normal: "Dependencies"
            case .dev: "Dev Dependencies"
            case .build: "Build Dependencies"
            }
        }

        /// `cargo add` / `cargo remove` flag.
        public var flag: String? {
            switch self {
            case .normal: nil
            case .dev: "--dev"
            case .build: "--build"
            }
        }
    }

    public enum Source: Sendable, Hashable {
        case registry, path(String), git(String)
    }

    /// Crate name (the package name, not the `rename`).
    public var name: String
    /// Name used in code when renamed (`foo = { package = "bar" }`).
    public var rename: String?
    public var req: String
    public var kind: Kind
    public var optional: Bool
    /// `cfg(...)` or triple for target-specific dependencies.
    public var target: String?
    public var source: Source
    public var features: [String]

    public var id: String { "\(kind.rawValue)|\(target ?? "")|\(rename ?? name)" }
    public var isRegistry: Bool { source == .registry }

    public init(name: String, rename: String? = nil, req: String, kind: Kind = .normal, optional: Bool = false,
                target: String? = nil, source: Source = .registry, features: [String] = []) {
        self.name = name
        self.rename = rename
        self.req = req
        self.kind = kind
        self.optional = optional
        self.target = target
        self.source = source
        self.features = features
    }

    init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue else { return nil }
        let sourceString = json["source"]?.stringValue
        let source: Source = if let path = json["path"]?.stringValue {
            .path(path)
        } else if let sourceString, sourceString.hasPrefix("git+") {
            .git(String(sourceString.dropFirst(4)))
        } else {
            .registry
        }
        self.init(name: name, rename: json["rename"]?.stringValue, req: json["req"]?.stringValue ?? "*",
                  kind: Kind(rawValue: json["kind"]?.stringValue ?? "normal") ?? .normal,
                  optional: json["optional"]?.boolValue ?? false, target: json["target"]?.stringValue,
                  source: source, features: json["features"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }
}

public struct CargoPackage: Sendable, Hashable {
    public var name: String
    public var manifestPath: String
    /// Feature names, without `default`.
    public var features: [String]
    public var targets: [CargoTarget]
    public var dependencies: [CargoDependency] = []
    /// What `default` turns on.
    public var defaultFeatures: [String] = []
    /// feature → what it enables (`dep:foo`, `other`, `foo/bar`).
    public var featureMap: [String: [String]] = [:]

    public var directory: String { (manifestPath as NSString).deletingLastPathComponent }

    /// `-p name/feature` style key used for workspace-wide feature selection.
    public func featureKey(_ feature: String) -> String { "\(name)/\(feature)" }
}

/// The parts of `cargo metadata --no-deps --format-version 1` RustIDE uses.
public struct CargoMetadata: Sendable, Hashable {
    public var workspaceRoot: String
    public var targetDirectory: String
    public var packages: [CargoPackage]

    /// Binaries first (in package order), then examples.
    public var runnableTargets: [CargoTarget] {
        let all = packages.flatMap(\.targets).filter(\.isRunnable)
        return all.filter { $0.kind == .bin } + all.filter { $0.kind == .example }
    }

    public static func parse(_ data: Data) -> CargoMetadata? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let root = json["workspace_root"]?.stringValue else { return nil }
        let packages: [CargoPackage] = (json["packages"]?.arrayValue ?? []).compactMap { package in
            guard let name = package["name"]?.stringValue else { return nil }
            let targets: [CargoTarget] = (package["targets"]?.arrayValue ?? []).compactMap { target in
                guard let targetName = target["name"]?.stringValue,
                      let src = target["src_path"]?.stringValue else { return nil }
                let kinds = target["kind"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let kind: CargoTarget.Kind = kinds.contains("bin") ? .bin
                    : kinds.contains("example") ? .example
                    : kinds.contains("test") ? .test
                    : kinds.contains("bench") ? .bench
                    : kinds.contains("custom-build") ? .buildScript
                    : kinds.contains(where: { ["lib", "rlib", "dylib", "cdylib", "staticlib", "proc-macro"].contains($0) }) ? .lib
                    : .other
                return CargoTarget(package: name, name: targetName, kind: kind, srcPath: src,
                                   requiredFeatures: target["required-features"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            }
            let featureMap = (package["features"]?.objectValue ?? [:])
                .mapValues { $0.arrayValue?.compactMap(\.stringValue) ?? [] }
            return CargoPackage(name: name, manifestPath: package["manifest_path"]?.stringValue ?? "",
                                features: featureMap.keys.filter { $0 != "default" }.sorted(), targets: targets,
                                dependencies: (package["dependencies"]?.arrayValue ?? []).compactMap(CargoDependency.init(json:)),
                                defaultFeatures: featureMap["default"] ?? [], featureMap: featureMap)
        }
        return CargoMetadata(workspaceRoot: root,
                             targetDirectory: json["target_directory"]?.stringValue ?? root + "/target",
                             packages: packages)
    }

    /// Runs `cargo metadata` in `root` (blocking; call off the main thread). Nil if not a Cargo project.
    public static func load(root: URL) -> CargoMetadata? {
        guard let cargo = ToolLocator.find("cargo"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("Cargo.toml").path) else { return nil }
        let process = Process()
        process.executableURL = cargo
        process.arguments = ["metadata", "--no-deps", "--format-version", "1"]
        process.currentDirectoryURL = root
        process.environment = ToolLocator.environment()
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? parse(data) : nil
    }
}

/// Resolved versions from `Cargo.lock` (`[[package]]` tables: name + version).
public enum CargoLock {
    /// Crate name → locked versions (several when semver-incompatible versions coexist).
    public static func versions(in text: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var name: String?
        var version: String?
        func flush() {
            if let name, let version { result[name, default: []].append(version) }
            name = nil
            version = nil
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                flush()
            } else if let value = stringValue(line, key: "name") {
                name = value
            } else if let value = stringValue(line, key: "version") {
                version = value
            }
        }
        flush()
        return result
    }

    /// `key = "value"` → value.
    private static func stringValue(_ line: String, key: String) -> String? {
        guard line.hasPrefix(key) else { return nil }
        let rest = line.dropFirst(key.count).drop { $0 == " " }
        guard rest.first == "=" else { return nil }
        let value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return nil }
        return String(value.dropFirst().dropLast())
    }

    public static func load(workspaceRoot: String) -> [String: [String]] {
        (try? String(contentsOfFile: workspaceRoot + "/Cargo.lock", encoding: .utf8)).map(versions(in:)) ?? [:]
    }
}

/// `path/file.rs:12:5` references in compiler / test output (e.g. rustc's `--> src/main.rs:3:9`,
/// panics' `at src/lib.rs:10:5`), with their ranges in `line`.
public enum OutputReferences {
    private static let regex = try! NSRegularExpression(pattern: #"((?:[\w.\-]+/)*[\w.\-]+\.rs):(\d+)(?::(\d+))?"#)

    public static func find(in line: String) -> [(range: NSRange, file: String, line: Int, column: Int?)] {
        let ns = line as NSString
        return regex.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let number = Int(ns.substring(with: match.range(at: 2))) else { return nil }
            let column = match.range(at: 3).location == NSNotFound ? nil : Int(ns.substring(with: match.range(at: 3)))
            return (match.range, ns.substring(with: match.range(at: 1)), number, column)
        }
    }
}

/// An executable cargo produced (`--message-format=json` → `compiler-artifact` with `executable`).
public struct CargoArtifact: Sendable, Hashable {
    public var targetName: String
    public var kinds: [String]
    /// Built with the test harness (`cargo test --no-run`).
    public var isTest: Bool
    public var executable: String

    /// Executables from cargo's JSON message stream (non-JSON lines are ignored).
    public static func executables(in lines: [String]) -> [CargoArtifact] {
        lines.compactMap { line in
            guard line.hasPrefix("{"), let json = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                  json["reason"]?.stringValue == "compiler-artifact",
                  let executable = json["executable"]?.stringValue,
                  let name = json["target"]?["name"]?.stringValue else { return nil }
            return CargoArtifact(targetName: name,
                                 kinds: json["target"]?["kind"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                                 isTest: json["profile"]?["test"]?.boolValue ?? false,
                                 executable: executable)
        }
    }
}

/// Settings that make LLDB show Rust values well: rustc's own formatters
/// (`<sysroot>/lib/rustlib/etc/lldb_lookup.py` + `lldb_commands`, what `rust-lldb` loads).
public enum RustLLDB {
    public static func initCommands(sysroot: String?) -> [String] {
        guard let sysroot else { return [] }
        let etc = sysroot + "/lib/rustlib/etc"
        guard FileManager.default.fileExists(atPath: etc + "/lldb_lookup.py") else { return [] }
        var commands = ["command script import \"\(etc)/lldb_lookup.py\""]
        if FileManager.default.fileExists(atPath: etc + "/lldb_commands") {
            commands.append("command source -s 0 \"\(etc)/lldb_commands\"")
        }
        return commands
    }

    /// `rustc --print sysroot` (blocking).
    public static func sysroot() -> String? {
        guard let rustc = ToolLocator.find("rustc") else { return nil }
        let process = Process()
        process.executableURL = rustc
        process.arguments = ["--print", "sysroot"]
        process.environment = ToolLocator.environment()
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !path.isEmpty ? path : nil
    }
}
