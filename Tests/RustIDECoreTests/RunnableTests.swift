import Foundation
import Testing
@testable import RustIDECore

@Suite struct RunnableTests {
    @Test func parsesRunnablesWithLocations() {
        let json: JSONValue = [
            [
                "label": "run hello", "kind": "cargo",
                "location": ["targetUri": "file:///w/src/main.rs",
                             "targetRange": ["start": ["line": 0, "character": 0], "end": ["line": 2, "character": 1]],
                             "targetSelectionRange": ["start": ["line": 0, "character": 3], "end": ["line": 0, "character": 7]]],
                "args": ["cargoArgs": ["run", "--package", "hello", "--bin", "hello"], "executableArgs": [], "cwd": "/w"],
            ],
            [
                "label": "test-mod tests", "kind": "cargo",
                "location": ["targetUri": "file:///w/src/main.rs",
                             "targetRange": ["start": ["line": 4, "character": 0], "end": ["line": 9, "character": 1]],
                             "targetSelectionRange": ["start": ["line": 5, "character": 4], "end": ["line": 5, "character": 9]]],
                "args": ["cargoArgs": ["test", "--package", "hello", "--bin", "hello"], "executableArgs": ["tests", "--nocapture"]],
            ],
            [  // workspace-level: no location
                "label": "cargo check -p hello --all-targets", "kind": "cargo",
                "args": ["cargoArgs": ["check", "--package", "hello", "--all-targets"], "executableArgs": []],
            ],
            ["label": "shell thing", "kind": "shell", "location": ["targetRange": ["start": ["line": 1, "character": 0]]],
             "args": ["cargoArgs": ["x"]]],
        ]
        let runnables = Runnable.parseAll(json)
        #expect(runnables.count == 2)
        #expect(runnables[0].kind == .run && runnables[0].line == 0 && runnables[0].subject == "hello" && !runnables[0].isTest)
        #expect(runnables[0].commandLine() == ["run", "--package", "hello", "--bin", "hello"])
        #expect(runnables[1].kind == .testModule && runnables[1].line == 5 && runnables[1].isTest)
        #expect(runnables[1].commandLine(extra: ["--features", "hello/x"])
                == ["test", "--package", "hello", "--bin", "hello", "--features", "hello/x", "--", "tests", "--nocapture"])
        #expect(Runnable(label: "doctest add", line: 0, cargoArgs: ["test"]).kind == .doctest)
        #expect(Runnable(label: "bench parse", line: 0, cargoArgs: ["bench"]).kind == .bench)
    }

    @Test(.enabled(if: RustAnalyzerHarness.available), .timeLimit(.minutes(2)))
    func rustAnalyzerReportsMainTestModulesAndDoctests() async throws {
        let main = "fn main() {}\n\n#[cfg(test)]\nmod tests {\n    #[test]\n    fn t1() {}\n}\n"
        let lib = "/// ```\n/// assert_eq!(fixture::f(), 1);\n/// ```\npub fn f() -> i32 { 1 }\n"
        let ra = try await RustAnalyzerHarness(files: ["src/main.rs": main, "src/lib.rs": lib])
        try await ra.open("src/main.rs", "src/lib.rs")
        let mainRunnables = Runnable.parseAll(try await ra.request("experimental/runnables", ["textDocument": ["uri": ra.uri("src/main.rs")]]))
        #expect(mainRunnables.contains { $0.kind == .run && $0.line == 0 && $0.cargoArgs.first == "run" }, "\(mainRunnables)")
        #expect(mainRunnables.contains { $0.kind == .testModule && $0.line == 3 && $0.executableArgs.first == "tests" }, "\(mainRunnables)")
        #expect(mainRunnables.contains { $0.kind == .test && $0.subject == "tests::t1" }, "\(mainRunnables)")
        let libRunnables = Runnable.parseAll(try await ra.request("experimental/runnables", ["textDocument": ["uri": ra.uri("src/lib.rs")]]))
        #expect(libRunnables.contains { $0.kind == .doctest && $0.cargoArgs.contains("--doc") }, "\(libRunnables)")
        await ra.shutdown()
    }
}
