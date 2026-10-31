import Foundation
import Testing
@testable import RustIDECore

/// lldb-dap end-to-end (skipped without lldb-dap + cargo, or when macOS developer mode is off:
/// then launching under a debugger would pop an authorization dialog).
enum DebuggerAvailability {
    static let lldbDAP = DAPClient.locateLLDBDAP()

    static let enabled: Bool = {
        guard lldbDAP != nil, ToolLocator.find("cargo") != nil else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/DevToolsSecurity")
        process.arguments = ["-status"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        guard (try? process.run()) != nil else { return false }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return text.contains("enabled") && !text.contains("disabled")
    }()

    /// Builds a one-file crate and returns (crate dir, executable).
    static func build(_ main: String) throws -> (dir: URL, executable: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rustide-dap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("src"), withIntermediateDirectories: true)
        let dir = base.canonicalFileURL
        try "[package]\nname = \"dbg\"\nversion = \"0.1.0\"\nedition = \"2021\"\n"
            .write(to: dir.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8)
        try main.write(to: dir.appendingPathComponent("src/main.rs"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = ToolLocator.find("cargo")
        process.arguments = ["build", "--message-format=json-render-diagnostics"]
        process.currentDirectoryURL = dir
        process.environment = ToolLocator.environment()
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let lines = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).components(separatedBy: "\n")
        process.waitUntilExit()
        let artifact = try #require(CargoArtifact.executables(in: lines).first)
        return (dir, URL(fileURLWithPath: artifact.executable))
    }

    static func launch(_ client: DAPClient, program: URL, dir: URL) async throws {
        try client.start(adapter: try #require(lldbDAP), directory: dir, environment: ToolLocator.environment())
        try await client.request("initialize", arguments: [
            "clientID": "rustide", "adapterID": "lldb-dap", "linesStartAt1": true, "columnsStartAt1": true,
            "pathFormat": "path", "supportsVariableType": true,
        ])
        try await client.request("launch", arguments: [
            "program": .string(program.path), "cwd": .string(dir.path),
            "initCommands": .array(RustLLDB.initCommands(sysroot: RustLLDB.sysroot()).map(JSONValue.string)),
        ])
        await client.waitForEvent("initialized")
    }
}

@Suite struct CargoArtifactTests {
    @Test func parsesExecutables() {
        let lines = [
            #"{"reason":"compiler-artifact","target":{"kind":["lib"],"name":"app"},"profile":{"test":false},"executable":null}"#,
            #"{"reason":"compiler-artifact","target":{"kind":["bin"],"name":"app"},"profile":{"test":false},"executable":"/t/debug/app"}"#,
            #"{"reason":"compiler-artifact","target":{"kind":["lib"],"name":"app"},"profile":{"test":true},"executable":"/t/debug/deps/app-1f"}"#,
            #"{"reason":"build-finished","success":true}"#,
            "   Compiling app v0.1.0",
        ]
        let artifacts = CargoArtifact.executables(in: lines)
        #expect(artifacts.map(\.executable) == ["/t/debug/app", "/t/debug/deps/app-1f"])
        #expect(artifacts.map(\.isTest) == [false, true])
    }

    @Test func rustFormatterCommands() throws {
        #expect(RustLLDB.initCommands(sysroot: nil).isEmpty)
        #expect(RustLLDB.initCommands(sysroot: "/nonexistent").isEmpty)
        if let sysroot = RustLLDB.sysroot() {
            #expect(RustLLDB.initCommands(sysroot: sysroot).first?.hasPrefix("command script import") == true)
        }
    }
}

@Suite struct DAPTests {
    @Test(.enabled(if: DebuggerAvailability.enabled), .timeLimit(.minutes(2)))
    func launchesBreaksInspectsAndContinues() async throws {
        let (dir, program) = try DebuggerAvailability.build("""
            #[derive(Debug)]
            struct Point {
                x: i32,
                y: i32,
            }

            fn main() {
                let p = Point { x: 3, y: 4 };
                let names = vec!["a".to_string(), "b".to_string()];
                let total = p.x + p.y;
                println!("total {total} {}", names.len());
            }

            """)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let client = DAPClient()
        let (events, continuation) = AsyncStream<(String, JSONValue)>.makeStream()
        client.onEvent = { continuation.yield(($0, $1)) }
        try await DebuggerAvailability.launch(client, program: program, dir: dir)
        let set = try await client.request("setBreakpoints", arguments: [
            "source": ["path": .string(dir.appendingPathComponent("src/main.rs").path)], "breakpoints": [["line": 10]],
        ])
        #expect(set["breakpoints"]?[0]?["verified"]?.boolValue == true, "\(set)")
        try await client.request("configurationDone")

        var stoppedThread: Int?
        for await (event, body) in events where event == "stopped" {
            stoppedThread = body["threadId"]?.intValue
            break
        }
        let thread = try #require(stoppedThread)
        let frames = StackFrame.parseAll(try await client.request("stackTrace", arguments: ["threadId": .int(thread), "levels": 20]))
        #expect(frames.first?.name.contains("main") == true && frames.first?.line == 10, "\(frames.prefix(2))")
        #expect(frames.first?.path?.hasSuffix("/src/main.rs") == true)

        let scopes = DebugVariable.parseScopes(try await client.request("scopes", arguments: ["frameId": .int(frames[0].id)]))
        let locals = try #require(scopes.first { $0.name == "Locals" }, "\(scopes.map(\.name))")
        let variables = DebugVariable.parseVariables(try await client.request("variables", arguments: [
            "variablesReference": .int(locals.variablesReference),
        ]))
        let p = try #require(variables.first { $0.name == "p" }, "\(variables.map(\.name))")
        let fields = DebugVariable.parseVariables(try await client.request("variables", arguments: [
            "variablesReference": .int(p.variablesReference),
        ]))
        #expect(fields.map(\.name) == ["x", "y"] && fields.map(\.value) == ["3", "4"], "\(fields)")
        // rustc's formatters: a Vec shows its length and elements, not raw buf/len fields.
        let names = try #require(variables.first { $0.name == "names" })
        #expect(names.value.contains("size=2"), "Vec shown as: \(names.value)")

        try await client.request("next", arguments: ["threadId": .int(thread)])
        for await (event, _) in events where event == "stopped" { break }
        let afterStep = StackFrame.parseAll(try await client.request("stackTrace", arguments: ["threadId": .int(thread), "levels": 1]))
        #expect(afterStep.first?.line == 11)

        try await client.request("continue", arguments: ["threadId": .int(thread)])
        var sawOutput = false
        for await (event, body) in events {
            if event == "output", body["output"]?.stringValue?.contains("total 7 2") == true { sawOutput = true }
            if event == "terminated" { break }
        }
        #expect(sawOutput)
        await client.shutdown()
    }

    @Test(.enabled(if: DebuggerAvailability.enabled), .timeLimit(.minutes(2)))
    func conditionalBreakpointAndEvaluate() async throws {
        let (dir, program) = try DebuggerAvailability.build("""
            fn main() {
                let mut total = 0;
                for i in 0..10 {
                    total += i;
                }
                println!("{total}");
            }

            """)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let client = DAPClient()
        let (events, continuation) = AsyncStream<(String, JSONValue)>.makeStream()
        client.onEvent = { continuation.yield(($0, $1)) }
        try await DebuggerAvailability.launch(client, program: program, dir: dir)
        try await client.request("setBreakpoints", arguments: [
            "source": ["path": .string(dir.appendingPathComponent("src/main.rs").path)],
            "breakpoints": [["line": 4, "condition": "i == 7"]],
        ])
        try await client.request("configurationDone")
        var thread: Int?
        for await (event, body) in events where event == "stopped" {
            thread = body["threadId"]?.intValue
            break
        }
        let frames = StackFrame.parseAll(try await client.request("stackTrace", arguments: ["threadId": .int(try #require(thread)), "levels": 1]))
        let frame = try #require(frames.first).id
        func evaluate(_ expression: String) async throws -> String? {
            try await client.request("evaluate", arguments: ["expression": .string(expression), "frameId": .int(frame), "context": "hover"])["result"]?.stringValue
        }
        #expect(try await evaluate("i") == "7")       // stopped only when the condition held
        #expect(try await evaluate("total") == "21")  // 0+1+…+6
        await client.shutdown()
    }
}
