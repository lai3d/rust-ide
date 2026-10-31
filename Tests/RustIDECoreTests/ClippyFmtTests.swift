import Foundation
import Testing
@testable import RustIDECore

@Suite struct RustAnalyzerSettingsTests {
    @Test func checkCommandIsCheckOrClippy() {
        #expect(RustAnalyzerSettings.make()["check"]?["command"]?.stringValue == "check")
        #expect(RustAnalyzerSettings.make(checkCommand: "clippy")["check"]?["command"]?.stringValue == "clippy")
        #expect(RustAnalyzerSettings.make(checkCommand: "rm -rf")["check"]?["command"]?.stringValue == "check")
        #expect(RustAnalyzerSettings.make()["check"]?["allTargets"]?.boolValue == true)
    }
}

@Suite struct ClippyAndRustfmtTests {
    static let clippyAvailable: Bool = {
        guard RustAnalyzerHarness.available, let cargo = ToolLocator.find("cargo") else { return false }
        let process = Process()
        process.executableURL = cargo
        process.arguments = ["clippy", "--version"]
        process.environment = ToolLocator.environment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }()

    /// With check.command = clippy, saving publishes clippy lints (source "clippy").
    @Test(.enabled(if: clippyAvailable), .timeLimit(.minutes(3)))
    func clippyLintsOnSave() async throws {
        let source = "fn main() {\n    let v = vec![1];\n    if v.len() == 0 {\n        println!(\"empty\");\n    }\n}\n"
        let ra = try await RustAnalyzerHarness(files: ["src/main.rs": source],
                                               settings: RustAnalyzerSettings.make(checkCommand: "clippy"))
        try await ra.open("src/main.rs")
        try ra.client.notify("textDocument/didSave", params: ["textDocument": ["uri": ra.uri("src/main.rs")]])
        let published = try await ra.waitFor(timeout: .seconds(150)) { method, params in
            method == "textDocument/publishDiagnostics"
                && (Diagnostic.parsePublish(params)?.diagnostics.contains { $0.source == "clippy" } ?? false)
        }
        let diagnostics = try #require(Diagnostic.parsePublish(published)).diagnostics
        #expect(diagnostics.contains { $0.source == "clippy" && $0.start.line == 2 }, "\(diagnostics)")
        await ra.shutdown()
    }

    /// Switching to clippy at runtime (didChangeConfiguration → workspace/configuration) takes effect.
    @Test(.enabled(if: clippyAvailable), .timeLimit(.minutes(3)))
    func switchesToClippyAtRuntime() async throws {
        let source = "fn main() {\n    let v = vec![1];\n    if v.len() == 0 {\n        println!(\"empty\");\n    }\n}\n"
        let ra = try await RustAnalyzerHarness(files: ["src/main.rs": source], settings: RustAnalyzerSettings.make())
        try await ra.open("src/main.rs")
        ra.configuration = RustAnalyzerSettings.make(checkCommand: "clippy")
        try ra.client.notify("workspace/didChangeConfiguration", params: ["settings": ra.configuration])
        try await Task.sleep(for: .milliseconds(500))
        try await ra.waitUntilQuiescent()
        try ra.client.notify("textDocument/didSave", params: ["textDocument": ["uri": ra.uri("src/main.rs")]])
        _ = try await ra.waitFor(timeout: .seconds(150)) { method, params in
            method == "textDocument/publishDiagnostics"
                && (Diagnostic.parsePublish(params)?.diagnostics.contains { $0.source == "clippy" } ?? false)
        }
        await ra.shutdown()
    }

    /// rustfmt (through rust-analyzer) picks up the crate's rustfmt.toml.
    @Test(.enabled(if: RustAnalyzerHarness.available), .timeLimit(.minutes(2)))
    func formattingRespectsRustfmtToml() async throws {
        let source = "fn main(){\nlet x=1;\nprintln!(\"{}\",x);\n}\n"
        let ra = try await RustAnalyzerHarness(files: ["src/main.rs": source, "rustfmt.toml": "tab_spaces = 2\n"])
        try await ra.open("src/main.rs")
        let edits = (try await ra.request("textDocument/formatting", [
            "textDocument": ["uri": ra.uri("src/main.rs")], "options": ["tabSize": 4, "insertSpaces": true],
        ])).arrayValue?.compactMap(TextEdit.parse) ?? []
        let formatted = TextEdit.apply(edits, to: source)
        #expect(formatted == "fn main() {\n  let x = 1;\n  println!(\"{}\", x);\n}\n", "\(formatted)")
        await ra.shutdown()
    }
}
