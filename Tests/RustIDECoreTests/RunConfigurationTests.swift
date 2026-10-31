import Foundation
import Testing
@testable import RustIDECore

@Suite struct RunConfigurationTests {
    @Test func splitsShellWords() {
        #expect(ShellWords.split(#"-port 8080 --name "my app" 'a b' c\ d"#) == ["-port", "8080", "--name", "my app", "a b", "c d"])
        #expect(ShellWords.split("   ").isEmpty)
        #expect(ShellWords.split(#"--flag="" x"#) == ["--flag=", "x"])
    }

    @Test func parsesEnvironmentAndPattern() {
        let config = RunConfiguration(name: "server", package: "cmd/server", arguments: "-v",
                                      environment: "PORT=8080\n# comment\nDSN=postgres://u@h/db?x=1\n\n")
        #expect(config.environmentVariables == ["PORT": "8080", "DSN": "postgres://u@h/db?x=1"])
        #expect(config.packagePattern == "./cmd/server")
        #expect(RunConfiguration(name: "root", package: ".").packagePattern == ".")
    }

    @Test func findsMainPackages() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("goide-mains-\(UUID().uuidString)")
        let fm = FileManager.default
        for dir in ["cmd/server", "cmd/cli", "internal/lib"] {
            try fm.createDirectory(at: base.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: base) }
        try "package main\n\nfunc main() {}\n".write(to: base.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
        try "package main\nfunc main() {}\n".write(to: base.appendingPathComponent("cmd/server/main.go"), atomically: true, encoding: .utf8)
        try "package main\nfunc main() {}\n".write(to: base.appendingPathComponent("cmd/cli/cli.go"), atomically: true, encoding: .utf8)
        try "package lib\n".write(to: base.appendingPathComponent("internal/lib/lib.go"), atomically: true, encoding: .utf8)
        try "package main\n".write(to: base.appendingPathComponent("internal/lib/x_test.go"), atomically: true, encoding: .utf8)
        #expect(GoPackages.mainPackages(under: base) == [".", "cmd/cli", "cmd/server"])
    }
}
