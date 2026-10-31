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

public struct CargoPackage: Sendable, Hashable {
    public var name: String
    public var manifestPath: String
    public var features: [String]
    public var targets: [CargoTarget]
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
            let features = package["features"]?.objectValue.map { $0.keys.filter { $0 != "default" }.sorted() } ?? []
            return CargoPackage(name: name, manifestPath: package["manifest_path"]?.stringValue ?? "",
                                features: features, targets: targets)
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
