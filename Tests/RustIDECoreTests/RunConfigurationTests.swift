import Foundation
import Testing
@testable import RustIDECore

@Suite struct RunConfigurationTests {
    @Test func splitsShellWords() {
        #expect(ShellWords.split(#"-port 8080 --name "my app" 'a b' c\ d"#) == ["-port", "8080", "--name", "my app", "a b", "c d"])
        #expect(ShellWords.split("   ").isEmpty)
        #expect(ShellWords.split(#"--flag="" x"#) == ["--flag=", "x"])
    }

    @Test func buildsCargoArguments() {
        let config = RunConfiguration(name: "server", package: "web", target: "server", features: "tls, metrics",
                                      arguments: "--port 8080", environment: "PORT=8080\n# comment\nDSN=postgres://u@h/db?x=1\n\n")
        #expect(config.environmentVariables == ["PORT": "8080", "DSN": "postgres://u@h/db?x=1"])
        #expect(config.cargoRunArguments == ["run", "-p", "web", "--bin", "server", "--features", "tls,metrics", "--", "--port", "8080"])
        #expect(config.executablePath(targetDirectory: "/p/target") == "/p/target/debug/server")

        let example = RunConfiguration(name: "demo", target: "demo", kind: .example, release: true)
        #expect(example.cargoRunArguments == ["run", "--example", "demo", "--release"])
        #expect(example.executablePath(targetDirectory: "/p/target") == "/p/target/release/examples/demo")
    }

    @Test func parsesCargoMetadata() throws {
        let json = #"""
        {"packages":[{"name":"app","manifest_path":"/w/app/Cargo.toml","features":{"default":["tls"],"tls":[]},
          "targets":[{"name":"app","kind":["lib"],"src_path":"/w/app/src/lib.rs"},
                     {"name":"tool","kind":["bin"],"src_path":"/w/app/src/bin/tool.rs","required-features":["tls"]},
                     {"name":"demo","kind":["example"],"src_path":"/w/app/examples/demo.rs"},
                     {"name":"cli","kind":["bin"],"src_path":"/w/app/src/main.rs"},
                     {"name":"build-script-build","kind":["custom-build"],"src_path":"/w/app/build.rs"}]}],
         "workspace_root":"/w","target_directory":"/w/target","version":1}
        """#
        let metadata = try #require(CargoMetadata.parse(Data(json.utf8)))
        #expect(metadata.workspaceRoot == "/w" && metadata.targetDirectory == "/w/target")
        #expect(metadata.packages.first?.features == ["tls"])
        #expect(metadata.runnableTargets.map(\.name) == ["tool", "cli", "demo"])
        #expect(RunConfiguration(target: metadata.runnableTargets[0]).features == "tls")
        #expect(RunConfiguration(target: metadata.runnableTargets[2]).name == "demo (example)")
    }

    @Test(.enabled(if: ToolLocator.find("cargo") != nil))
    func loadsMetadataFromCargo() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rustide-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("src/bin"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "[package]\nname = \"meta\"\nversion = \"0.1.0\"\nedition = \"2021\"\n"
            .write(to: base.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8)
        try "fn main() {}\n".write(to: base.appendingPathComponent("src/main.rs"), atomically: true, encoding: .utf8)
        try "fn main() {}\n".write(to: base.appendingPathComponent("src/bin/extra.rs"), atomically: true, encoding: .utf8)
        let metadata = try #require(CargoMetadata.load(root: base))
        #expect(Set(metadata.runnableTargets.map(\.name)) == ["meta", "extra"])
    }

    @Test func findsOutputReferences() {
        let refs = OutputReferences.find(in: "  --> src/main.rs:3:9 and at crates/core/src/lib.rs:10")
        #expect(refs.map(\.file) == ["src/main.rs", "crates/core/src/lib.rs"])
        #expect(refs.map(\.line) == [3, 10])
        #expect(refs.map(\.column) == [9, nil])
    }
}
